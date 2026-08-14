/**
 * keepalive 静默黑洞判定 —— 任务 N12 的可测纯逻辑单元（判定口径见下）。
 *
 * 背景（N6 遗留语义）：socket ERR / 对端 FIN / RST 由 epoll 事件秒级捕获；
 * 「拔网线无 RST」的静默黑洞不会有任何 fd 事件，只能靠 keepalive 周期探测。
 * libssh2 只提供 libssh2_keepalive_config + libssh2_keepalive_send（want_reply=1 时
 * 发 SSH_MSG_GLOBAL_REQUEST 要求对端应答），**没有内建的无应答计数与断线判定**
 * （已核对 1.11.1 源码 keepalive.c），计数与判定由本文件承担。
 *
 * 判定口径（session.cpp onKeepaliveTick 使用，近似性如实说明）：
 *   每个 keepalive 周期观测一次「本周期内是否有任何入站活动」：
 *     - 信号 1：established 态 fd 事件里出现过 EPOLLIN（有通道时通道泵送会随即
 *       抽干 socket，这一信号覆盖正常业务流量）；
 *     - 信号 2：socket 待读字节数（FIONREAD）较上一周期增加（无通道时 keepalive
 *       应答包无人消费、留在内核缓冲，字节数增长即证明对端应答过）。
 *     两者取或——近似点在于它证明的是「上个周期内对端曾发来字节」，并不逐一核对
 *     哪字节是 keepalive 应答；对保活判定这一目的足够且不会把单向出站流量误判为
 *     存活（出站不算入站）。
 *   连续 keepaliveMaxMisses 个周期无任何入站活动 → 判黑洞（tick 返回 true），
 *   会话以 kKeepaliveTimeout 进 disconnected。maxMisses == 0 = 只发不判
 *   （保留 NAT/防火墙会话刷新的流量价值，放弃本端黑洞检测）。
 *
 * 纯逻辑：只依赖 C++ 标准库，宿主机 GoogleTest 直接断言（tests/reconnect_policy_test.cpp）。
 */
#pragma once

namespace sshclient {
namespace ssh {

// 入站活动观测合并：fd 事件标志 或 待读字节数增长（纯函数，便于逐分支断言）
inline bool keepaliveInboundObserved(bool epollInSeen, long pendingBytesNow,
                                     long pendingBytesBaseline)
{
    return epollInSeen || pendingBytesNow > pendingBytesBaseline;
}

// 连续无入站周期计数器：tick(hadInbound) 每个 keepalive 周期调用一次，
// 返回 true = 达到阈值，应判黑洞断线
class KeepaliveMissTracker {
public:
    // maxMisses == 0：判定关闭（tick 恒返回 false）
    explicit KeepaliveMissTracker(unsigned maxMisses) : maxMisses_(maxMisses) {}

    bool tick(bool hadInbound)
    {
        if (hadInbound) {
            misses_ = 0;
            return false;
        }
        if (maxMisses_ == 0) {
            return false; // 只发不判
        }
        ++misses_;
        return misses_ >= maxMisses_;
    }

    unsigned misses() const { return misses_; }
    unsigned maxMisses() const { return maxMisses_; }
    void reset() { misses_ = 0; }

private:
    unsigned maxMisses_;
    unsigned misses_ = 0;
};

} // namespace ssh
} // namespace sshclient
