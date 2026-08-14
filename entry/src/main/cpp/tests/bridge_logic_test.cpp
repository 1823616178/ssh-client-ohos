/**
 * 桥接层纯逻辑测试 —— 任务 N11「NAPI 桥接层」的宿主可测部分。
 *
 * 覆盖（均不依赖 napi，NAPI 胶水路径由交叉编译 + 真机验证）：
 *   HandleTable：
 *     - 句柄分配从 1 开始、单调递增、erase 后不复现（「单调递增不复用」）
 *     - lookup 命中/未命中；erase 幂等（重复擦除返回 nullptr）
 *     - erase 后经旧 shared_ptr 副本对象仍存活（引用计数语义）
 *     - eraseAll 全量摘除且表清空
 *     - 并发 insert/erase/lookup 压力（析构安全，ASan/TSan 语义）
 *   DataAggregator：
 *     - 尺寸触发：恰好达到 flushBytes 触发、差 1 字节不触发
 *     - 时间触发：msUntilTimeFlush 的到期边界（注入假时钟）
 *     - takeBatch 取出全部内容并复位（批次计时重新开始）
 *     - 空批次 takeBatch 返回空串；feed 空数据不开启批次
 *     - 并发 feed/takeBatch 压力（模拟循环线程聚合 + 冲刷的竞态；
 *       生产契约是单线程访问，这里用互斥锁保护后压测内存安全）
 */
#include <gtest/gtest.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "bridge/data_aggregator.h"
#include "bridge/handle_table.h"

using sshclient::bridge::DataAggregator;
using sshclient::bridge::HandleTable;

namespace {

// ---------------------------------------------------------------- HandleTable

struct FakeSession {
    int tag = 0;
    std::shared_ptr<std::atomic<int>> destroyedCount;
    ~FakeSession()
    {
        if (destroyedCount) {
            destroyedCount->fetch_add(1);
        }
    }
};

TEST(HandleTableTest, InsertLookupEraseBasics)
{
    HandleTable<FakeSession> table;
    auto a = std::make_shared<FakeSession>();
    a->tag = 1;
    auto b = std::make_shared<FakeSession>();
    b->tag = 2;

    const uint64_t ha = table.insert(a);
    const uint64_t hb = table.insert(b);
    EXPECT_EQ(ha, 1u); // 从 1 开始
    EXPECT_EQ(hb, 2u); // 单调递增
    EXPECT_EQ(table.size(), 2u);

    auto found = table.lookup(ha);
    ASSERT_TRUE(found != nullptr);
    EXPECT_EQ(found->tag, 1);
    EXPECT_EQ(table.lookup(999), nullptr); // 未命中

    auto erased = table.erase(ha);
    ASSERT_TRUE(erased != nullptr);
    EXPECT_EQ(erased->tag, 1);
    EXPECT_EQ(table.size(), 1u);
    EXPECT_EQ(table.erase(ha), nullptr);   // 幂等：重复擦除
    EXPECT_EQ(table.lookup(ha), nullptr);
}

TEST(HandleTableTest, HandlesNeverReused)
{
    HandleTable<FakeSession> table;
    std::set<uint64_t> seen;
    // 反复插入/擦除，句柄集合不得复现旧值
    for (int i = 0; i < 1000; ++i) {
        const uint64_t h = table.insert(std::make_shared<FakeSession>());
        EXPECT_EQ(seen.count(h), 0u) << "句柄复用：h=" << h;
        seen.insert(h);
        table.erase(h);
    }
}

TEST(HandleTableTest, SharedPtrKeepsObjectAliveAfterErase)
{
    HandleTable<FakeSession> table;
    auto destroyed = std::make_shared<std::atomic<int>>(0);
    uint64_t h = 0;
    {
        auto obj = std::make_shared<FakeSession>();
        obj->destroyedCount = destroyed;
        h = table.insert(obj);
    } // obj 出作用域，表里仍持有一份

    auto copy = table.lookup(h);
    auto erased = table.erase(h);
    EXPECT_EQ(table.size(), 0u);
    EXPECT_EQ(destroyed->load(), 0); // 表已摘除，但副本仍在 → 不析构

    copy.reset();
    EXPECT_EQ(destroyed->load(), 0);
    erased.reset();
    EXPECT_EQ(destroyed->load(), 1); // 最后一份副本释放才析构
}

TEST(HandleTableTest, EraseAllDrainsTable)
{
    HandleTable<FakeSession> table;
    auto destroyed = std::make_shared<std::atomic<int>>(0);
    for (int i = 0; i < 8; ++i) {
        auto obj = std::make_shared<FakeSession>();
        obj->destroyedCount = destroyed;
        table.insert(std::move(obj));
    }
    auto all = table.eraseAll();
    EXPECT_EQ(all.size(), 8u);
    EXPECT_EQ(table.size(), 0u);
    EXPECT_TRUE(table.lookup(1) == nullptr);
    EXPECT_EQ(destroyed->load(), 0); // 对象随 vector 持有，未提前析构
    all.clear();
    EXPECT_EQ(destroyed->load(), 8);
}

TEST(HandleTableTest, ConcurrentInsertEraseLookup)
{
    HandleTable<FakeSession> table;
    auto destroyed = std::make_shared<std::atomic<int>>(0);
    constexpr int kThreads = 4;
    constexpr int kOpsPerThread = 500;
    std::atomic<bool> start{false};

    std::vector<std::thread> threads;
    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t]() {
            while (!start.load(std::memory_order_acquire)) {
            }
            std::vector<uint64_t> mine;
            for (int i = 0; i < kOpsPerThread; ++i) {
                auto obj = std::make_shared<FakeSession>();
                obj->destroyedCount = destroyed;
                obj->tag = t * kOpsPerThread + i;
                const uint64_t h = table.insert(std::move(obj));
                mine.push_back(h);
                // 随机对已分配的句柄做 lookup/erase（含别的线程的句柄）
                const uint64_t probe = mine[i / 2];
                auto copy = table.lookup(probe);
                if (i % 3 == 0) {
                    auto erased = table.erase(probe);
                    (void)erased;
                }
            }
            // 收尾：把自己剩余的句柄全部擦掉
            for (uint64_t h : mine) {
                table.erase(h);
            }
        });
    }
    start.store(true, std::memory_order_release);
    for (auto &th : threads) {
        th.join();
    }
    // 剩余条目经 eraseAll 清空；全部对象最终析构、无泄漏无重复释放
    auto rest = table.eraseAll();
    EXPECT_EQ(destroyed->load() + static_cast<int>(rest.size()), kThreads * kOpsPerThread);
    rest.clear();
    EXPECT_EQ(destroyed->load(), kThreads * kOpsPerThread);
    EXPECT_EQ(table.size(), 0u);
}

