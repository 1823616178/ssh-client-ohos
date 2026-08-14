/**
 * 通道数据聚合器 —— 任务 N11「NAPI 桥接层」的纯逻辑部分（宿主可测）。
 *
 * 背景（DESIGN §2.1/§2.2 的数据通路约束与 M1 出口之间的折中，本注释即约定记录）：
 *   架构约束是「native → ArkTS 只投递轻量事件，不投递终端字节流」，终端主路径
 *   应由 T3 的零拷贝网格快照承载。但 M1 里程碑出口要求「命令行式最小界面看到
 *   原始输出」，而 T3 还没做——故本桥接层临时经 TSFN 投递 channel 数据，
 *   **必须聚合**：循环线程内累积，达到 flushBytes（默认 16 KiB）立即发一批，
 *   否则距批次首字节超过 flushIntervalMs（默认 8 ms）发一批。这样事件频率上限
 *   ≈ 125 批/秒/通道，远低而平稳；高吞吐时批大小自适应放大。
 *   T3 落地后终端路径切换到网格快照 + 脏行位图，本路径仅保留给 exec/SCP 类
 *   低吞吐通道使用。
 *
 * 使用契约（调用方在 session_bridge.cpp）：
 *   - feed() 追加数据，返回 true = 已达尺寸阈值，调用方应立即 takeBatch 投递；
 *   - 未达尺寸阈值时，调用方按 msUntilTimeFlush() 的剩余时间武装一次性定时器
 *     （EventLoop::runAfter），到期 flush；
 *   - 时间源（Clock::time_point）由调用方注入，宿主测试可注入假时钟，
 *     生产路径传 Clock::now()；
 *   - 非线程安全：设计上只在会话事件循环线程内访问（bridge 侧如此使用）。
 *
 * 纯逻辑代码：只依赖 C++ 标准库，禁止 include <napi/native_api.h> / <hilog/log.h>。
 */
#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

namespace sshclient {
namespace bridge {

class DataAggregator {
public:
    using Clock = std::chrono::steady_clock;

    struct Params {
        size_t flushBytes = 16 * 1024; // 批次达到该字节数立即冲刷
        uint64_t flushIntervalMs = 8;  // 批次首字节起超过该间隔即冲刷
    };

    // 注意：不能用「explicit DataAggregator(Params params = {})」——
    // 嵌套类带默认成员初始化器时，外围类体内的默认实参会触发 clang 报错
    // （default member initializer needed within definition of enclosing class）
    DataAggregator();                           // 默认参数：16 KiB / 8 ms
    explicit DataAggregator(Params params);

    DataAggregator(const DataAggregator &) = delete;
    DataAggregator &operator=(const DataAggregator &) = delete;

    // 追加数据；返回 true = 批次已达尺寸阈值，应立即 takeBatch 并投递
    bool feed(const void *data, size_t len, Clock::time_point now = Clock::now());
    bool feed(const std::string &data, Clock::time_point now = Clock::now())
    {
        return feed(data.data(), data.size(), now);
    }

    // 距时间触发点的剩余毫秒（<= 0 表示已到期应立即冲刷）；
    // 无积压数据返回 nullopt（调用方据此决定是否武装定时器）
    std::optional<int64_t> msUntilTimeFlush(Clock::time_point now = Clock::now()) const;

    bool empty() const { return batch_.empty(); }
    size_t pendingBytes() const { return batch_.size(); }

    // 取出累积批次并复位（清空缓冲、重新开始计时）；空批次返回空串
    std::string takeBatch();

private:
    Params params_;
    std::string batch_;
    Clock::time_point firstByteAt_{}; // 当前批次首字节时间
};

} // namespace bridge
} // namespace sshclient
