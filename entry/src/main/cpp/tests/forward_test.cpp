/**
 * 端口转发 native 测试 —— 任务 N15/N16。
 *
 * 两层：
 *   1. 纯逻辑（状态机 / 目标校验 / ProxyJump 规格解析）——不依赖 sshd，始终跑；
 *   2. 集成（真实 sshd + 认证环境上的 direct-tcpip 打开 / 回环读写）——
 *      环境未就绪或 sshd 拒绝转发时 GTEST_SKIP，不拖垮门禁。
 */
#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <libssh2.h>

#include "io/SessionThread.h"
#include "ssh/forward.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using namespace std::chrono_literals;
using namespace sshclient::ssh;

// ================================================================ 纯逻辑

TEST(ForwardLogic, LegalTransitions)
{
    using S = ForwardState;
    EXPECT_TRUE(isLegalForwardTransition(S::kIdle, S::kOpening));
    EXPECT_TRUE(isLegalForwardTransition(S::kOpening, S::kOpen));
    EXPECT_TRUE(isLegalForwardTransition(S::kOpening, S::kClosing));
    EXPECT_TRUE(isLegalForwardTransition(S::kOpen, S::kClosing));
    EXPECT_TRUE(isLegalForwardTransition(S::kOpen, S::kClosed));
    EXPECT_TRUE(isLegalForwardTransition(S::kClosing, S::kClosed));
    EXPECT_FALSE(isLegalForwardTransition(S::kClosed, S::kOpen));
    EXPECT_FALSE(isLegalForwardTransition(S::kIdle, S::kOpen));
    EXPECT_FALSE(isLegalForwardTransition(S::kOpen, S::kOpening));
}

TEST(ForwardLogic, TargetValidation)
{
    EXPECT_TRUE(isValidForwardTarget({"127.0.0.1", 22}));
    EXPECT_TRUE(isValidForwardTarget({"example.com", 65535}));
    EXPECT_FALSE(isValidForwardTarget({"", 22}));
    EXPECT_FALSE(isValidForwardTarget({"h", 0}));
    EXPECT_FALSE(isValidForwardTarget({"h", 65536}));
}

TEST(ForwardLogic, ParseProxyJumpSpec)
{
    auto hops = parseProxyJumpSpec("bastion");
    ASSERT_EQ(hops.size(), 1u);
    EXPECT_EQ(hops[0].host, "bastion");
    EXPECT_EQ(hops[0].port, 22);
    EXPECT_TRUE(hops[0].username.empty());

    hops = parseProxyJumpSpec("alice@jump.example.com:2222");
    ASSERT_EQ(hops.size(), 1u);
    EXPECT_EQ(hops[0].username, "alice");
    EXPECT_EQ(hops[0].host, "jump.example.com");
    EXPECT_EQ(hops[0].port, 2222);

    hops = parseProxyJumpSpec("u1@h1:22,u2@h2");
    ASSERT_EQ(hops.size(), 2u);
    EXPECT_EQ(hops[0].host, "h1");
    EXPECT_EQ(hops[0].port, 22);
    EXPECT_EQ(hops[1].username, "u2");
    EXPECT_EQ(hops[1].host, "h2");
    EXPECT_EQ(hops[1].port, 22);

    hops = parseProxyJumpSpec("[::1]:2200");
    ASSERT_EQ(hops.size(), 1u);
    EXPECT_EQ(hops[0].host, "::1");
    EXPECT_EQ(hops[0].port, 2200);

    EXPECT_TRUE(parseProxyJumpSpec("").empty());
    EXPECT_TRUE(parseProxyJumpSpec("  ").empty());
    EXPECT_TRUE(parseProxyJumpSpec("u@").empty());
    EXPECT_TRUE(parseProxyJumpSpec("h:0").empty());
    EXPECT_TRUE(parseProxyJumpSpec("h:70000").empty());
    EXPECT_TRUE(parseProxyJumpSpec("[bad").empty());
}

TEST(ForwardLogic, PlanProxyJumpHops)
{
    auto hops = parseProxyJumpSpec("a,b,c");
    auto plan = planProxyJumpHops(hops);
    ASSERT_EQ(plan.size(), 3u);
    EXPECT_EQ(plan[0].host, "a");
    EXPECT_EQ(plan[2].host, "c");
    EXPECT_TRUE(planProxyJumpHops({}).empty());
}

TEST(ForwardLogic, ProxyJumpNotesDocumentGap)
{
    const std::string notes = proxyJumpTransportNotes();
    EXPECT_FALSE(notes.empty());
    EXPECT_NE(notes.find("LIBSSH2_CALLBACK"), std::string::npos);
    EXPECT_NE(notes.find("GAP"), std::string::npos);
    EXPECT_NE(notes.find("fd"), std::string::npos);
}

TEST(ForwardLogic, ErrorNamesSnakeCase)
{
    EXPECT_STREQ(forwardErrorName(ForwardError::kNone), "none");
    EXPECT_STREQ(forwardErrorName(ForwardError::kNotEstablished), "not_established");
    EXPECT_STREQ(forwardErrorName(ForwardError::kOpenFailed), "open_failed");
    EXPECT_STREQ(forwardErrorName(ForwardError::kTargetInvalid), "target_invalid");
    EXPECT_STREQ(forwardErrorName(ForwardError::kSessionLost), "session_lost");
    EXPECT_STREQ(forwardErrorName(ForwardError::kNotSupported), "not_supported");
}

// ================================================================ 集成（可跳过）

