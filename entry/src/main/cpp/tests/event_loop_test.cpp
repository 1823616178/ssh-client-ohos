/**
 * EventLoop 单测 —— 任务 N5 验收标准的直接证据。
 *
 * 覆盖：
 *   - post 任务顺序与执行线程；
 *   - runAfter 触发/取消、runEvery 周期触发与取消；
 *   - wakeup 能打断无 fd 无定时器时无限阻塞的 epoll_wait；
 *   - socketpair 模拟连接 1000 次「注册→读→removeFd→close」，fd 计数回基线。
 *
 * fd 泄漏断言法：读 /proc/self/fd 目录条目数（宿主机 Linux 可行；OHOS 交叉
 * 目标只编不跑，同样能编译）。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <dirent.h>
#include <future>
#include <mutex>
#include <thread>
#include <vector>

#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#include "io/EventLoop.h"

using namespace std::chrono_literals;
using sshclient::io::EventLoop;

namespace {

// 事件循环线程脚手架：构造即在新线程 run()，析构自动 stop + join
class LoopRunner {
public:
    LoopRunner() : thread_([this] { loop_.run(); }) {}
    ~LoopRunner()
    {
        loop_.stop();
        thread_.join();
    }

    EventLoop &loop() { return loop_; }
    std::thread::id loopThreadId() const { return thread_.get_id(); }

private:
    EventLoop loop_;
    std::thread thread_;
};

// /proc/self/fd 条目数（去掉 "." 与 ".."）；opendir 自占的 fd 前后两次一致，可抵消
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

TEST(EventLoopTest, PostTasksRunInOrderOnLoopThread)
{
    LoopRunner runner;

    std::mutex mutex;
    std::condition_variable cv;
    std::vector<int> order;
    std::vector<std::thread::id> threads;
    int done = 0;

    constexpr int kTasks = 10;
    for (int i = 0; i < kTasks; ++i) {
        runner.loop().post([&, i] {
            {
                std::lock_guard<std::mutex> lock(mutex);
                order.push_back(i);
                threads.push_back(std::this_thread::get_id());
                ++done;
            }
            cv.notify_one();
        });
    }

    std::unique_lock<std::mutex> lock(mutex);
    ASSERT_TRUE(cv.wait_for(lock, 5s, [&] { return done == kTasks; }));
    for (int i = 0; i < kTasks; ++i) {
        EXPECT_EQ(order[i], i); // 同一线程 post 保序（FIFO）
        EXPECT_EQ(threads[i], runner.loopThreadId()); // 全部在事件循环线程执行
    }
}

TEST(EventLoopTest, RunAfterFires)
{
    LoopRunner runner;

    std::promise<std::chrono::milliseconds> elapsedPromise;
    auto elapsedFuture = elapsedPromise.get_future();
    const auto start = EventLoop::Clock::now();

    runner.loop().runAfter(50, [&] {
        const auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(EventLoop::Clock::now() - start);
        elapsedPromise.set_value(elapsed);
    });

    ASSERT_EQ(elapsedFuture.wait_for(5s), std::future_status::ready);
    // 下界留 10ms 调度余量：定时器不应显著提前触发
    EXPECT_GE(elapsedFuture.get(), 40ms);
}

TEST(EventLoopTest, RunAfterCancel)
{
    LoopRunner runner;

    std::atomic<bool> fired{false};
    const EventLoop::TimerId id = runner.loop().runAfter(50, [&] { fired = true; });
    runner.loop().cancelTimer(id);

    std::this_thread::sleep_for(300ms); // 远超 50ms，未取消则必然已触发
    EXPECT_FALSE(fired.load());
    // 重复取消与不存在的 id 均静默忽略
    runner.loop().cancelTimer(id);
    runner.loop().cancelTimer(9999);
}

TEST(EventLoopTest, RunEveryRepeatsUntilCancelled)
{
    LoopRunner runner;

    std::atomic<int> count{0};
    const EventLoop::TimerId id = runner.loop().runEvery(30, [&] { ++count; });

    // 等至少触发 3 次（轮询 + 总超时，避免死等）
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (count.load() < 3 && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(5ms);
    }
    ASSERT_GE(count.load(), 3);

    runner.loop().cancelTimer(id);
    const int snapshot = count.load();
    std::this_thread::sleep_for(200ms);
    EXPECT_EQ(count.load(), snapshot); // 取消后不再增长
}

TEST(EventLoopTest, WakeupInterruptsBlockedEpollWait)
{
    // 无 fd、无定时器时 epoll_wait 以 -1 无限阻塞；post 必须经 eventfd 唤醒它，
    // 否则下面的 wait_for 会超时失败
    LoopRunner runner;

    runner.loop().wakeup(); // 裸 wakeup 不应崩溃或卡死
    std::this_thread::sleep_for(100ms); // 确保循环已进 epoll_wait

    std::promise<void> donePromise;
    auto doneFuture = donePromise.get_future();
    runner.loop().post([&] { donePromise.set_value(); });

    EXPECT_EQ(doneFuture.wait_for(2s), std::future_status::ready);
}

TEST(EventLoopTest, FdCallbackReceivesReadEvent)
{
    LoopRunner runner;

    int fds[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);

    std::promise<uint32_t> eventsPromise;
    auto eventsFuture = eventsPromise.get_future();

    runner.loop().post([&, readFd = fds[0]] {
        // 跨线程 lambda 内不用 ASSERT：addFd 失败经 promise 上报 0，由主线程断言
        if (!runner.loop().addFd(readFd, EPOLLIN, [&eventsPromise](int fd, uint32_t events) {
                char buf[8];
                const ssize_t n = ::read(fd, buf, sizeof(buf));
                eventsPromise.set_value(n == 1 ? events : 0);
            })) {
            eventsPromise.set_value(0);
        }
    });
    ASSERT_EQ(::write(fds[1], "x", 1), 1);

    ASSERT_EQ(eventsFuture.wait_for(5s), std::future_status::ready);
    EXPECT_NE(eventsFuture.get() & EPOLLIN, 0u);

    // removeFd 不 close（fd 所有权约定）：摘除后由本测试负责 close
    std::promise<bool> removedPromise;
    auto removedFuture = removedPromise.get_future();
    runner.loop().post([&, readFd = fds[0]] {
        removedPromise.set_value(runner.loop().removeFd(readFd));
    });
    ASSERT_EQ(removedFuture.wait_for(5s), std::future_status::ready);
    EXPECT_TRUE(removedFuture.get());
    // 已摘除监视但未 close，fd 应仍可写读（证明 removeFd 没有动所有权）
    EXPECT_EQ(::write(fds[1], "y", 1), 1);
    char buf[8];
    EXPECT_EQ(::read(fds[0], buf, sizeof(buf)), 1);
    ::close(fds[0]);
    ::close(fds[1]);
}

// N5 验收核心：1000 次「连接→读→断开」，fd 计数必须回到基线
TEST(EventLoopTest, SocketpairChurnNoFdLeak)
{
    LoopRunner runner;

    const size_t baseline = CountFds();
    ASSERT_GT(baseline, 0u);

    constexpr int kRounds = 1000;
    for (int i = 0; i < kRounds; ++i) {
        int fds[2];
        ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0) << "第 " << i << " 轮";

        std::promise<bool> okPromise;
        auto okFuture = okPromise.get_future();

        EventLoop *loop = &runner.loop();
        const int readFd = fds[0];
        const int writeFd = fds[1];
        loop->post([loop, readFd, writeFd, &okPromise] {
            if (!loop->addFd(readFd, EPOLLIN, [loop, readFd, writeFd, &okPromise](int fd, uint32_t events) {
                    char buf[8];
                    const ssize_t n = ::read(fd, buf, sizeof(buf));
                    const bool ok = (n == 1 && buf[0] == 'x' && (events & EPOLLIN) != 0);
                    loop->removeFd(readFd); // 只摘除监视
                    ::close(readFd);        // close 由注册方负责
                    ::close(writeFd);
                    okPromise.set_value(ok);
                })) {
                ::close(readFd);
                ::close(writeFd);
                okPromise.set_value(false);
            }
        });
        ASSERT_EQ(::write(writeFd, "x", 1), 1) << "第 " << i << " 轮";

        ASSERT_EQ(okFuture.wait_for(5s), std::future_status::ready) << "第 " << i << " 轮";
        EXPECT_TRUE(okFuture.get()) << "第 " << i << " 轮";
    }

    EXPECT_EQ(CountFds(), baseline);
}
