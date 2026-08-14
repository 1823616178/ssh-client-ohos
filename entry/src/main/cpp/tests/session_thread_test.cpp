/**
 * SessionThread 单测 —— 任务 N5「每会话线程」封装与线程泄漏验收。
 *
 * 线程数断言法：读 /proc/self/status 的 Threads 字段（比 hardware_concurrency
 * 可靠——后者是 CPU 核数，与进程线程数无关）。1000 次 start/stop 后线程数
 * 必须回到基线；同测 fd 计数（EventLoop 持有 epoll fd 与 eventfd，构造/析构
 * 1000 次也必须无泄漏）。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <future>
#include <thread>

#include "io/SessionThread.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;

namespace {

// 解析 /proc/self/status 的 "Threads:\tN"；读不到返回 -1（调用方 GTEST_SKIP）
long ReadThreadCount()
{
    FILE *f = std::fopen("/proc/self/status", "r");
    if (f == nullptr) {
        return -1;
    }
    long count = -1;
    char line[256];
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        if (std::strncmp(line, "Threads:", 8) == 0) {
            count = std::strtol(line + 8, nullptr, 10);
            break;
        }
    }
    std::fclose(f);
    return count;
}

size_t CountFds()
{
    DIR *dir = ::opendir("/proc/self/fd");
    if (dir == nullptr) {
        return 0;
    }
    size_t n = 0;
    while (::readdir(dir) != nullptr) {
        ++n;
    }
    ::closedir(dir);
    return n >= 2 ? n - 2 : 0;
}

} // namespace

TEST(SessionThreadTest, StartPostStopLifecycle)
{
    SessionThread session;
    EXPECT_FALSE(session.isRunning());

    ASSERT_TRUE(session.start());
    EXPECT_TRUE(session.isRunning());
    EXPECT_TRUE(session.start()); // 重复 start 幂等

    // post 的任务在会话线程执行
    std::promise<std::thread::id> threadPromise;
    auto threadFuture = threadPromise.get_future();
    session.post([&] { threadPromise.set_value(std::this_thread::get_id()); });
    ASSERT_EQ(threadFuture.wait_for(5s), std::future_status::ready);
    EXPECT_NE(threadFuture.get(), std::this_thread::get_id());

    session.stop();
    EXPECT_FALSE(session.isRunning());
    session.stop(); // 重复 stop 幂等
    SUCCEED();
}

TEST(SessionThreadTest, PostBeforeStartRunsAfterStart)
{
    SessionThread session;

    std::promise<void> ranPromise;
    auto ranFuture = ranPromise.get_future();
    session.post([&] { ranPromise.set_value(); }); // 未 start：任务入队

    ASSERT_TRUE(session.start());
    EXPECT_EQ(ranFuture.wait_for(5s), std::future_status::ready);
    session.stop();
}

TEST(SessionThreadTest, StopClearsPendingTasks)
{
    SessionThread session;
    ASSERT_TRUE(session.start());
    session.stop();

    // 会话停止后投递的任务由 stop 清空，重启也不应复活执行
    std::atomic<bool> ran{false};
    session.post([&] { ran = true; });
    session.stop();

    ASSERT_TRUE(session.start());
    std::this_thread::sleep_for(200ms);
    EXPECT_FALSE(ran.load());
    session.stop();
}

TEST(SessionThreadTest, DestructorStopsThread)
{
    const long baseline = ReadThreadCount();
    if (baseline < 0) {
        GTEST_SKIP() << "/proc/self/status 不可用，跳过线程数断言";
    }
    {
        SessionThread session;
        ASSERT_TRUE(session.start());
        // 不显式 stop：析构必须自动 wakeup + join
    }
    EXPECT_EQ(ReadThreadCount(), baseline);
}

// N5 验收核心：1000 次 start/stop 无线程泄漏；顺带验证 EventLoop fd 无泄漏
TEST(SessionThreadTest, ChurnNoThreadOrFdLeak)
{
    const long baselineThreads = ReadThreadCount();
    if (baselineThreads < 0) {
        GTEST_SKIP() << "/proc/self/status 不可用，跳过线程数断言";
    }
    const size_t baselineFds = CountFds();
    ASSERT_GT(baselineFds, 0u);

    constexpr int kRounds = 1000;
    for (int i = 0; i < kRounds; ++i) {
        SessionThread session;
        ASSERT_TRUE(session.start()) << "第 " << i << " 轮";
        session.stop();
        EXPECT_FALSE(session.isRunning());
    }

    // join 是同步回收，结束后线程数应立即回落
    EXPECT_EQ(ReadThreadCount(), baselineThreads);
    EXPECT_EQ(CountFds(), baselineFds);
}
