/**
 * TeardownGuard —— Q3：session_bridge「在途调用 vs teardown」竞态的纯逻辑防护。
 *
 * 竞态模型（docs/QUALITY-GATES.md §3）：
 *   closeSession 摘表后 teardown 在独立线程执行；ArkTS 线程的方法可能在
 *   LookupLive 成功之后、真正使用 sh->session / channel 之前，与 teardown
 *   的 session.reset() / channels.clear() 交错 → UAF。
 *
 * 防护三件套（本头为宿主可测纯逻辑，napi 胶水仍只在 session_bridge.cpp）：
 *   1. generation 代际：BeginTeardown 时递增；在途调用/事件携带进入时的
 *      代际，代际不一致即视为过期，直接丢弃（late callback drop）；
 *   2. in-flight 调用计数：TryBeginCall 成功即 +1，EndCall -1；
 *      BeginTeardown 关闭入口后等待 inFlight==0，再允许销毁共享资源；
 *   3. tornDown 闩锁：一旦 teardown 开始，新的 TryBeginCall / 投递一律拒绝。
 *
 * 线程安全：全部方法内部持锁或使用原子量，可任意线程并发。
 * 纯逻辑：只依赖 C++ 标准库，禁止 include napi/hilog（tests CMake 约定）。
 */
#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>

namespace sshclient {
namespace bridge {

/**
 * 会话级 teardown 防护闩。
 *
 * 典型用法：
 *   // ArkTS 方法入口
 *   auto lease = guard.TryBeginCall();
 *   if (!lease.valid) return reject;
 *   ... 使用 session/channel ...
 *   guard.EndCall(lease);   // 或 RAII
 *
 *   // Teardown 线程
 *   if (!guard.BeginTeardown()) return; // 幂等
 *   ... 停线程 / 析构 session ...
 *   guard.EndTeardown();
 *
 *   // 循环线程回调投递
 *   if (!guard.ShouldDeliver(evtGeneration)) { delete evt; return; }
 */
class TeardownGuard {
public:
    /** 在途调用租约：valid=false 表示入口已关（teardown 中/后） */
    struct CallLease {
        uint64_t generation = 0;
        bool valid = false;
    };

    TeardownGuard() = default;
    ~TeardownGuard() = default;
    TeardownGuard(const TeardownGuard &) = delete;
    TeardownGuard &operator=(const TeardownGuard &) = delete;

    /**
     * 尝试进入在途调用。
     * 成功：返回 valid=true 的租约（携带当前 generation），inFlight++。
     * 失败：teardown 已开始 → valid=false，调用方不得触碰共享资源。
     */
    CallLease TryBeginCall()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (tornDown_) {
            return CallLease{generation_, false};
        }
        ++inFlight_;
        return CallLease{generation_, true};
    }

    /** 结束在途调用。仅在 lease.valid 时调用；重复 EndCall 同一租约由调用方避免。 */
    void EndCall(const CallLease &lease)
    {
        if (!lease.valid) {
            return;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (inFlight_ > 0) {
            --inFlight_;
        }
        if (inFlight_ == 0) {
            cv_.notify_all();
        }
    }

    /**
     * 开始 teardown：置 tornDown、递增 generation、等待在途调用排空。
     * 返回 false = 已经 teardown 过（幂等）。
     * @param wait 排空等待上限；超时仍返回 true（调用方走兜底回收并记日志）。
     */
    bool BeginTeardown(std::chrono::milliseconds wait = std::chrono::milliseconds(4000))
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (tornDown_) {
            return false;
        }
        tornDown_ = true;
        ++generation_; // 过期租约 / 过期事件从此代际不匹配
        if (inFlight_ > 0) {
            cv_.wait_for(lock, wait, [this] { return inFlight_ == 0; });
        }
        return true;
    }

    /** teardown 收尾标记（资源已销毁）；不改变 generation/tornDown */
    void EndTeardown()
    {
        std::lock_guard<std::mutex> lock(mutex_);
        teardownFinished_ = true;
    }

    /**
     * 事件/回调是否仍应投递。
     * @param eventGeneration 事件产生时的代际（0 = 未打戳，只看 tornDown）
     * teardown 开始后一律 false（late callback drop）。
     */
    bool ShouldDeliver(uint64_t eventGeneration) const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (tornDown_) {
            return false;
        }
        return eventGeneration == 0 || eventGeneration == generation_;
    }

    /** 租约是否仍与当前代际一致（方法体内二次校验用） */
    bool IsLiveLease(const CallLease &lease) const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return lease.valid && !tornDown_ && lease.generation == generation_;
    }

    bool tornDown() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return tornDown_;
    }

    bool teardownFinished() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return teardownFinished_;
    }

    uint64_t generation() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return generation_;
    }

    int32_t inFlight() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return inFlight_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    uint64_t generation_ = 1;
    int32_t inFlight_ = 0;
    bool tornDown_ = false;
    bool teardownFinished_ = false;
};

/** RAII：在途调用租约（ArkTS 线程方法入口持有，析构自动 EndCall） */
class InFlightLease {
public:
    InFlightLease() = default;

    /** @param guard 会话防护闩；sh 存活期间指针有效（shared_ptr 保活） */
    explicit InFlightLease(TeardownGuard *guard) : guard_(guard)
    {
        if (guard_ != nullptr) {
            lease_ = guard_->TryBeginCall();
        }
    }

    ~InFlightLease() { release(); }

    InFlightLease(const InFlightLease &) = delete;
    InFlightLease &operator=(const InFlightLease &) = delete;

    InFlightLease(InFlightLease &&other) noexcept
        : guard_(other.guard_), lease_(other.lease_)
    {
        other.guard_ = nullptr;
        other.lease_ = TeardownGuard::CallLease{};
    }

    InFlightLease &operator=(InFlightLease &&other) noexcept
    {
        if (this != &other) {
            release();
            guard_ = other.guard_;
            lease_ = other.lease_;
            other.guard_ = nullptr;
            other.lease_ = TeardownGuard::CallLease{};
        }
        return *this;
    }

    bool ok() const { return lease_.valid && guard_ != nullptr; }
    uint64_t generation() const { return lease_.generation; }
    const TeardownGuard::CallLease &lease() const { return lease_; }

    void release()
    {
        if (guard_ != nullptr && lease_.valid) {
            guard_->EndCall(lease_);
        }
        guard_ = nullptr;
        lease_ = TeardownGuard::CallLease{};
    }

private:
    TeardownGuard *guard_ = nullptr;
    TeardownGuard::CallLease lease_{};
};

} // namespace bridge
} // namespace sshclient
