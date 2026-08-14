/**
 * 每会话 I/O 线程封装 —— DESIGN §2.1：每条 SSH 会话一条 native I/O 线程。
 *
 * 组合关系：一个 SessionThread = 一条 std::thread + 一个 EventLoop。
 *   - start() / stop() 幂等，stop 语义：wakeup 退出循环 → join → 清空遗留任务；
 *   - 析构自动 stop，不会让 std::thread 悬着 joinable 析构（那是 terminate）；
 *   - post() 直接转发给 EventLoop；未 start 时任务入队，start 后依次执行。
 *
 * N6 接 libssh2 时的用法：会话装配代码经 post() 切到循环线程，再在其中
 * addFd / 设定时器（EventLoop 的 fd 接口只允许循环线程调用）。
 */
#pragma once

#include <mutex>
#include <thread>

#include "EventLoop.h"

namespace sshclient {
namespace io {

class SessionThread {
public:
    using Task = EventLoop::Task;

    SessionThread() = default;
    ~SessionThread();

    SessionThread(const SessionThread &) = delete;
    SessionThread &operator=(const SessionThread &) = delete;

    // 启动循环线程；已在运行则直接返回 true；EventLoop 初始化失败返回 false
    bool start();
    // 幂等：未启动直接返回。wakeup 唤醒 epoll_wait → join → 清空遗留任务/定时器。
    // 不可在本线程自身的任务/回调里调用（join 自身是未定义行为）；
    // 循环线程内想退出，调 loop().stop() 即可
    void stop();
    bool isRunning() const;

    // 投递任务到循环线程执行（线程安全；未 start 时入队待执行）
    void post(Task task) { loop_.post(std::move(task)); }

    // 访问底层 EventLoop（fd/定时器接口的线程契约见 EventLoop 头文件）
    EventLoop &loop() { return loop_; }

private:
    EventLoop loop_;
    mutable std::mutex mutex_; // 只保护 thread_ 生命周期
    std::thread thread_;
};

} // namespace io
} // namespace sshclient
