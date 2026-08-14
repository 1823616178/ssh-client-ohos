/**
 * 通道与 PTY 测试 —— 任务 N10「shell 通道与 PTY」。
 *
 * 覆盖：
 *   单元级（不需要真实服务器）：
 *     - isLegalTransition：idle→opening→pty→starting→open→closing→closed 全表
 *     - 会话非 established 态拒绝打开通道；未打开的通道拒绝 write/resize/sendEof
 *   集成（SSH_TESTS_INTEGRATION 且认证 sshd 环境就绪时；否则 GTEST_SKIP）：
 *     - 开 shell + PTY：写入 `stty size; exit`，回显含所设 rows/cols（97x31），
 *       退出后关闭回调给出 kExitStatus 0
 *     - execWithPty `stty size`：干净断言「100x40 → "40 100"」
 *     - resize：shell 内 stty 先得 "24 80"，resize(120,40) 后再得 "40 120"
 *      （远端收到 window-change 后 ioctl TIOCSWINSZ + SIGWINCH 的直接证据）
 *     - exit-status：`exit 42` → 42；不存在的命令 → 127；
 *       `kill -KILL $$` → kExitSignal 且信号名 "KILL"
 *     - stderr 分离：exec 无 PTY 时 echo 到 >&2 的内容走 kStderr 流
 *     - 大数据量：`seq 1 100000`（约 575 KB）全部收齐，首末行与行数校验
 *     - 背压续发：exec("cat") 单次 write 2 MiB → sendEof → 回显逐字节相等
 *     - 背压拒收：exec("sleep 30")（对端不读）下连写 1 MiB 块直到被拒
 *      （4 MiB 队列上限），close 后待发泄零
 *     - 会话关闭通知：established 态 session.close()，开着的通道收到 kError
 *
 * 认证 sshd 环境：与 N8/N9 相同（sshd_testkit.h 头注），材料在
 * $HOME/ohos-probe/build/host-deps/auth/。
 */
#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "io/SessionThread.h"
#include "ssh/channel.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;
using sshclient::ssh::ChannelCloseInfo;
using sshclient::ssh::ChannelCloseReason;
using sshclient::ssh::ChannelState;
using sshclient::ssh::ChannelStream;
using sshclient::ssh::ChannelOpenResult;
using sshclient::ssh::PtySpec;
using sshclient::ssh::SshChannel;
using sshclient::ssh::SshChannelCallbacks;
using sshclient::ssh::SshChannelError;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionState;

namespace {

// ---------------------------------------------------------------- 回调收集器

class OpenBox {
public:
    void operator()(const ChannelOpenResult &result)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            result_ = result;
        }
        cv_.notify_all();
    }

    bool wait(std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return result_.has_value(); });
    }

    std::optional<ChannelOpenResult> result() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return result_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::optional<ChannelOpenResult> result_;
};

class CloseBox {
public:
    void operator()(const ChannelCloseInfo &info)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            info_ = info;
        }
        cv_.notify_all();
    }

    bool wait(std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return info_.has_value(); });
    }

    std::optional<ChannelCloseInfo> result() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return info_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::optional<ChannelCloseInfo> info_;
};

// stdout/stderr 分账收集；waitOutContains 支持偏移量（区分先后两次相同命令的输出）
class DataSink {
public:
    void operator()(const std::string &data, ChannelStream stream)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stream == ChannelStream::kStdout) {
                out_ += data;
            } else {
                err_ += data;
            }
        }
        cv_.notify_all();
    }

    // 等待 out_ 在 fromOffset 之后出现 needle；命中时经 foundPos 返回位置
    bool waitOutContains(const std::string &needle, size_t fromOffset,
                         std::chrono::milliseconds timeout, size_t *foundPos = nullptr)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        const bool ok = cv_.wait_for(lock, timeout, [&] {
            return out_.find(needle, fromOffset) != std::string::npos;
        });
        if (!ok) {
            return false;
        }
        if (foundPos != nullptr) {
            *foundPos = out_.find(needle, fromOffset);
        }
        return true;
    }

    bool waitOutSize(size_t size, std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return out_.size() >= size; });
    }

    std::string out() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return out_;
    }

    std::string err() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return err_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::string out_;
    std::string err_;
};