// ---------------------------------------------------------------- DataAggregator

using Clock = DataAggregator::Clock;

DataAggregator::Params TestParams()
{
    DataAggregator::Params p;
    p.flushBytes = 64;      // 小阈值便于边界断言
    p.flushIntervalMs = 50; // 假时钟下人为推进
    return p;
}

TEST(DataAggregatorTest, SizeTriggerBoundary)
{
    DataAggregator agg{TestParams()};
    const auto t0 = Clock::now();

    EXPECT_FALSE(agg.feed(std::string(63, 'a'), t0)); // 差 1 字节
    EXPECT_EQ(agg.pendingBytes(), 63u);
    EXPECT_TRUE(agg.feed(std::string(1, 'b'), t0));   // 恰好达到阈值
    EXPECT_EQ(agg.pendingBytes(), 64u);

    std::string batch = agg.takeBatch();
    EXPECT_EQ(batch.size(), 64u);
    EXPECT_EQ(batch[0], 'a');
    EXPECT_EQ(batch[63], 'b');
    EXPECT_TRUE(agg.empty());
}

TEST(DataAggregatorTest, TimeTriggerBoundary)
{
    DataAggregator agg{TestParams()};
    const auto t0 = Clock::now();

    EXPECT_EQ(agg.msUntilTimeFlush(t0), std::nullopt); // 空批次无定时需求
    agg.feed(std::string(10, 'x'), t0);

    auto atStart = agg.msUntilTimeFlush(t0);
    ASSERT_TRUE(atStart.has_value());
    EXPECT_EQ(*atStart, 50); // 首字节起算 50 ms

    auto mid = agg.msUntilTimeFlush(t0 + std::chrono::milliseconds(49));
    ASSERT_TRUE(mid.has_value());
    EXPECT_EQ(*mid, 1);

    // 到期边界：恰好 50 ms 与超过都为 <= 0（调用方按 <=0 冲刷）
    EXPECT_LE(*agg.msUntilTimeFlush(t0 + std::chrono::milliseconds(50)), 0);
    EXPECT_LE(*agg.msUntilTimeFlush(t0 + std::chrono::milliseconds(51)), 0);
}

