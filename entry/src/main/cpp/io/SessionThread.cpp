#include "SessionThread.h"

namespace sshclient {
namespace io {

SessionThread::~SessionThread()
{
    stop();
}

bool SessionThread::start()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (thread_.joinable()) {
        return true; // 幂等：已在运行
    }
    if (!loop_.isValid()) {
        return false;
    }
    // 必须在建线程前 rearm：若先建线程，stop() 可能抢在 run() 首条指令前
    // 置位，而 run() 内的重置会吞掉它（持本锁保证 rearm 与 stop 不交错）
    loop_.rearm();
    thread_ = std::thread([this] { loop_.run(); });
    return true;
}

void SessionThread::stop()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (thread_.joinable()) {
        loop_.stop();   // 置退出标记 + eventfd 唤醒，run() 随即返回
        thread_.join();
    }
    // 无论本轮是否有线程可 join 都清空未执行的投递任务与定时器：
    // 会话结束即「不再有遗留工作」，幂等且重启拿到的是干净队列
    loop_.clearPendingTasks();
}

bool SessionThread::isRunning() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return thread_.joinable();
}

} // namespace io
} // namespace sshclient