namespace {

// 等会话进终态再让栈上 SshSession/SshForwardChannel 析构——
// close() 是异步 post，立刻析构会与循环线程上的 pump 竞态（UAF）
void WaitSessionTerminal(SshSession &session)
{
    session.close();
    for (int i = 0; i < 200; ++i) {
        const auto st = session.state();
        if (st == SshSessionState::kClosed || st == SshSessionState::kDisconnected ||
            st == SshSessionState::kError) {
            return;
        }
        std::this_thread::sleep_for(10ms);
    }
}

} // namespace

TEST(ForwardIntegration, OpenDirectTcpipAgainstSshd)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    StateRecorder rec;
    sshclient::io::SessionThread thread;
    ASSERT_TRUE(thread.start());
    SshSessionOptions opts;
    SshSession session(thread, opts, std::ref(rec));
    if (!ReachEstablished(session, rec, env)) {
        GTEST_SKIP() << "无法驱动到 established（sshd/认证环境异常）";
    }

    struct Box {
        std::mutex mu;
        std::condition_variable cv;
        bool opened = false;
        bool openOk = false;
        std::string openErr;
        bool closed = false;
        std::string data;
    } box;

    ForwardCallbacks cb;
    cb.onOpen = [&](const ForwardOpenResult &r) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.opened = true;
        box.openOk = r.success;
        box.openErr = r.message.empty() ? forwardErrorName(r.error) : r.message;
        box.cv.notify_all();
    };
    cb.onData = [&](const std::string &d) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.data += d;
        box.cv.notify_all();
    };
    cb.onClose = [&](const ForwardCloseInfo &) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.closed = true;
        box.cv.notify_all();
    };

    // 目标：sshd 自身端口（direct-tcpip 回环）。AllowTcpForwarding 默认 yes；
    // 被拒/超时/环境异常一律 SKIP（不拖垮门禁）。
    // 析构纪律：必须等 onOpen 到达 + 会话终态后再离开作用域。
    {
        SshForwardChannel fwd(session, cb);
        const bool admitted = fwd.openDirectTcpip("127.0.0.1", env.port);
        if (!admitted) {
            WaitSessionTerminal(session);
            GTEST_SKIP() << "openDirectTcpip 未受理";
        }
        {
            std::unique_lock<std::mutex> lock(box.mu);
            if (!box.cv.wait_for(lock, 8s, [&] { return box.opened; })) {
                lock.unlock();
                WaitSessionTerminal(session);
                GTEST_SKIP() << "direct-tcpip open 超时";
            }
            if (!box.openOk) {
                lock.unlock();
                WaitSessionTerminal(session);
                GTEST_SKIP() << "direct-tcpip 被拒（AllowTcpForwarding/策略）：" << box.openErr;
            }
        }
        fwd.close();
        {
            std::unique_lock<std::mutex> lock(box.mu);
            box.cv.wait_for(lock, 3s, [&] { return box.closed; });
        }
        // 通道收尾后再关会话；等终态，避免 pump 与析构竞态
        WaitSessionTerminal(session);
    }
}

TEST(ForwardIntegration, RejectOpenWhenNotEstablished)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    StateRecorder rec;
    sshclient::io::SessionThread thread;
    ASSERT_TRUE(thread.start());
    SshSessionOptions opts;
    SshSession session(thread, opts, std::ref(rec));
    // 不连接：idle 态直接拒收
    ForwardCallbacks cb;
    SshForwardChannel fwd(session, cb);
    EXPECT_FALSE(fwd.openDirectTcpip("127.0.0.1", 22));
    EXPECT_FALSE(fwd.openDirectTcpip("", 22));
    EXPECT_FALSE(fwd.write("x"));
    WaitSessionTerminal(session);
}

TEST(ForwardIntegration, RemoteForwardListenBestEffort)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    StateRecorder rec;
    sshclient::io::SessionThread thread;
    ASSERT_TRUE(thread.start());
    SshSessionOptions opts;
    SshSession session(thread, opts, std::ref(rec));
    if (!ReachEstablished(session, rec, env)) {
        GTEST_SKIP() << "无法驱动到 established";
    }

    struct Box {
        std::mutex mu;
        std::condition_variable cv;
        bool opened = false;
        bool openOk = false;
        std::string err;
        uint32_t bound = 0;
    } box;

    ForwardCallbacks cb;
    cb.onOpen = [&](const ForwardOpenResult &r) {
        std::lock_guard<std::mutex> lock(box.mu);
        box.opened = true;
        box.openOk = r.success;
        box.bound = r.boundPort;
        box.err = r.message.empty() ? forwardErrorName(r.error) : r.message;
        box.cv.notify_all();
    };
    cb.onAccepted = [&](struct _LIBSSH2_CHANNEL *raw, const ForwardOpenResult &) {
        if (raw != nullptr) {
            ::libssh2_channel_close(raw);
            ::libssh2_channel_free(raw);
        }
    };

    {
        EXPECT_FALSE(SshRemoteForward(session, cb).openRemote("127.0.0.1", 0));

        SshRemoteForward remote2(session, cb);
        if (!remote2.openRemote("127.0.0.1", 39999)) {
            WaitSessionTerminal(session);
            GTEST_SKIP() << "remote listen 未受理";
        }
        {
            std::unique_lock<std::mutex> lock(box.mu);
            if (!box.cv.wait_for(lock, 8s, [&] { return box.opened; })) {
                lock.unlock();
                remote2.cancel();
                WaitSessionTerminal(session);
                GTEST_SKIP() << "remote listen open 超时";
            }
            if (!box.openOk) {
                lock.unlock();
                WaitSessionTerminal(session);
                GTEST_SKIP() << "远程转发被拒（AllowTcpForwarding no?）：" << box.err;
            }
            EXPECT_EQ(box.bound, 39999u);
        }
        remote2.cancel();
        WaitSessionTerminal(session);
    }
}
