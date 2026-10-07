/**
 * Q3 —— session_bridge teardown 竞态防护（TeardownGuard）宿主单测。
 *
 * 覆盖：
 *   - 基本语义：TryBeginCall/EndCall、BeginTeardown 幂等、teardown 后拒绝新调用
 *   - generation：teardown bump 后 IsLiveLease/ShouldDeliver 过期丢弃
 *   - late callback drop：teardown 后事件一律不投递
 *   - connect-then-teardown storm：多线程并发 connect/write 与 close 交错，
 *     断言无 use-after-free（资源存活窗口受 inFlight 租约保护）与泄漏
 *
 * 纯逻辑：不依赖 napi/hilog；ASan 构建下应保持干净。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <thread>
#include <vector>

#include "bridge/teardown_guard.h"

using sshclient::bridge::InFlightLease;
using sshclient::bridge::TeardownGuard;
using namespace std::chrono_literals;

namespace {

// ---------------------------------------------------------------- 基本语义

TEST(TeardownGuardTest, BeginCallEndCallAndRejectAfterTeardown)
{
    TeardownGuard g;
    EXPECT_EQ(g.generation(), 1u);
    EXPECT_FALSE(g.tornDown());

    auto lease = g.TryBeginCall();
    EXPECT_TRUE(lease.valid);
    EXPECT_EQ(lease.generation, 1u);
    EXPECT_EQ(g.inFlight(), 1);
    EXPECT_TRUE(g.IsLiveLease(lease));

    g.EndCall(lease);
    EXPECT_EQ(g.inFlight(), 0);

    EXPECT_TRUE(g.BeginTeardown());
    EXPECT_TRUE(g.tornDown());
    EXPECT_EQ(g.generation(), 2u); // 代际 bump
    EXPECT_TRUE(g.BeginTeardown() == false); // 幂等
    EXPECT_EQ(g.generation(), 2u);

    auto late = g.TryBeginCall();
    EXPECT_FALSE(late.valid);
    EXPECT_FALSE(g.IsLiveLease(late));
    EXPECT_EQ(g.inFlight(), 0);
}

TEST(TeardownGuardTest, GenerationInvalidatesOldLeaseAfterTeardown)
{
    TeardownGuard g;
    auto lease = g.TryBeginCall();
    ASSERT_TRUE(lease.valid);
    // 模拟「LookupLive 成功后 teardown 开始」：租约仍持有，但代际已变
    EXPECT_TRUE(g.BeginTeardown(0ms)); // inFlight>0 时 0ms 超时仍返回 true
    EXPECT_FALSE(g.IsLiveLease(lease));
    EXPECT_EQ(g.inFlight(), 1); // 尚未 EndCall
    g.EndCall(lease);
    EXPECT_EQ(g.inFlight(), 0);
}

TEST(TeardownGuardTest, LateCallbackDroppedAfterTeardown)
{
    TeardownGuard g;
    EXPECT_TRUE(g.ShouldDeliver(1));
    EXPECT_TRUE(g.ShouldDeliver(0)); // 未打戳：只看 tornDown
    g.BeginTeardown();
    EXPECT_FALSE(g.ShouldDeliver(1));
    EXPECT_FALSE(g.ShouldDeliver(2)); // 新代际事件在 teardown 后也不投
    EXPECT_FALSE(g.ShouldDeliver(0));
    g.EndTeardown();
    EXPECT_TRUE(g.teardownFinished());
}

TEST(TeardownGuardTest, GenerationMismatchDroppedWhileLive)
{
    TeardownGuard g;
    EXPECT_TRUE(g.ShouldDeliver(1));
    EXPECT_FALSE(g.ShouldDeliver(99)); // 过期/未来代际：live 时也不投
}

TEST(TeardownGuardTest, InFlightLeaseRaii)
{
    TeardownGuard g;
    {
        InFlightLease a(&g);
        EXPECT_TRUE(a.ok());
        EXPECT_EQ(g.inFlight(), 1);
        InFlightLease b(&g);
        EXPECT_EQ(g.inFlight(), 2);
        // move
        InFlightLease c = std::move(b);
        EXPECT_TRUE(c.ok());
        EXPECT_FALSE(b.ok());
        EXPECT_EQ(g.inFlight(), 2);
    }
    EXPECT_EQ(g.inFlight(), 0);

    g.BeginTeardown();
    InFlightLease rejected(&g);
    EXPECT_FALSE(rejected.ok());
}

// ---------------------------------------------------------------- connect-then-teardown storm

/**
 * 模拟 SessionHandle 共享资源：teardown 等 inFlight 排空后才析构。
 * 在途「connect/write」若在资源已销毁后触碰 → UAF 计数（ASan 另会直接报）。
 */
struct FakeSessionResource {
    std::atomic<int> touches{0};
    std::atomic<bool> alive{true};
    ~FakeSessionResource() { alive.store(false); }
};

class FakeBridgeSession {
public:
    TeardownGuard guard;
    std::shared_ptr<FakeSessionResource> resource = std::make_shared<FakeSessionResource>();
    std::atomic<int> admitted{0};
    std::atomic<int> rejected{0};
    std::atomic<int> uaf{0};
    std::atomic<int> lateEventsDropped{0};
    std::atomic<int> lateEventsDelivered{0};

