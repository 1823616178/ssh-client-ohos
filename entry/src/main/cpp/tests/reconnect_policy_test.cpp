/**
 * N12 纯逻辑测试 —— 「keepalive 与自动重连策略」的宿主可测部分。
 *
 * 覆盖：
 *   BackoffSchedule（ssh/reconnect_policy.h）：
 *     - 默认序列 1/2/5/10/20/30 逐档断言；越界钳到最后档；attempt=0 防御性按 1 处理
 *     - 默认上限 6 次：1..6 不放弃、7 起放弃
 *     - 无限模式（maxAttempts=0）：永不放弃、延迟恒钳 30 s
 *     - 自定义序列与上限；空序列回落默认；上限大于序列长度时延迟钳制仍生效
 *   KeepaliveMissTracker / keepaliveInboundObserved（ssh/keepalive.h）：
 *     - 连续无入站达到阈值判黑洞；有入站即清零；maxMisses=0 只发不判；1 = 一次即判
 *     - 入站观测合并：fd 事件标志 / 待读字节增长 两信号取或
 *   KeepaliveProbe（ssh/keepalive.h，P1 网络切换主动探测的判定窗口）：
 *     - 开窗/关窗与基线记录；到期裁决与周期判定同信号；重开窗即换基线
 *     - 「libssh2 跳过本次发送」时沿用旧基线，在途应答仍算存活证据
 *   isAutoReconnectable（ssh/session.h）：
 *     - disconnected 一律可重连；error 按链路类/凭据类分；closed 与非终态不可
 *   SshSessionOptions 默认值（30 s / 3 次，DESIGN §7.1）
 *
 * 黑洞判定的正向触发（真静默断线）无法在宿主机无 root 环境模拟
 * （loopback 无法制造「收不到 RST 的静默丢包」），故判定逻辑全部落在上述
 * 纯函数单测；集成侧只覆盖「keepalive 正常收发不误判」（tests/keepalive_test.cpp）。
 */
#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "ssh/keepalive.h"
#include "ssh/reconnect_policy.h"
#include "ssh/session.h"

using sshclient::ssh::BackoffSchedule;
using sshclient::ssh::KeepaliveMissTracker;
using sshclient::ssh::KeepaliveProbe;
using sshclient::ssh::SshSessionError;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;
using sshclient::ssh::isAutoReconnectable;
using sshclient::ssh::keepaliveInboundObserved;

