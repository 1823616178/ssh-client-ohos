#include "EventLoop.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <climits>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>

// 简单日志宏：native 统一日志基建（hilog 封装）是后续任务，先落 stderr
#define IO_LOG(...)                            \
    do {                                       \
        std::fprintf(stderr, "[io] " __VA_ARGS__); \
        std::fprintf(stderr, "\n");            \
    } while (0)

namespace sshclient {
namespace io {

EventLoop::EventLoop()
{
    epollFd_ = ::epoll_create1(EPOLL_CLOEXEC);
    if (epollFd_ < 0) {
        IO_LOG("epoll_create1 失败 errno=%d", errno);
        return;
    }

    // 唤醒机制选 eventfd：Linux 与 OHOS musl 均提供；相比 pipe 少占一个 fd，
    // 写 8 字节计数即唤醒，读一次即清零，语义比管道字节流更贴合「唤醒信号」
    wakeFd_ = ::eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (wakeFd_ < 0) {
        IO_LOG("eventfd 失败 errno=%d", errno);
        ::close(epollFd_);
        epollFd_ = -1;
        return;
    }

    struct epoll_event ev {};
    ev.events = EPOLLIN;
    ev.data.fd = wakeFd_;
    if (::epoll_ctl(epollFd_, EPOLL_CTL_ADD, wakeFd_, &ev) < 0) {
        IO_LOG("eventfd 注册进 epoll 失败 errno=%d", errno);
        ::close(wakeFd_);
        ::close(epollFd_);
        wakeFd_ = -1;
        epollFd_ = -1;
    }
}

EventLoop::~EventLoop()
{
    // 约定：析构前 run() 必须已返回（由 SessionThread::stop 保证）
    if (wakeFd_ >= 0) {
        ::close(wakeFd_);
    }
    if (epollFd_ >= 0) {
        ::close(epollFd_);
    }
}

bool EventLoop::addFd(int fd, uint32_t events, FdCallback callback)
{
    if (!isValid() || fd < 0 || fdCallbacks_.count(fd) != 0) {
        return false;
    }
    struct epoll_event ev {};
    ev.events = events;
    ev.data.fd = fd;
    if (::epoll_ctl(epollFd_, EPOLL_CTL_ADD, fd, &ev) < 0) {
        IO_LOG("epoll_ctl(ADD) fd=%d 失败 errno=%d", fd, errno);
        return false;
    }
    fdCallbacks_[fd] = std::move(callback);
    return true;
}

bool EventLoop::modifyFd(int fd, uint32_t events)
{
    if (!isValid() || fdCallbacks_.count(fd) == 0) {
        return false;
    }
    struct epoll_event ev {};
    ev.events = events;
    ev.data.fd = fd;
    if (::epoll_ctl(epollFd_, EPOLL_CTL_MOD, fd, &ev) < 0) {
        IO_LOG("epoll_ctl(MOD) fd=%d 失败 errno=%d", fd, errno);
        return false;
    }
    return true;
}

bool EventLoop::removeFd(int fd)
{
    if (!isValid()) {
        return false;
    }
    auto it = fdCallbacks_.find(fd);
    if (it == fdCallbacks_.end()) {
        return false;
    }
    // 只摘除监视，不 close —— fd 所有权在调用方（见头文件约定）
    if (::epoll_ctl(epollFd_, EPOLL_CTL_DEL, fd, nullptr) < 0) {
        IO_LOG("epoll_ctl(DEL) fd=%d 失败 errno=%d", fd, errno);
    }
    fdCallbacks_.erase(it);
    return true;
}

void EventLoop::post(Task task)
{
    {
        std::lock_guard<std::mutex> lock(taskMutex_);
        pendingTasks_.push_back(std::move(task));
    }
    wakeup();
}

EventLoop::TimerId EventLoop::runAfter(uint64_t delayMs, Task task)
{
    TimerId id = nextTimerId_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(timerMutex_);
        auto it = timers_.emplace(Clock::now() + std::chrono::milliseconds(delayMs),
                                  Timer{id, 0, std::move(task)});
        timerIndex_[id] = it;
    }
    // 新定时器可能早于 epoll_wait 当前超时，必须唤醒让其重算
    wakeup();
    return id;
}

EventLoop::TimerId EventLoop::runEvery(uint64_t intervalMs, Task task)
{
    TimerId id = nextTimerId_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(timerMutex_);
        auto it = timers_.emplace(Clock::now() + std::chrono::milliseconds(intervalMs),
                                  Timer{id, intervalMs, std::move(task)});
        timerIndex_[id] = it;
    }
    wakeup();
    return id;
}