    /** 模拟 connect/write 等 napi 方法入口 */
    bool InvokeOp()
    {
        InFlightLease lease(&guard);
        if (!lease.ok()) {
            rejected.fetch_add(1);
            return false;
        }
        // 模拟方法体触碰 session（shared_ptr 副本：与 bridge 侧 shared_ptr 语义一致）
        auto res = resource;
        if (!res || !res->alive.load()) {
            uaf.fetch_add(1);
            return false;
        }
        res->touches.fetch_add(1);
        admitted.fetch_add(1);
        return true;
    }

    /** 模拟循环线程事件投递 */
    void EmitEvent()
    {
        const uint64_t gen = guard.generation();
        if (!guard.ShouldDeliver(gen)) {
            lateEventsDropped.fetch_add(1);
            return;
        }
        lateEventsDelivered.fetch_add(1);
    }

    /** 模拟 closeSession 摘表后的异步 teardown */
    void Teardown()
    {
        if (!guard.BeginTeardown()) {
            return;
        }
        // BeginTeardown 已等待 inFlight==0；此时销毁资源安全
        resource.reset();
        guard.EndTeardown();
        // teardown 后 late 事件必须被丢弃
        EmitEvent();
    }
};

TEST(TeardownGuardStormTest, ConnectThenTeardownStorm)
{
    constexpr int kCycles = 200;
    constexpr int kWorkers = 4;

    for (int cycle = 0; cycle < kCycles; ++cycle) {
        auto session = std::make_shared<FakeBridgeSession>();
        std::atomic<bool> start{false};
        std::vector<std::thread> workers;
        workers.reserve(kWorkers + 1);

        // 多路「ArkTS 方法」：connect / write / resize 风暴
        for (int w = 0; w < kWorkers; ++w) {
            workers.emplace_back([session, &start]() {
                while (!start.load(std::memory_order_acquire)) {
                }
                for (int i = 0; i < 40; ++i) {
                    session->InvokeOp();
                    if ((i & 7) == 0) {
                        session->EmitEvent();
                    }
                }
            });
        }
        // 循环线程回调风暴
        workers.emplace_back([session, &start]() {
            while (!start.load(std::memory_order_acquire)) {
            }
            for (int i = 0; i < 80; ++i) {
                session->EmitEvent();
            }
        });

        std::thread teardown([&]() {
            while (!start.load(std::memory_order_acquire)) {
            }
            // 与 in-flight 调用交错：不 sleep 也允许，制造竞态窗口
            if ((cycle & 3) == 0) {
                std::this_thread::sleep_for(std::chrono::microseconds(cycle % 50));
            }
            session->Teardown();
        });

        start.store(true, std::memory_order_release);
        for (auto &th : workers) {
            th.join();
        }
        teardown.join();

        EXPECT_TRUE(session->guard.tornDown());
        EXPECT_TRUE(session->guard.teardownFinished());
        EXPECT_EQ(session->uaf.load(), 0) << "cycle=" << cycle;
        EXPECT_EQ(session->guard.inFlight(), 0) << "cycle=" << cycle;
        // teardown 后的 late 事件必须至少被丢弃一次（Teardown 内 EmitEvent）
        EXPECT_GE(session->lateEventsDropped.load(), 1) << "cycle=" << cycle;
        // 资源已释放
        EXPECT_TRUE(session->resource == nullptr);
        // 迟到的调用必须被拒绝（再打一轮）
        const int rejectedBefore = session->rejected.load();
        EXPECT_FALSE(session->InvokeOp());
        EXPECT_EQ(session->rejected.load(), rejectedBefore + 1);
        EXPECT_EQ(session->uaf.load(), 0);
    }
}

TEST(TeardownGuardStormTest, ConcurrentTeardownsOnlyOneWins)
{
    TeardownGuard g;
    std::atomic<int> wins{0};
    std::vector<std::thread> threads;
    for (int i = 0; i < 8; ++i) {
        threads.emplace_back([&g, &wins]() {
            if (g.BeginTeardown()) {
                wins.fetch_add(1);
            }
        });
    }
    for (auto &th : threads) {
        th.join();
    }
    EXPECT_EQ(wins.load(), 1);
    EXPECT_EQ(g.generation(), 2u);
}

TEST(TeardownGuardStormTest, LongHoldCallBlocksTeardownUntilEnd)
{
    TeardownGuard g;
    auto lease = g.TryBeginCall();
    ASSERT_TRUE(lease.valid);

    std::atomic<bool> teardownReturned{false};
    std::thread t([&g, &teardownReturned]() {
        // 短等待上限：调用未结束时超时返回 true，但 inFlight 仍 >0
        g.BeginTeardown(20ms);
        teardownReturned.store(true);
    });
    t.join();
    EXPECT_TRUE(teardownReturned.load());
    EXPECT_TRUE(g.tornDown());
    EXPECT_EQ(g.inFlight(), 1); // 仍在途
    EXPECT_FALSE(g.IsLiveLease(lease)); // 代际已 bump
    g.EndCall(lease);
    EXPECT_EQ(g.inFlight(), 0);
}

} // namespace