SshChannelCallbacks MakeCallbacks(OpenBox &openBox, DataSink &sink, CloseBox &closeBox)
{
    SshChannelCallbacks callbacks;
    callbacks.onOpen = std::ref(openBox);
    callbacks.onData = std::ref(sink);
    callbacks.onClose = std::ref(closeBox);
    return callbacks;
}

// 用例样板：建立会话（established）与通道后交给 body；body 返回后无论成败都按
// 「通道 close（已在终态则空操作）→ 会话 close → 等会话终态 → 通道析构」的顺序
// 兜底收尾——析构约定（通道不晚于会话终态存活）在断言失败路径上同样成立。
// body 参数：(channel, openBox, sink, closeBox)。
template <typename F>
void ChannelTestCase(const AuthTestEnv &env, F body)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachEstablished(session, rec, env));
        OpenBox openBox;
        DataSink sink;
        CloseBox closeBox;
        auto channel =
            std::make_unique<SshChannel>(session, MakeCallbacks(openBox, sink, closeBox));
        body(*channel, openBox, sink, closeBox);
        // 兜底收尾：通道未到终态则主动 close 并等一拍（成功路径下是空操作；
        // 失败路径上 close 握手若也走不完，session.close 的 onSessionLost 兜底）
        if (channel->state() != ChannelState::kClosed) {
            channel->close();
            closeBox.wait(5s);
        }
        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        // 会话终态后：注册表已清空，通道要么已自行收尾，要么已被 onSessionLost
        // 推到终态——此刻析构通道满足约定
        channel.reset();
    }
    thread.stop();
}

size_t CountNewlines(const std::string &s)
{
    size_t n = 0;
    for (const char c : s) {
        if (c == '\n') {
            ++n;
        }
    }
    return n;
}

// ---------------------------------------------------------------- 单元级：状态机边界

TEST(SshChannelTest, LegalTransitions)
{
    using S = ChannelState;
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kIdle, S::kOpening));
    EXPECT_FALSE(SshChannel::isLegalTransition(S::kIdle, S::kOpen));

    EXPECT_TRUE(SshChannel::isLegalTransition(S::kOpening, S::kRequestingPty));
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kOpening, S::kStarting)); // 无 PTY 跳过 pty 步
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kOpening, S::kClosing));
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kOpening, S::kClosed));
    EXPECT_FALSE(SshChannel::isLegalTransition(S::kOpening, S::kOpen));

    EXPECT_TRUE(SshChannel::isLegalTransition(S::kRequestingPty, S::kStarting));
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kRequestingPty, S::kClosing));
    EXPECT_FALSE(SshChannel::isLegalTransition(S::kRequestingPty, S::kOpen));

    EXPECT_TRUE(SshChannel::isLegalTransition(S::kStarting, S::kOpen));
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kStarting, S::kClosed));
    EXPECT_FALSE(SshChannel::isLegalTransition(S::kStarting, S::kRequestingPty));

    EXPECT_TRUE(SshChannel::isLegalTransition(S::kOpen, S::kClosing));
    EXPECT_TRUE(SshChannel::isLegalTransition(S::kOpen, S::kClosed)); // 会话丢失强制清理
    EXPECT_FALSE(SshChannel::isLegalTransition(S::kOpen, S::kOpening));

    EXPECT_TRUE(SshChannel::isLegalTransition(S::kClosing, S::kClosed));
    EXPECT_FALSE(SshChannel::isLegalTransition(S::kClosing, S::kOpen));

    EXPECT_FALSE(SshChannel::isLegalTransition(S::kClosed, S::kOpening)); // 终态
}

