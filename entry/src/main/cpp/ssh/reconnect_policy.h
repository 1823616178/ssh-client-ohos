/**
 * 自动重连退避策略 —— 任务 N12「keepalive 与自动重连策略」的纯逻辑件。
 *
 * 架构分工（任务约定）：重连编排整体在 ArkTS 侧（SessionManager，任务 C4）——
 * 重连要新建 socket 与会话，由持有 HostProfile 的上层决定何时重建；native 不自己
 * 做重连循环。本文件只提供「第 n 次重连该等多久、何时放弃」的纯计算，经 bridge 的
 * setReconnectPolicy / nextReconnectDelaySec 暴露给 ArkTS（session_bridge.cpp），
 * 由上层在 stateChange(disconnected, reconnectHint=true) 后逐次查询并自行倒计时。
 *
 * 语义（DESIGN §7.1）：
 *   - 默认退避序列 1/2/5/10/20/30 秒；attempt 从 1 开始计（第 1 次重连前等 1 s）；
 *   - 次数超出序列长度时钳到最后档（默认 30 s 封顶）；
 *   - 最大尝试次数默认 6（与默认序列 6 档对齐：6 次尝试的等待恰好走完整个序列），
 *     0 = 无限重试（永不放弃）；
 *   - shouldGiveUp(attempt) 判定的是「即将发起的第 attempt 次重连是否还应进行」：
 *     attempt > maxAttempts（非无限模式）时放弃。
 *
 * 纯逻辑：只依赖 C++ 标准库，可在宿主机 GoogleTest 直接断言（tests/reconnect_policy_test.cpp）。
 */
#pragma once

#include <cstdint>
#include <vector>

namespace sshclient {
namespace ssh {

class BackoffSchedule {
public:
    // 默认退避序列（DESIGN §7.1）：1→2→5→10→20→30 秒
    static const std::vector<uint32_t> &defaultDelaysSec()
    {
        static const std::vector<uint32_t> kDefault{1, 2, 5, 10, 20, 30};
        return kDefault;
    }
    // 默认最大尝试次数：6（与默认序列档数一致）；0 = 无限
    static constexpr uint32_t kDefaultMaxAttempts = 6;

    BackoffSchedule() : delays_(defaultDelaysSec()), maxAttempts_(kDefaultMaxAttempts) {}

    // delaysSec 为空序列时回落到默认序列（防御：空序列无法给出任何延迟档位）；
    // 序列元素为秒数，允许 0（立即重试档）；maxAttempts 0 = 无限重试
    explicit BackoffSchedule(std::vector<uint32_t> delaysSec,
                             uint32_t maxAttempts = kDefaultMaxAttempts)
        : delays_(delaysSec.empty() ? defaultDelaysSec() : std::move(delaysSec)),
          maxAttempts_(maxAttempts)
    {
    }

    // 第 attempt 次重连前的建议等待秒数。attempt 从 1 开始；传 0 按第 1 次处理
    // （防御性钳制）；超出序列长度钳到最后档。本函数不判定放弃与否——
    // 调用方应先问 shouldGiveUp（bridge 的 nextReconnectDelaySec 已把两者合并：
    // 应放弃时返回 -1，不再查询本函数）
    uint32_t delayForAttempt(uint32_t attempt) const
    {
        if (attempt < 1) {
            attempt = 1;
        }
        const size_t idx = attempt - 1;
        return idx < delays_.size() ? delays_[idx] : delays_.back();
    }

    // 即将发起的第 attempt 次重连是否应放弃（已达上限）。
    // 无限模式（maxAttempts == 0）永不放弃
    bool shouldGiveUp(uint32_t attempt) const
    {
        return maxAttempts_ != 0 && attempt > maxAttempts_;
    }

    uint32_t maxAttempts() const { return maxAttempts_; }
    const std::vector<uint32_t> &delaysSec() const { return delays_; }

private:
    std::vector<uint32_t> delays_;
    uint32_t maxAttempts_;
};

} // namespace ssh
} // namespace sshclient
