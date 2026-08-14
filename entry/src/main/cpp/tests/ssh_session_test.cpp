/**
 * SshSession 单测与集成测试 —— 任务 N6「会话生命周期与状态机」。
 *
 * 覆盖：
 *   状态机（不需要真实服务器）：
 *     - 迁移合法性表（isLegalTransition 静态校验，含 N7 新增的 handshaking→closing）
 *     - 非法迁移拒绝：idle 态 close 空操作、非 idle 重复 connect 被拒
 *     - 回调按序触发：连关闭端口 → idle→connecting→error
 *     - 连接超时机制：连 RFC 5737 黑洞地址（192.0.2.x），connectTimeout 内收敛到 error
 *     - 握手超时 / 垃圾 banner：本地哑服务器（accept 后沉默 / 发垃圾字节）
 *   集成（SSH_TESTS_INTEGRATION 且找到 sshd 时；否则 GTEST_SKIP）：
 *     - 完整握手到「待认证」（authenticating）边界
 *     - 优雅关闭：authenticating→closing→closed
 *     - 断线检测：kill 掉辅助 sshd 进程（模拟「拔线/RST」——被 kill 进程的
 *        socket 由内核 RST），断言 30 s 内进入 disconnected（实测秒级以内）
 *
 * sshd 集成辅助（StateRecorder / PickFreePort / 免 root sshd 起停等）自 N7 起
 * 抽到 sshd_testkit.h，与 hostkey_test.cpp 共用。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <poll.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "io/SessionThread.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionError;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;

namespace {

// 哑 TCP 服务器：accept 后按构造参数发一段字节（空 = 一字节不发，保持沉默），
// 随后保持连接直到对端关闭或 stop()。用于握手超时 / 垃圾 banner 用例。
class DeadEndServer {
public:
    explicit DeadEndServer(std::string payload) : payload_(std::move(payload)) {}
    ~DeadEndServer() { stop(); }

    bool start()
    {
        listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd_ < 0) {
            return false;
        }
        int one = 1;
        ::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        if (::bind(listenFd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0 ||
            ::listen(listenFd_, 4) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }
        socklen_t len = sizeof(addr);
        if (::getsockname(listenFd_, reinterpret_cast<struct sockaddr *>(&addr), &len) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }
        port_ = ntohs(addr.sin_port);
        thread_ = std::thread([this] { serve(); });
        return true;
    }

    uint16_t port() const { return port_; }

    void stop()
    {
        if (listenFd_ < 0 && !thread_.joinable()) {
            return;
        }
        stop_ = true;
        if (listenFd_ >= 0) {
            ::shutdown(listenFd_, SHUT_RDWR); // 唤醒 poll/accept
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        if (listenFd_ >= 0) {
            ::close(listenFd_);
            listenFd_ = -1;
        }
    }

private:
    void serve()
    {
        while (!stop_.load()) {
            struct pollfd pfd {};
            pfd.fd = listenFd_;
            pfd.events = POLLIN;
            if (::poll(&pfd, 1, 100) <= 0) {
                continue; // 超时 / 被 shutdown 打断，回看 stop 标记
            }
            int conn = ::accept(listenFd_, nullptr, nullptr);
            if (conn < 0) {
                continue;
            }
            if (!payload_.empty()) {
                ssize_t n = ::write(conn, payload_.data(), payload_.size());
                (void)n;
            }
            // 保持连接：读到对端关闭（会话收尾 close fd）或 stop 为止
            char buf[512];
            while (!stop_.load()) {
                struct pollfd cfd {};
                cfd.fd = conn;
                cfd.events = POLLIN;
                if (::poll(&cfd, 1, 100) <= 0) {
                    continue;
                }
                if (::recv(conn, buf, sizeof(buf), 0) <= 0) {
                    break;
                }
            }
            ::close(conn);
        }
    }

    std::string payload_;
    int listenFd_ = -1;
    uint16_t port_ = 0;
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

} // namespace

// ================================================================== 状态机单测

TEST(SshSessionStateMachineTest, TransitionTableLegality)
{
    using S = SshSessionState;
    // 合法主路径
    EXPECT_TRUE(SshSession::isLegalTransition(S::kIdle, S::kConnecting));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kConnecting, S::kHandshaking));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kHandshaking, S::kAuthenticating));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kAuthenticating, S::kEstablished));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kAuthenticating, S::kClosing));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kClosing, S::kClosed));
    // 异常路径
    EXPECT_TRUE(SshSession::isLegalTransition(S::kConnecting, S::kError));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kHandshaking, S::kError));
    // N7：主机密钥被拒时 handshaking → closing（发协议层 disconnect 再 closed）
    EXPECT_TRUE(SshSession::isLegalTransition(S::kHandshaking, S::kClosing));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kAuthenticating, S::kDisconnected));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kEstablished, S::kDisconnected));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kConnecting, S::kClosed));
    // 非法：跳级、回退、终态再迁移
    EXPECT_FALSE(SshSession::isLegalTransition(S::kIdle, S::kEstablished));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kIdle, S::kClosed));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kConnecting, S::kEstablished));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kAuthenticating, S::kConnecting));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kError, S::kConnecting));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kClosed, S::kConnecting));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kDisconnected, S::kIdle));
}

TEST(SshSessionStateMachineTest, CloseFromIdleIsNoop)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        session.close(); // idle 态：幂等空操作，不得产生任何迁移
        std::this_thread::sleep_for(200ms); // 给 post 的任务留执行窗口
        EXPECT_EQ(session.state(), SshSessionState::kIdle);
        EXPECT_TRUE(rec.toSequence().empty());
        thread.stop();
    }
}

TEST(SshSessionStateMachineTest, DuplicateConnectRejected)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        const uint16_t port = PickFreePort(); // 刚释放的端口：必为关闭态
        ASSERT_TRUE(session.connect("127.0.0.1", port, "tester"));
        // 已受理后（任何非 idle 态）重复 connect 一律拒绝
        EXPECT_FALSE(session.connect("127.0.0.1", port, "tester"));

        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        // 终态后同样拒绝
        EXPECT_FALSE(session.connect("127.0.0.1", port, "tester"));
        thread.stop();
    }
    // 序列里只能有一条 connecting：第二次 connect 没有产生任何迁移
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kError});
}

TEST(SshSessionStateMachineTest, ConnectToClosedPortFailsFast)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        const uint16_t port = PickFreePort();
        const auto begin = std::chrono::steady_clock::now();
        ASSERT_TRUE(session.connect("127.0.0.1", port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;

        EXPECT_EQ(session.lastError(), SshSessionError::kConnectFailed);
        // 本地拒绝是即时的，应远小于默认 10 s 连接超时
        EXPECT_LT(elapsed, 5s);
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kError});
}

TEST(SshSessionStateMachineTest, ConnectToBlackholeAlwaysConvergesToError)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    std::vector<SshSessionState> seq;
    {
        SshSessionOptions opts;
        opts.connectTimeoutMs = 500;   // 收紧超时，测试别等默认 10 s
        opts.handshakeTimeoutMs = 2000;
        SshSession session(thread, opts, std::ref(rec));
        const auto begin = std::chrono::steady_clock::now();
        // 192.0.2.0/24 是 RFC 5737 TEST-NET-1：正常环境 SYN 被静默丢弃，
        // connectTimeout 到期 → error(connect_timeout)。但 WSL NAT 等环境会劫持
        // 该地址完成 TCP、随后 RST——路径不同但同样必须收敛到 error 而非卡死，
        // 这正是本用例要守的底线；环境相关分支都接受。
        ASSERT_TRUE(session.connect("192.0.2.1", 22, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 8s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;

        const SshSessionError err = session.lastError();
        // N13：部分环境内核直接报 EHOSTUNREACH/ENETUNREACH，细分为 connect_unreachable
        EXPECT_TRUE(err == SshSessionError::kConnectTimeout ||
                    err == SshSessionError::kConnectFailed ||
                    err == SshSessionError::kConnectUnreachable ||
                    err == SshSessionError::kHandshakeTimeout ||
                    err == SshSessionError::kHandshakeFailed)
            << "意外错误码: " << sshclient::ssh::toString(err);
        EXPECT_LT(elapsed, 8s);
        seq = rec.toSequence();
        thread.stop();
    }
    // 首迁移必为 connecting，终态必为 error（中间是否经过 handshaking 视环境而定）
    ASSERT_FALSE(seq.empty());
    EXPECT_EQ(seq.front(), SshSessionState::kConnecting);
    EXPECT_EQ(seq.back(), SshSessionState::kError);
}

TEST(SshSessionStateMachineTest, HandshakeTimeoutAgainstSilentServer)
{
    DeadEndServer server(""); // 沉默服务器：accept 后一字节不发
    ASSERT_TRUE(server.start());

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.handshakeTimeoutMs = 800;
        SshSession session(thread, opts, std::ref(rec));
        const auto begin = std::chrono::steady_clock::now();
        ASSERT_TRUE(session.connect("127.0.0.1", server.port(), "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;

        EXPECT_EQ(session.lastError(), SshSessionError::kHandshakeTimeout);
        EXPECT_GE(elapsed, 700ms); // 不能提前误触发
        EXPECT_LT(elapsed, 5s);
        thread.stop();
    }
    server.stop();
    // TCP 连接成功 → 握手超时：connecting → handshaking → error
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kError});
}

TEST(SshSessionStateMachineTest, HandshakeGarbageBannerFails)
{
    // 合法 banner 之后塞垃圾字节：算法协商/包层解析必然失败
    DeadEndServer server(std::string("SSH-2.0-TestGarbage\r\n") + std::string(256, '\xAB'));
    ASSERT_TRUE(server.start());

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.handshakeTimeoutMs = 3000; // 兜底：即使实现选择挂起也得按时收敛
        SshSession session(thread, opts, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", server.port(), "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        // N13：垃圾字节断在 KEX 阶段时 libssh2 报 KEX_FAILURE，细分为算法协商失败
        EXPECT_TRUE(session.lastError() == SshSessionError::kHandshakeFailed ||
                    session.lastError() == SshSessionError::kHandshakeTimeout ||
                    session.lastError() == SshSessionError::kAlgorithmNegotiationFailed)
            << "意外错误码: " << sshclient::ssh::toString(session.lastError());
        thread.stop();
    }
    server.stop();
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kError});
}

// ================================================================== 集成测试（真实 sshd）

TEST(SshSessionIntegrationTest, HandshakeReachesAuthenticatingThenGracefulClose)
{
    std::string rt;
    const std::string sshd = RequireSshd(&rt);
    if (sshd.empty()) {
        GTEST_SKIP() << "找不到可用 sshd（跑 scripts/setup-host-deps.sh 或设 SSH_TESTS_SSHD）";
    }
    SshdInstance sshdInst = StartSshd(sshd, rt);
    if (sshdInst.pid <= 0) {
        GTEST_SKIP() << "sshd 启动失败（端口竞态或配置不兼容），跳过集成用例";
    }

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));

        // N6 边界：握手 + 算法协商完成，进入「待认证」
        ASSERT_TRUE(rec.waitFor(SshSessionState::kAuthenticating, 20s));
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);
        EXPECT_EQ(session.lastError(), SshSessionError::kNone);

        // 优雅关闭：authenticating → closing → closed
        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        thread.stop();
    }
    StopSshd(sshdInst);
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kClosing,
                         SshSessionState::kClosed});
}

TEST(SshSessionIntegrationTest, ServerKilledLeadsToDisconnectedWithin30s)
{
    std::string rt;
    const std::string sshd = RequireSshd(&rt);
    if (sshd.empty()) {
        GTEST_SKIP() << "找不到可用 sshd（跑 scripts/setup-host-deps.sh 或设 SSH_TESTS_SSHD）";
    }
    SshdInstance sshdInst = StartSshd(sshd, rt);
    if (sshdInst.pid <= 0) {
        GTEST_SKIP() << "sshd 启动失败（端口竞态或配置不兼容），跳过集成用例";
    }

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kAuthenticating, 20s));

        // 模拟「拔线/RST」：SIGKILL 辅助 sshd 的整个进程组（-d 模式对接受的连接会
        // re-exec 出子进程，只杀监听进程连接还活着）——其 socket 由内核发送 RST，
        // 客户端必须按验收标准在 30 s 内进入 disconnected 而非卡死（实测毫秒级）。
        // 说明：静默黑洞（拔网线无 RST）场景的检测靠 keepalive，属 N12 范围。
        const auto begin = std::chrono::steady_clock::now();
        ASSERT_EQ(::kill(-sshdInst.pid, SIGKILL), 0);
        ::waitpid(sshdInst.pid, nullptr, 0);
        sshdInst.pid = -1;

        ASSERT_TRUE(rec.waitFor(SshSessionState::kDisconnected, 30s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;
        std::fprintf(stderr, "[test] kill sshd → disconnected 耗时 %lld ms（验收线 30000 ms）\n",
                     static_cast<long long>(
                         std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count()));
        EXPECT_LT(elapsed, 30s);
        EXPECT_TRUE(session.lastError() == SshSessionError::kDisconnectedByPeer ||
                    session.lastError() == SshSessionError::kSocketError)
            << "意外错误码: " << sshclient::ssh::toString(session.lastError());
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kDisconnected});
}