// 会话不在 established 态时拒绝打开；未打开的通道拒绝一切数据面操作
TEST(SshChannelTest, RejectedWhenNotEstablished)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec)); // 不 connect，停留 idle
        OpenBox openBox;
        DataSink sink;
        CloseBox closeBox;
        SshChannel channel(session, MakeCallbacks(openBox, sink, closeBox));

        EXPECT_FALSE(channel.openShell(PtySpec{}));
        EXPECT_FALSE(channel.exec("true"));
        EXPECT_FALSE(channel.execWithPty(PtySpec{}, "true"));
        EXPECT_FALSE(channel.write("x", 1));
        EXPECT_FALSE(channel.resize(80, 24));
        EXPECT_FALSE(channel.sendEof());
        channel.close(); // 从未受理打开：空操作、不投递、不回调
        EXPECT_EQ(channel.state(), ChannelState::kIdle);
        EXPECT_FALSE(openBox.wait(200ms)) << "未受理的打开不得触发回调";
    }
    thread.stop();
}

// ---------------------------------------------------------------- 集成：shell + PTY

// 验收标准①：能开 shell；验收标准②：stty size 与设置的 cols/rows 一致。
// 用非常规尺寸 97x31（而非 80x24 默认值）证明是本端设置生效而非巧合。
TEST(SshChannelIntegrationTest, OpenShellEchoSttySize)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink &sink,
                            CloseBox &closeBox) {
        PtySpec pty;
        pty.cols = 97;
        pty.rows = 31;
        ASSERT_TRUE(channel.openShell(pty));
        ASSERT_TRUE(openBox.wait(10s)) << "shell 打开超时";
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;

        ASSERT_TRUE(channel.write("stty size; exit\n"));
        // PTY 回显命令本身（"stty size; exit"），stty 输出 "<rows> <cols>"
        ASSERT_TRUE(sink.waitOutContains("31 97", 0, 10s))
            << "shell 回显中未见所设尺寸，已收到:\n" << sink.out();
        ASSERT_TRUE(closeBox.wait(10s)) << "exit 后通道关闭超时";
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 0);
        EXPECT_EQ(channel.state(), ChannelState::kClosed);
    });
}

// execWithPty：request_pty + process_startup("exec", ...) 组合，输出无 shell
// 回显干扰，干净断言尺寸（另一非常规值 100x40）
TEST(SshChannelIntegrationTest, ExecWithPtySttySize)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink &sink,
                            CloseBox &closeBox) {
        PtySpec pty;
        pty.cols = 100;
        pty.rows = 40;
        ASSERT_TRUE(channel.execWithPty(pty, "stty size"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;

        ASSERT_TRUE(sink.waitOutContains("40 100", 0, 10s))
            << "stty size 输出不含所设尺寸，已收到:\n" << sink.out();
        ASSERT_TRUE(closeBox.wait(10s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 0);
    });
}

// 验收标准③：resize 后 SIGWINCH 生效——同一 shell 会话内 stty size 先报
// 24 80，resize(120,40) 后报 40 120（远端 sshd 收到 window-change 后
// TIOCSWINSZ 并向 pty 前台进程组发 SIGWINCH，shell/stty 随后读到新尺寸）
TEST(SshChannelIntegrationTest, ResizeDeliversSigwinch)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink &sink,
                            CloseBox &closeBox) {
        ASSERT_TRUE(channel.openShell(PtySpec{})); // 默认 80x24
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;

        ASSERT_TRUE(channel.write("stty size\n"));
        size_t firstPos = 0;
        ASSERT_TRUE(sink.waitOutContains("24 80", 0, 10s, &firstPos))
            << "初始尺寸非 24 80，已收到:\n" << sink.out();

        ASSERT_TRUE(channel.resize(120, 40));
        // resize 请求与本命令按 post FIFO 先后上送，对端按序处理：
        // window-change 生效后 shell 才读到这条 stty
        ASSERT_TRUE(channel.write("stty size\n"));
        ASSERT_TRUE(sink.waitOutContains("40 120", firstPos + 1, 10s))
            << "resize 后尺寸未变（SIGWINCH 未生效？），已收到:\n" << sink.out();

        ASSERT_TRUE(channel.write("exit\n"));
        ASSERT_TRUE(closeBox.wait(10s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 0);
    });
}

