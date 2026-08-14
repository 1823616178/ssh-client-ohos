/**
 * 非阻塞 I/O 事件循环 —— DESIGN §2.1 线程模型的核心件（任务 N5）。
 *
 * 封装 Linux / OHOS musl 共有的 epoll（LT 水平触发，简单够用，不追 ET 极致性能）：
 *   - fd 事件注册/修改/移除：addFd / modifyFd / removeFd
 *   - 跨线程唤醒与任务投递：eventfd（Linux 与 musl 均有，比 pipe 省一个 fd、
 *     语义即「计数信号」，天然适合唤醒场景）+ wakeup / post
 *   - 定时器：runAfter / runEvery / cancelTimer；到期任务用 std::multimap
 *     按截止时间排序（最小堆语义），epoll_wait 超时取最近到期任务
 *
 * 线程契约：
 *   - run() 所在线程即「事件循环线程」，所有 fd 回调与任务都在该线程执行；
 *   - addFd / modifyFd / removeFd 只能由事件循环线程调用（别的线程想操作，
 *     post 一个任务进来再做）；
 *   - post / runAfter / runEvery / cancelTimer / wakeup / stop 任意线程可调。
 *
 * fd 所有权约定：EventLoop 不拥有 fd。removeFd 只做 epoll_ctl(DEL)，绝不 close；
 * close 的时机与责任在注册方（谁注册谁关闭，避免双关）。
 *
 * 纯逻辑代码：只依赖 POSIX 与 C++ 标准库，禁止 include <napi/native_api.h>
 * 等 OHOS 头；同一份源码同时编进 OHOS 产物与宿主机单测（tests/CMakeLists.txt）。
 */
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace sshclient {
namespace io {

class EventLoop {
public:
    // fd 就绪回调：fd 为触发的描述符，events 为 epoll 返回的事件掩码（EPOLLIN 等，
    // EPOLLERR/EPOLLHUP 由内核无条件上报，回调内需自行处理）
    using FdCallback = std::function<void(int fd, uint32_t events)>;
    using Task = std::function<void()>;
    using Clock = std::chrono::steady_clock;

    // 定时器 id，cancelTimer 的凭据；0 为无效 id（接口不会返回 0）
    using TimerId = uint64_t;

    EventLoop();
    ~EventLoop();

    EventLoop(const EventLoop &) = delete;
    EventLoop &operator=(const EventLoop &) = delete;

    // 构造是否成功（epoll/eventfd 创建失败时 false，此后一切操作空转并打日志）
    bool isValid() const { return epollFd_ >= 0; }

    // ---- fd 事件（仅事件循环线程调用）----
    // events 为 EPOLLIN/EPOLLOUT 等掩码组合；重复注册同一 fd 返回 false
    bool addFd(int fd, uint32_t events, FdCallback callback);
    bool modifyFd(int fd, uint32_t events);
    // 只摘除 epoll 监视与回调，不 close；fd 不存在时返回 false
    bool removeFd(int fd);

    // ---- 任务与定时器（任意线程可调）----
    // 投递任务到事件循环线程执行（FIFO 顺序），内部经 eventfd 唤醒 epoll_wait
    void post(Task task);
    // 一次性/周期定时器（毫秒），返回 id 供 cancelTimer；到期任务在事件循环线程执行
    TimerId runAfter(uint64_t delayMs, Task task);
    TimerId runEvery(uint64_t intervalMs, Task task);
    // 取消尚未到期的定时器；已到期正在执行的任务不受影响；id 不存在时静默忽略
    void cancelTimer(TimerId id);

    // 打断阻塞中的 epoll_wait（无实际任务时用于探活/配合 stop）
    void wakeup();

    // 事件循环主函数：在调用线程内运转，直至 stop() 后返回。
    // 注意：run() 自身不重置退出标记——stop() 可能早于 run() 首条指令到达
    // （线程刚建就被停），重置会把停止请求吞掉造成 join 死锁。
    // 停止后想再次运行，必须在启动 run() 前显式 rearm()
    // （SessionThread::start 持锁建线程前调用，时序天然安全）。
    void run();
    // 清除退出标记，使 run() 可再次进入；只允许在「run() 尚未启动」的窗口调用
    void rearm() { stopRequested_ = false; }
    // 请求退出 run()（任意线程可调，含事件循环线程自身；异步生效，不保证已返回）
    void stop();
    // 清空尚未执行的投递任务与全部定时器（SessionThread::stop 在 join 后调用）
    void clearPendingTasks();

private:
    static constexpr int kMaxEvents = 64;

    struct Timer {
        TimerId id;
        uint64_t intervalMs; // 0 = 一次性；>0 = 周期
        Task task;
    };

    void drainWakeup();
    void runPostedTasks();
    void runDueTimers();
    int computeTimeoutMs();

    int epollFd_ = -1;
    int wakeFd_ = -1; // eventfd，跨线程唤醒通道

    std::atomic<bool> stopRequested_{false};

    // 仅事件循环线程访问，无需锁
    std::unordered_map<int, FdCallback> fdCallbacks_;

    std::mutex taskMutex_;
    std::vector<Task> pendingTasks_;

    // 定时器：multimap 按截止时间升序（最小堆语义）+ id 索引支持 O(log n) 取消
    std::mutex timerMutex_;
    std::multimap<Clock::time_point, Timer> timers_;
    std::unordered_map<TimerId, std::multimap<Clock::time_point, Timer>::iterator> timerIndex_;
    std::atomic<TimerId> nextTimerId_{1};
};

} // namespace io
} // namespace sshclient
