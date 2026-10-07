/**
 * N12 keepalive 集成测试 —— 真实 sshd 环境下的会话侧行为。
 *
 * 覆盖：
 *   - setKeepaliveConfig 受理语义：仅 idle 态受理（connect 前可调，进入
 *     connecting/error/established 后一律拒绝）——不需要 sshd；
 *   - keepalive 正常收发不误判：established 后按 1 s（libssh2 内部提升为 2 s
 *     最小间隔，见 session.cpp armKeepalive 注）周期跑 ~2 拍，发送计数增长、
 *     miss 计数恒 0、状态保持 established——真实 sshd 会对 keepalive 全局请求
 *     回 REQUEST_FAILURE/SUCCESS，入站观测（本用例无通道，走 FIONREAD 增长信号）
 *     必须持续判活；
 *   - keepaliveIntervalSec=0 完全关闭：established 后无任何发送。
 *
 * 黑洞判定的正向触发（静默丢包）在无 root 的宿主机上无法对 loopback 模拟，
 * 判定逻辑由纯逻辑单测覆盖（tests/reconnect_policy_test.cpp 的
 * KeepaliveMissTracker / keepaliveInboundObserved）；RST/FIN 快速断线路径
 * 已由 N6 用例（ServerKilledLeadsToDisconnectedWithin30s 等）覆盖。
 */
#include <gtest/gtest.h>

#include <chrono>
#include <thread>

#include "io/SessionThread.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using sshclient::io::SessionThread;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionError;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;

namespace {

// ================================================================== 配置受理语义（无需 sshd）

TEST(KeepaliveConfigTest, SetKeepaliveConfigOnlyInIdle)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.connectTimeoutMs = 1500;
        opts.handshakeTimeoutMs = 2000;
        SshSession session(thread, opts, std::ref(rec));
        // idle 态受理
        EXPECT_TRUE(session.setKeepaliveConfig(5, 2));

        // 连一个必然拒绝的端口（刚释放的空闲端口）：connecting → error
        const uint16_t port = PickFreePort();
        ASSERT_TRUE(session.connect("127.0.0.1", port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 8s));

        // 非 idle（终态）一律拒绝
        EXPECT_FALSE(session.setKeepaliveConfig(10, 5));
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kError});
}

// ================================================================== 集成测试（真实 sshd + 认证环境）

TEST(KeepaliveIntegrationTest, KeepaliveRunsWithoutFalsePositive)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        // connect 前配置：1 s 周期（libssh2 内部提升为 2 s 最小间隔）、3 次判黑洞
        ASSERT_TRUE(session.setKeepaliveConfig(1, 3));

        ASSERT_TRUE(ReachEstablished(session, rec, env));

        // established 后配置不再受理
        EXPECT_FALSE(session.setKeepaliveConfig(5, 2));

        // 等 ~2 个完整 keepalive 拍（t≈1s 首拍，之后按 seconds_to_next=2s 逐拍）
        std::this_thread::sleep_for(4600ms);

        // 发送计数在涨（≥2 拍），miss 恒 0（对端正常应答），状态保持 established
        EXPECT_GE(session.keepaliveSendCount(), 2u);
        EXPECT_EQ(session.keepaliveMissCount(), 0u);
        EXPECT_EQ(session.state(), SshSessionState::kEstablished);
        EXPECT_FALSE(rec.visited(SshSessionState::kDisconnected))
            << "keepalive 误判导致断线，lastError="
            << sshclient::ssh::toString(session.lastError());

        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        thread.stop();
    }
}

TEST(KeepaliveIntegrationTest, DisabledKeepaliveSendsNothing)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.keepaliveIntervalSec = 0; // 关闭
        SshSession session(thread, opts, std::ref(rec));

        ASSERT_TRUE(ReachEstablished(session, rec, env));

        std::this_thread::sleep_for(1200ms);
        EXPECT_EQ(session.keepaliveSendCount(), 0u);
        EXPECT_EQ(session.keepaliveMissCount(), 0u);
        EXPECT_EQ(session.state(), SshSessionState::kEstablished);

        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        thread.stop();
    }
}

} // namespace