// ---------------------------------------------------------------- 集成：exit-status / exit-signal

TEST(SshChannelIntegrationTest, ExecExitStatus42)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink & /*sink*/,
                            CloseBox &closeBox) {
        ASSERT_TRUE(channel.exec("exit 42"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;
        ASSERT_TRUE(closeBox.wait(10s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 42);
    });
}

TEST(SshChannelIntegrationTest, ExecCommandNotFound127)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink & /*sink*/,
                            CloseBox &closeBox) {
        ASSERT_TRUE(channel.exec("sshclient-nonexistent-cmd-xyz"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;
        ASSERT_TRUE(closeBox.wait(10s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 127);
    });
}

TEST(SshChannelIntegrationTest, ExecExitSignalKill)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink & /*sink*/,
                            CloseBox &closeBox) {
        // sh -c 进程自杀：sshd 按 RFC 4254 §6.10 报 exit-signal
        ASSERT_TRUE(channel.exec("kill -KILL $$"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;
        ASSERT_TRUE(closeBox.wait(10s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitSignal);
        EXPECT_EQ(closeBox.result()->exitSignal, "KILL");
    });
}

// ---------------------------------------------------------------- 集成：stderr 分离

TEST(SshChannelIntegrationTest, ExecSeparatesStderr)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink &sink,
                            CloseBox &closeBox) {
        // 无 PTY 的 exec：stderr 独立成流（PTY 下两流会被终端合并）
        ASSERT_TRUE(channel.exec("echo n10-stdout-marker; echo n10-stderr-marker >&2"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;

        ASSERT_TRUE(sink.waitOutContains("n10-stdout-marker", 0, 10s));
        ASSERT_TRUE(closeBox.wait(10s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_NE(sink.err().find("n10-stderr-marker"), std::string::npos)
            << "stderr 流未收到内容，err:\n" << sink.err();
        EXPECT_EQ(sink.out().find("n10-stderr-marker"), std::string::npos)
            << "stderr 混入了 stdout 流:\n" << sink.out();
    });
}

// ---------------------------------------------------------------- 集成：大数据量与背压

// seq 1 100000 ≈ 575 KB 输出：抽干路径跨多次 EPOLLIN/多轮 pump，全量收齐校验
TEST(SshChannelIntegrationTest, LargeOutputSeq)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink &sink,
                            CloseBox &closeBox) {
        ASSERT_TRUE(channel.exec("seq 1 100000"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;

        ASSERT_TRUE(closeBox.wait(20s)) << "seq 输出未收尾";
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 0);
        const std::string out = sink.out();
        EXPECT_EQ(out.rfind("1\n2\n3\n", 0), 0u) << "输出开头不符";
        const std::string kTail = "99999\n100000\n"; // 6+7=13 字节
        ASSERT_GE(out.size(), kTail.size());
        EXPECT_EQ(out.compare(out.size() - kTail.size(), kTail.size(), kTail), 0)
            << "输出末尾不符（截断？），实际末尾: " << out.substr(out.size() - 32);
        EXPECT_EQ(CountNewlines(out), 100000u) << "行数不符（丢数据？）";
    });
}

// 背压续发路径：单次 write 2 MiB（> socket 缓冲，必然 EAGAIN 留存续发），
// cat 回显逐字节相等；sendEof 排在待发数据之后触发对端退出
TEST(SshChannelIntegrationTest, CatEchoLargeWriteFlush)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink &sink,
                            CloseBox &closeBox) {
        ASSERT_TRUE(channel.exec("cat"));
        // 受理后即可写：数据在通道就绪前排队（不必等 onOpen）
        constexpr size_t kPayloadSize = 2u * 1024 * 1024;
        std::string payload;
        payload.reserve(kPayloadSize);
        const std::string block = "0123456789abcdef\n";
        while (payload.size() < kPayloadSize) {
            payload += block;
        }
        payload.resize(kPayloadSize);
        ASSERT_TRUE(channel.write(payload));
        ASSERT_TRUE(channel.sendEof());

        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;
        ASSERT_TRUE(sink.waitOutSize(kPayloadSize, 30s))
            << "回显字节不足：" << sink.out().size() << " / " << kPayloadSize;
        ASSERT_TRUE(closeBox.wait(20s));
        EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kExitStatus);
        EXPECT_EQ(closeBox.result()->exitStatus, 0);
        EXPECT_EQ(sink.out(), payload) << "回显与写入逐字节不等（EAGAIN 续发丢数据？）";
        EXPECT_EQ(channel.pendingWriteBytes(), 0u);
    });
}