namespace {

// ================================================================== BackoffSchedule

TEST(BackoffScheduleTest, DefaultSequenceStepByStep)
{
    const BackoffSchedule s;
    // DESIGN §7.1 的默认序列逐档断言（attempt 从 1 计）
    EXPECT_EQ(s.delayForAttempt(1), 1u);
    EXPECT_EQ(s.delayForAttempt(2), 2u);
    EXPECT_EQ(s.delayForAttempt(3), 5u);
    EXPECT_EQ(s.delayForAttempt(4), 10u);
    EXPECT_EQ(s.delayForAttempt(5), 20u);
    EXPECT_EQ(s.delayForAttempt(6), 30u);
    // 越界钳到最后档（30 s 封顶）
    EXPECT_EQ(s.delayForAttempt(7), 30u);
    EXPECT_EQ(s.delayForAttempt(100), 30u);
    // 防御：attempt=0 按第 1 次处理
    EXPECT_EQ(s.delayForAttempt(0), 1u);
    // 默认上限与序列内容
    EXPECT_EQ(s.maxAttempts(), 6u);
    EXPECT_EQ(s.delaysSec(), (std::vector<uint32_t>{1, 2, 5, 10, 20, 30}));
}

TEST(BackoffScheduleTest, GiveUpBoundaryAtDefaultMaxAttempts)
{
    const BackoffSchedule s; // maxAttempts = 6
    for (uint32_t attempt = 1; attempt <= 6; ++attempt) {
        EXPECT_FALSE(s.shouldGiveUp(attempt)) << "attempt=" << attempt;
    }
    EXPECT_TRUE(s.shouldGiveUp(7));
    EXPECT_TRUE(s.shouldGiveUp(100));
}

TEST(BackoffScheduleTest, InfiniteModeNeverGivesUp)
{
    const BackoffSchedule s({}, 0); // 空序列 + 0 = 无限
    EXPECT_FALSE(s.shouldGiveUp(1));
    EXPECT_FALSE(s.shouldGiveUp(6));
    EXPECT_FALSE(s.shouldGiveUp(1000));
    // 延迟仍按默认序列钳制
    EXPECT_EQ(s.delayForAttempt(1), 1u);
    EXPECT_EQ(s.delayForAttempt(6), 30u);
    EXPECT_EQ(s.delayForAttempt(1000), 30u);
}

TEST(BackoffScheduleTest, CustomSequenceAndClamp)
{
    const BackoffSchedule s({3, 9}, 2);
    EXPECT_EQ(s.delayForAttempt(1), 3u);
    EXPECT_EQ(s.delayForAttempt(2), 9u);
    // 次数超出序列长度：钳到最后一档
    EXPECT_EQ(s.delayForAttempt(3), 9u);
    // 上限 2：第 3 次放弃
    EXPECT_FALSE(s.shouldGiveUp(2));
    EXPECT_TRUE(s.shouldGiveUp(3));
}

TEST(BackoffScheduleTest, MaxAttemptsBeyondSequenceLength)
{
    const BackoffSchedule s({1, 2}, 5);
    EXPECT_EQ(s.delayForAttempt(1), 1u);
    EXPECT_EQ(s.delayForAttempt(2), 2u);
    EXPECT_EQ(s.delayForAttempt(3), 2u);
    EXPECT_EQ(s.delayForAttempt(5), 2u);
    EXPECT_FALSE(s.shouldGiveUp(5));
    EXPECT_TRUE(s.shouldGiveUp(6));
}

TEST(BackoffScheduleTest, EmptySequenceFallsBackToDefault)
{
    const BackoffSchedule s({}, 4);
    EXPECT_EQ(s.delaysSec(), BackoffSchedule::defaultDelaysSec());
    EXPECT_EQ(s.delayForAttempt(1), 1u);
    EXPECT_EQ(s.maxAttempts(), 4u);
}

TEST(BackoffScheduleTest, ZeroDelayEntryAllowed)
{
    // 0 秒档合法（首档立即重试的用法）
    const BackoffSchedule s({0, 5}, 2);
    EXPECT_EQ(s.delayForAttempt(1), 0u);
    EXPECT_EQ(s.delayForAttempt(2), 5u);
}

// ================================================================== KeepaliveMissTracker

TEST(KeepaliveMissTrackerTest, ConsecutiveSilenceReachesThreshold)
{
    KeepaliveMissTracker t(3);
    EXPECT_FALSE(t.tick(false)); // miss 1
    EXPECT_EQ(t.misses(), 1u);
    EXPECT_FALSE(t.tick(false)); // miss 2
    EXPECT_TRUE(t.tick(false));  // miss 3 → 判黑洞
    EXPECT_EQ(t.misses(), 3u);
}

TEST(KeepaliveMissTrackerTest, InboundResetsCounter)
{
    KeepaliveMissTracker t(3);
    EXPECT_FALSE(t.tick(false));
    EXPECT_FALSE(t.tick(false));
    EXPECT_FALSE(t.tick(true)); // 有入站 → 清零
    EXPECT_EQ(t.misses(), 0u);
    // 重新计满 3 次才判
    EXPECT_FALSE(t.tick(false));
    EXPECT_FALSE(t.tick(false));
    EXPECT_TRUE(t.tick(false));
}

TEST(KeepaliveMissTrackerTest, ZeroMaxMissesDisablesJudgement)
{
    KeepaliveMissTracker t(0); // 只发不判
    for (int i = 0; i < 10; ++i) {
        EXPECT_FALSE(t.tick(false));
    }
}

TEST(KeepaliveMissTrackerTest, OneMaxMissJudgesImmediately)
{
    KeepaliveMissTracker t(1);
    EXPECT_TRUE(t.tick(false));
}

TEST(KeepaliveMissTrackerTest, ResetClearsCounter)
{
    KeepaliveMissTracker t(3);
    t.tick(false);
    t.tick(false);
    t.reset();
    EXPECT_EQ(t.misses(), 0u);
    EXPECT_FALSE(t.tick(false));
}

// ================================================================== 入站观测合并

TEST(KeepaliveInboundObservedTest, EventFlagOrPendingGrowth)
{
    // 有 EPOLLIN 事件：无论字节数如何都算有入站
    EXPECT_TRUE(keepaliveInboundObserved(true, 0, 0));
    EXPECT_TRUE(keepaliveInboundObserved(true, 48, 48));
    // 无事件时看待读字节增长（无通道场景的 keepalive 应答留在内核缓冲）
    EXPECT_TRUE(keepaliveInboundObserved(false, 96, 48));
    // 无事件且字节数不涨（含持平/回落）→ 无入站
    EXPECT_FALSE(keepaliveInboundObserved(false, 48, 48));
    EXPECT_FALSE(keepaliveInboundObserved(false, 0, 48));
    EXPECT_FALSE(keepaliveInboundObserved(false, 0, 0));
}

// ================================================================== KeepaliveProbe（P1 探测窗口）

TEST(KeepaliveProbeTest, InactiveUntilArmed)
{
    KeepaliveProbe probe;
    EXPECT_FALSE(probe.active());
    probe.arm(48);
    EXPECT_TRUE(probe.active());
    EXPECT_EQ(probe.baseline(), 48);
    probe.disarm();
    EXPECT_FALSE(probe.active());
    EXPECT_EQ(probe.baseline(), 48); // disarm 只关窗，基线保留供到期裁决读取
}

TEST(KeepaliveProbeTest, VerdictFollowsInboundObservation)
{
    KeepaliveProbe probe;
    probe.arm(48);
    // 窗口内有 EPOLLIN（有通道时探测应答被通道泵送抽干）→ 存活
    EXPECT_TRUE(probe.verdictAlive(true, 48));
    // 无事件但待读字节增长（无通道时应答留在内核缓冲）→ 存活
    EXPECT_TRUE(probe.verdictAlive(false, 96));
    // 无事件且字节数不涨（含回落）→ 黑洞：切网后旧 socket 收不到任何应答的典型形态
    EXPECT_FALSE(probe.verdictAlive(false, 48));
    EXPECT_FALSE(probe.verdictAlive(false, 0));
}

TEST(KeepaliveProbeTest, RearmResetsBaseline)
{
    KeepaliveProbe probe;
    probe.arm(48);
    EXPECT_FALSE(probe.verdictAlive(false, 48));
    // 第二次探测以新基线开窗：同样的 96 字节，相对新基线不再算增长
    probe.arm(96);
    EXPECT_EQ(probe.baseline(), 96);
    EXPECT_FALSE(probe.verdictAlive(false, 96));
    EXPECT_TRUE(probe.verdictAlive(false, 97));
}

TEST(KeepaliveProbeTest, StaleBaselineKeepsInFlightReplyAsEvidence)
{
    // session.cpp doProbeNow 的 willSend == false 分支：libssh2 会跳过本次发送时
    // 沿用旧基线，上一拍应答落地即算存活证据（重置基线会把它抹掉造成误判）
    KeepaliveProbe probe;
    const long staleBaseline = 48;
    probe.arm(staleBaseline);
    EXPECT_TRUE(probe.verdictAlive(false, 64)); // 上一拍的应答落在窗口内
}

TEST(KeepaliveProbeTest, DefaultTimeoutMatchesAcceptance)
{
    // TASKS.md P1「WiFi ⇄ 蜂窝切换 5 s 内触发重连」
    EXPECT_EQ(sshclient::ssh::kDefaultKeepaliveProbeTimeoutSec, 5u);
    // libssh2 1.11.1 keepalive.c 的最小周期（doProbeNow 借它逼出发送）
    EXPECT_EQ(sshclient::ssh::kLibssh2MinKeepaliveIntervalSec, 2u);
}

// ================================================================== isAutoReconnectable

TEST(AutoReconnectableTest, DisconnectedAlwaysReconnectable)
{
    using E = SshSessionError;
    EXPECT_TRUE(isAutoReconnectable(SshSessionState::kDisconnected, E::kDisconnectedByPeer));
    EXPECT_TRUE(isAutoReconnectable(SshSessionState::kDisconnected, E::kSocketError));
    EXPECT_TRUE(isAutoReconnectable(SshSessionState::kDisconnected, E::kKeepaliveTimeout));
    EXPECT_TRUE(isAutoReconnectable(SshSessionState::kDisconnected, E::kNone));
}

TEST(AutoReconnectableTest, ErrorStateClassifiedByCode)
{
    using E = SshSessionError;
    const SshSessionState kErr = SshSessionState::kError;
    // 链路类（瞬态网络问题）：可重连
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kResolveFailed));
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kConnectFailed));
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kConnectUnreachable)); // N13：不可达多为瞬态网络
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kConnectTimeout));
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kHandshakeFailed));
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kHandshakeTimeout));
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kSocketError));
    EXPECT_TRUE(isAutoReconnectable(kErr, E::kAuthTimeout));
    // 凭据类、协商类与本端资源问题：重连无益
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kAuthFailedPassword));
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kAuthFailedKey));
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kAuthFailedPassphrase));
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kAuthFailedInteractive));
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kAlgorithmNegotiationFailed)); // N13
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kInternal));
    EXPECT_FALSE(isAutoReconnectable(kErr, E::kHostKeyMismatch));
}

TEST(AutoReconnectableTest, ClosedAndNonTerminalNotReconnectable)
{
    using E = SshSessionError;
    EXPECT_FALSE(isAutoReconnectable(SshSessionState::kClosed, E::kNone));
    EXPECT_FALSE(isAutoReconnectable(SshSessionState::kClosed, E::kHostKeyMismatch));
    EXPECT_FALSE(isAutoReconnectable(SshSessionState::kEstablished, E::kNone));
    EXPECT_FALSE(isAutoReconnectable(SshSessionState::kConnecting, E::kConnectTimeout));
}

// ================================================================== 选项默认值（DESIGN §7.1）

TEST(KeepaliveOptionsTest, DefaultsMatchDesign)
{
    const SshSessionOptions opts;
    EXPECT_EQ(opts.keepaliveIntervalSec, 30u);
    EXPECT_EQ(opts.keepaliveMaxMisses, 3u);
}

} // namespace