void EventLoop::cancelTimer(TimerId id)
{
    std::lock_guard<std::mutex> lock(timerMutex_);
    auto idx = timerIndex_.find(id);
    if (idx == timerIndex_.end()) {
        return;
    }
    timers_.erase(idx->second);
    timerIndex_.erase(idx);
}

void EventLoop::wakeup()
{
    if (wakeFd_ < 0) {
        return;
    }
    const uint64_t one = 1;
    // 计数已满（2^64-2，实际不可能）时 EAGAIN，循环反正已会被唤醒，忽略
    ssize_t n = ::write(wakeFd_, &one, sizeof(one));
    (void)n;
}

void EventLoop::run()
{
    if (!isValid()) {
        IO_LOG("EventLoop 未初始化，run() 直接返回");
        return;
    }
    // 不在这里重置 stopRequested_：stop() 可能早于本函数首条指令执行，
    // 重置会吞掉停止请求（见头文件 run()/rearm() 注释）

    std::vector<struct epoll_event> events(kMaxEvents);
    while (!stopRequested_.load(std::memory_order_relaxed)) {
        runDueTimers();

        const int timeoutMs = computeTimeoutMs();
        const int n = ::epoll_wait(epollFd_, events.data(), kMaxEvents, timeoutMs);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            // 持续性错误（如 epoll fd 被外部关闭），忙等无意义，退出循环
            IO_LOG("epoll_wait 失败 errno=%d，退出事件循环", errno);
            break;
        }

        for (int i = 0; i < n; ++i) {
            const int fd = events[i].data.fd;
            if (fd == wakeFd_) {
                drainWakeup();
                continue;
            }
            // 回调可能 removeFd 自身或注销同批其它 fd，先按快照取回调、查不到则跳过
            FdCallback callback;
            auto it = fdCallbacks_.find(fd);
            if (it != fdCallbacks_.end()) {
                callback = it->second;
            }
            if (callback) {
                callback(fd, events[i].events);
            }
        }

        runPostedTasks();
    }
}

void EventLoop::stop()
{
    stopRequested_ = true;
    wakeup();
}

void EventLoop::clearPendingTasks()
{
    {
        std::lock_guard<std::mutex> lock(taskMutex_);
        pendingTasks_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(timerMutex_);
        timers_.clear();
        timerIndex_.clear();
    }
}

void EventLoop::drainWakeup()
{
    uint64_t counter = 0;
    // 读一次即清零计数；EAGAIN 说明已被别的线程读走，无碍
    ssize_t n = ::read(wakeFd_, &counter, sizeof(counter));
    (void)n;
}

void EventLoop::runPostedTasks()
{
    std::vector<Task> tasks;
    {
        std::lock_guard<std::mutex> lock(taskMutex_);
        tasks.swap(pendingTasks_);
    }
    for (auto &task : tasks) {
        task();
    }
}

void EventLoop::runDueTimers()
{
    std::vector<Task> dueTasks;
    const Clock::time_point now = Clock::now();
    {
        std::lock_guard<std::mutex> lock(timerMutex_);
        auto it = timers_.begin();
        while (it != timers_.end() && it->first <= now) {
            Timer timer = std::move(it->second);
            timerIndex_.erase(timer.id);
            it = timers_.erase(it);
            // 周期任务执行前先重排下一次：回调内 cancelTimer(id) 可取消后续触发
            if (timer.intervalMs > 0) {
                auto next = timers_.emplace(now + std::chrono::milliseconds(timer.intervalMs), timer);
                timerIndex_[timer.id] = next;
            }
            dueTasks.push_back(std::move(timer.task));
        }
    }
    for (auto &task : dueTasks) {
        task();
    }
}

int EventLoop::computeTimeoutMs()
{
    std::lock_guard<std::mutex> lock(timerMutex_);
    if (timers_.empty()) {
        return -1; // 无定时器：无限阻塞，靠 eventfd 唤醒
    }
    const Clock::time_point deadline = timers_.begin()->first;
    const Clock::time_point now = Clock::now();
    if (deadline <= now) {
        return 0;
    }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
    return static_cast<int>(std::min<int64_t>(ms, INT_MAX));
}

} // namespace io
} // namespace sshclient