TEST(DataAggregatorTest, TakeBatchResetsTiming)
{
    DataAggregator agg{TestParams()};
    const auto t0 = Clock::now();

    agg.feed(std::string(5, 'a'), t0);
    EXPECT_EQ(agg.takeBatch(), "aaaaa");
    EXPECT_EQ(agg.msUntilTimeFlush(t0 + std::chrono::milliseconds(100)), std::nullopt);

    // 新批次的计时从下一个首字节重新开始
    agg.feed(std::string(3, 'b'), t0 + std::chrono::milliseconds(100));
    auto ms = agg.msUntilTimeFlush(t0 + std::chrono::milliseconds(100));
    ASSERT_TRUE(ms.has_value());
    EXPECT_EQ(*ms, 50);
}

TEST(DataAggregatorTest, EmptyAndNullFeeds)
{
    DataAggregator agg{TestParams()};
    const auto t0 = Clock::now();

    EXPECT_TRUE(agg.takeBatch().empty()); // 空批次
    EXPECT_FALSE(agg.feed("", 0, t0));    // 空数据不开启批次
    EXPECT_FALSE(agg.feed(nullptr, 10, t0));
    EXPECT_TRUE(agg.empty());

    // 默认参数：16 KiB / 8 ms（N11 任务约定值）
    DataAggregator def;
    EXPECT_FALSE(def.feed(std::string(16 * 1024 - 1, 'z')));
    EXPECT_TRUE(def.feed(std::string(1, 'z')));
    EXPECT_EQ(def.pendingBytes(), 16u * 1024);
}

TEST(DataAggregatorTest, MultiFeedAccumulatesUntilSizeTrigger)
{
    DataAggregator agg{TestParams()}; // 64 字节阈值
    const auto t0 = Clock::now();
    for (int i = 0; i < 5; ++i) { // 5×12=60 < 64 不触发
        EXPECT_FALSE(agg.feed(std::string(12, '0' + i), t0));
    }
    EXPECT_TRUE(agg.feed(std::string(4, '!'), t0)); // 64 触发
    std::string batch = agg.takeBatch();
    EXPECT_EQ(batch.size(), 64u);
    EXPECT_EQ(batch.substr(0, 12), std::string(12, '0'));
    EXPECT_EQ(batch.substr(60), "!!!!");
}

TEST(DataAggregatorTest, ConcurrentFeedAndTake)
{
    // 生产契约是单线程（会话循环线程）访问；本测试用互斥锁保护做并发压测，
    // 验证跨线程竞态下的内存安全（ASan 目标），而非接口语义
    DataAggregator agg;
    std::mutex mu;
    std::atomic<uint64_t> produced{0};
    std::atomic<uint64_t> consumed{0};
    std::atomic<bool> stop{false};

    std::vector<std::thread> producers;
    for (int t = 0; t < 4; ++t) {
        producers.emplace_back([&, t]() {
            const std::string chunk(1024, 'a' + t);
            for (int i = 0; i < 2000; ++i) {
                std::lock_guard<std::mutex> lock(mu);
                if (agg.feed(chunk)) {
                    consumed += agg.takeBatch().size();
                }
                produced += 1024;
            }
        });
    }
    std::thread flusher([&]() {
        while (!stop.load(std::memory_order_acquire)) {
            {
                std::lock_guard<std::mutex> lock(mu);
                consumed += agg.takeBatch().size();
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    for (auto &th : producers) {
        th.join();
    }
    stop.store(true, std::memory_order_release);
    flusher.join();
    {
        std::lock_guard<std::mutex> lock(mu);
        consumed += agg.takeBatch().size();
    }
    EXPECT_EQ(consumed.load(), produced.load()); // 字节守恒：不丢不重
}

} // namespace