// 背压拒收：对端（sleep）不读 stdin，通道窗口（OpenSSH 默认 2 MiB，按 4 MiB
// 上限预留）与 socket 缓冲耗尽后队列涨到 4 MiB 上限，write 整次拒收；
// close 后待发泄零（退账正确性）。
// 时序：sleep 期间对端始终不读（6 s > 12×50ms 的写入循环）；close 的
// CHANNEL_CLOSE 排在对端未消费的字节之后，sleep 退出后 sshd 才处理得到——
// closeBox 等待上限按此放宽。
TEST(SshChannelIntegrationTest, WriteBackpressureRejection)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    ChannelTestCase(env, [](SshChannel &channel, OpenBox &openBox, DataSink & /*sink*/,
                            CloseBox &closeBox) {
        ASSERT_TRUE(channel.exec("sleep 6"));
        ASSERT_TRUE(openBox.wait(10s));
        ASSERT_TRUE(openBox.result()->success) << openBox.result()->message;

        const std::string chunk(1024 * 1024, 'x'); // 1 MiB/块
        size_t accepted = 0;
        bool rejected = false;
        for (int i = 0; i < 12; ++i) {
            if (channel.write(chunk)) {
                ++accepted;
            } else {
                rejected = true;
                break;
            }
            // 给循环线程一点冲刷时间，让窗口/缓冲消耗反映到队列记账
            std::this_thread::sleep_for(50ms);
        }
        EXPECT_TRUE(rejected) << "写入 12 MiB 未触发背压拒收（上限 4 MiB）";
        EXPECT_LE(accepted * chunk.size(),
                  SshChannel::kMaxPendingWriteBytes + 5u * 1024 * 1024)
            << "受理总量异常（窗口+缓冲之外的超额入队）";

        channel.close();
        ASSERT_TRUE(closeBox.wait(15s));
        // 本地主动 close：对端进程随即被 sshd 终止，可能报 exit-signal，
        // 也可能直接 close 应答——不断言具体原因，只要不是 error
        EXPECT_NE(closeBox.result()->reason, ChannelCloseReason::kError)
            << closeBox.result()->message;
        EXPECT_EQ(channel.pendingWriteBytes(), 0u) << "关闭后待发队列未退账清零";
    });
}

// ---------------------------------------------------------------- 集成：会话关闭通知通道

TEST(SshChannelIntegrationTest, SessionCloseNotifiesChannels)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachEstablished(session, rec, env));
        OpenBox openBox;
        DataSink sink;
        CloseBox closeBox;
        auto channel =
            std::make_unique<SshChannel>(session, MakeCallbacks(openBox, sink, closeBox));

        const bool admitted = channel->openShell(PtySpec{});
        EXPECT_TRUE(admitted);
        const bool opened =
            admitted && openBox.wait(10s) && openBox.result()->success;
        EXPECT_TRUE(opened) << (openBox.result() ? openBox.result()->message : "超时");

        session.close(); // 会话断开 → 注册通道收到 kError 关闭通知
        if (opened) {
            EXPECT_TRUE(closeBox.wait(10s)) << "会话关闭未通知到通道";
            if (closeBox.result().has_value()) {
                EXPECT_EQ(closeBox.result()->reason, ChannelCloseReason::kError);
                EXPECT_EQ(channel->state(), ChannelState::kClosed);
            }
        }
        // 无论成败按序收尾：会话终态（releaseResources 强制清理残留通道）后再析构
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        channel.reset();
    }
    thread.stop();
}

} // namespace
