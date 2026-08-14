#include "channel.h"

#include <cstdio>
#include <cstring>
#include <utility>

#include <libssh2.h>

#include "../io/SessionThread.h"
#include "session.h"

// 与 session.cpp 同款：native 统一日志基建（hilog 封装）是后续任务，先落 stderr
#define SSH_LOG(...)                               \
    do {                                           \
        std::fprintf(stderr, "[ssh] " __VA_ARGS__); \
        std::fprintf(stderr, "\n");                \
    } while (0)

namespace sshclient {
namespace ssh {

SshChannel::SshChannel(SshSession &session, SshChannelCallbacks callbacks)
    : session_(session), callbacks_(std::move(callbacks))
{
}

SshChannel::~SshChannel()
{
    // 析构约定（见头注）：onOpen 失败或收到 onClose 之后析构，此时 libssh2 句柄
    // 必已释放、已从会话注销。契约违反时无法跨线程安全 free，仅告警不兜底。
    if (channel_ != nullptr) {
        SSH_LOG("警告：SshChannel 在句柄存活期间被析构（违反析构约定，可能泄漏）");
    }
}

// ------------------------------------------------------------------ 打开受理（任意线程）

bool SshChannel::openShell(PtySpec pty)
{
    if (pty.termType.empty() || pty.cols == 0 || pty.rows == 0) {
        SSH_LOG("openShell 拒绝受理：PTY 参数非法（term 空或尺寸为 0）");
        return false;
    }
    return admitOpen(RequestKind::kShell, true, std::move(pty), "");
}

bool SshChannel::exec(std::string command)
{
    if (command.empty()) {
        SSH_LOG("exec 拒绝受理：命令为空");
        return false;
    }
    return admitOpen(RequestKind::kExec, false, PtySpec{}, std::move(command));
}

bool SshChannel::execWithPty(PtySpec pty, std::string command)
{
    if (pty.termType.empty() || pty.cols == 0 || pty.rows == 0 || command.empty()) {
        SSH_LOG("execWithPty 拒绝受理：PTY 参数非法或命令为空");
        return false;
    }
    return admitOpen(RequestKind::kExec, true, std::move(pty), std::move(command));
}

// 受理（任意线程）：CAS 占位 → 暂存参数 → post 装配。
// 暂存字段的写入与循环线程的读取经 EventLoop::post 互斥锁构成 happens-before
// （同 SshSession::connect 惯例）。
bool SshChannel::admitOpen(RequestKind kind, bool withPty, PtySpec pty, std::string command)
{
    if (session_.state() != SshSessionState::kEstablished) {
        SSH_LOG("通道打开拒绝受理：会话状态 %s（仅 established 可开通道）",
                toString(session_.state()));
        return false;
    }
    bool expected = false;
    if (!openAdmitted_.compare_exchange_strong(expected, true)) {
        SSH_LOG("通道打开拒绝受理：本通道已打开过");
        return false;
    }
    kind_ = kind;
    pty_ = std::move(pty);
    command_ = std::move(command);
    // hasPty_ 先于 acceptWrites_ 放行：resize 受理路径 acquire acceptWrites_ 后读 hasPty_
    hasPty_.store(withPty, std::memory_order_relaxed);
    acceptWrites_.store(true, std::memory_order_release);
    session_.thread_.post([this] { begin(); });
    return true;
}

// ------------------------------------------------------------------ 数据面受理（任意线程）

bool SshChannel::write(const char *data, size_t len)
{
    if (data == nullptr || !acceptWrites_.load(std::memory_order_acquire)) {
        return false;
    }
    if (len == 0) {
        return true;
    }
    // 背压记账：先入账再核账，超限退账并整次拒收（不接受部分写入，
    // 避免调用方处理「写了一半」的边界）；并发写入的竞态只会使拒绝更保守
    const size_t prev = pendingBytes_.fetch_add(len, std::memory_order_acq_rel);
    if (prev + len > kMaxPendingWriteBytes) {
        pendingBytes_.fetch_sub(len, std::memory_order_release);
        SSH_LOG("write 背压拒收：%zu + %zu 超过上限 %zu", prev, len, kMaxPendingWriteBytes);
        return false;
    }
    session_.thread_.post([this, chunk = std::string(data, len)]() mutable {
        // 到达循环线程时通道可能已进入收尾（写入与关闭跨线程竞态）：丢弃并退账。
        // kIdle/kOpening 不丢弃——open* 的 begin 与本任务按 post FIFO 先后到达，
        // 数据在通道就绪前排队，就绪后按序冲刷
        const ChannelState st = state_.load(std::memory_order_acquire);
        if (st == ChannelState::kClosing || st == ChannelState::kClosed) {
            pendingBytes_.fetch_sub(chunk.size(), std::memory_order_release);
            return;
        }
        writeQueue_.push_back(std::move(chunk));
        pump();
        session_.updateFdInterest();
    });
    return true;
}

bool SshChannel::resize(uint32_t cols, uint32_t rows)
{
    if (cols == 0 || rows == 0 || !hasPty_.load(std::memory_order_acquire) ||
        !acceptWrites_.load(std::memory_order_acquire)) {
        return false;
    }
    session_.thread_.post([this, cols, rows] {
        pendingResize_ = std::make_pair(cols, rows); // 在途合并：后到覆盖先到
        pump();
        session_.updateFdInterest();
    });
    return true;
}

bool SshChannel::sendEof()
{
    if (!acceptWrites_.load(std::memory_order_acquire)) {
        return false;
    }
    session_.thread_.post([this] {
        eofRequested_ = true;
        pump();
        session_.updateFdInterest();
    });
    return true;
}

void SshChannel::close()
{
    if (!openAdmitted_.load(std::memory_order_acquire)) {
        return; // 从未受理打开：无事可关（也不投递任务，契约见头注）
    }
    bool expected = false;
    if (!closeRequested_.compare_exchange_strong(expected, true)) {
        return; // 幂等
    }
    session_.thread_.post([this] {
        localCloseRequested_ = true;
        pump();
        session_.updateFdInterest();
    });
}

// ------------------------------------------------------------------ 状态机（静态纯函数）

bool SshChannel::isLegalTransition(ChannelState from, ChannelState to)
{
    using S = ChannelState;
    switch (from) {
    case S::kIdle:
        return to == S::kOpening;
    case S::kOpening:
        return to == S::kRequestingPty || to == S::kStarting || to == S::kClosing ||
               to == S::kClosed;
    case S::kRequestingPty:
        return to == S::kStarting || to == S::kClosing || to == S::kClosed;
    case S::kStarting:
        return to == S::kOpen || to == S::kClosing || to == S::kClosed;
    case S::kOpen:
        return to == S::kClosing || to == S::kClosed; // kClosed：会话丢失的强制清理
    case S::kClosing:
        return to == S::kClosed;
    case S::kClosed:
        return false;
    }
    return false;
}

// ------------------------------------------------------------------ 装配与总泵（循环线程）

void SshChannel::begin()
{
    transitionTo(ChannelState::kOpening); // idle → opening
    if (session_.state() != SshSessionState::kEstablished || session_.session_ == nullptr) {
        // 受理后会话竞态断开：未注册进会话，直接终结（onOpen 失败回报）
        failOpen(SshChannelError::kNotEstablished, "会话已离开 established 态");
        return;
    }
    session_.registerChannel(this);
    pump();
    session_.updateFdInterest();
}

bool SshChannel::pump()
{
    bool progress = false;
    const ChannelState st = state_.load(std::memory_order_acquire);
    switch (st) {
    case ChannelState::kOpening:
    case ChannelState::kRequestingPty:
    case ChannelState::kStarting:
        progress = driveOpen();
        if (state_.load(std::memory_order_acquire) == ChannelState::kOpen) {
            // 打开完成，同一拍继续数据面（排队的 write/resize/eof 立即生效）
            progress = true;
        } else {
            break; // 仍在打开中（EAGAIN）或已失败
        }
        [[fallthrough]];
    case ChannelState::kOpen: {
        if (driveResize()) {
            progress = true;
        }
        if (driveSendEof()) {
            progress = true;
        }
        if (drainReads()) {
            progress = true;
        }
        if (flushWrites()) {
            progress = true;
        }
        if (eofSeen_ || localCloseRequested_) {
            // 对端 EOF（剩余数据上方已抽干）或本地 close：进入 close 握手
            transitionTo(ChannelState::kClosing);
            progress = true;
        }
        if (state_.load(std::memory_order_acquire) == ChannelState::kClosing && driveClose()) {
            progress = true;
        }
        break;
    }
    case ChannelState::kClosing:
        if (driveClose()) {
            progress = true;
        }
        break;
    default:
        break; // kIdle/kClosed：空转防御
    }
    return progress;
}

// ------------------------------------------------------------------ 打开步骤（循环线程）

bool SshChannel::driveOpen()
{
    bool progress = false;
    for (;;) {
        const ChannelState st = state_.load(std::memory_order_acquire);
        if (st == ChannelState::kOpening) {
            LIBSSH2_CHANNEL *ch = ::libssh2_channel_open_session(session_.session_);
            if (ch == nullptr) {
                if (::libssh2_session_last_errno(session_.session_) == LIBSSH2_ERROR_EAGAIN) {
                    noteBlocked();
                    return progress;
                }
                failOpen(SshChannelError::kOpenFailed, lastLibssh2Error());
                return true;
            }
            channel_ = ch;
            blockedOutbound_ = false;
            transitionTo(hasPty_.load(std::memory_order_relaxed) ? ChannelState::kRequestingPty
                                                                 : ChannelState::kStarting);
            progress = true;
            continue;
        }
        if (st == ChannelState::kRequestingPty) {
            // 像素维度传 0：终端尺寸只按字符格子生效（DESIGN §7.2）
            const int rc = ::libssh2_channel_request_pty_ex(
                channel_, pty_.termType.c_str(),
                static_cast<unsigned int>(pty_.termType.size()), nullptr, 0,
                static_cast<int>(pty_.cols), static_cast<int>(pty_.rows), 0, 0);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                noteBlocked();
                return progress;
            }
            if (rc != 0) {
                failOpen(SshChannelError::kPtyFailed, lastLibssh2Error());
                return true;
            }
            blockedOutbound_ = false;
            transitionTo(ChannelState::kStarting);
            progress = true;
            continue;
        }
        if (st == ChannelState::kStarting) {
            const bool isShell = kind_ == RequestKind::kShell;
            const char *request = isShell ? "shell" : "exec";
            const int rc = ::libssh2_channel_process_startup(
                channel_, request, static_cast<unsigned int>(std::strlen(request)),
                isShell ? nullptr : command_.c_str(),
                isShell ? 0 : static_cast<unsigned int>(command_.size()));
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                noteBlocked();
                return progress;
            }
            if (rc != 0) {
                failOpen(SshChannelError::kStartupFailed, lastLibssh2Error());
                return true;
            }
            command_.clear(); // exec 命令已完成使命
            blockedOutbound_ = false;
            transitionTo(ChannelState::kOpen);
            if (callbacks_.onOpen) {
                callbacks_.onOpen({true, SshChannelError::kNone, ""});
            }
            return true;
        }
        return progress; // 防御：不在打开步骤
    }
}

// ------------------------------------------------------------------ 数据面驱动（循环线程）

bool SshChannel::driveResize()
{
    if (!pendingResize_.has_value()) {
        return false;
    }
    const uint32_t cols = pendingResize_->first;
    const uint32_t rows = pendingResize_->second;
    const int rc = ::libssh2_channel_request_pty_size_ex(
        channel_, static_cast<int>(cols), static_cast<int>(rows), 0, 0);
    if (rc == LIBSSH2_ERROR_EAGAIN) {
        noteBlocked();
        return false;
    }
    pendingResize_.reset();
    blockedOutbound_ = false;
    if (rc != 0) {
        // 对端拒绝尺寸调整不致命：记日志后丢弃本次请求（通道继续可用）
        SSH_LOG("request_pty_size 被拒：%s", lastLibssh2Error().c_str());
        return false;
    }
    SSH_LOG("PTY 尺寸已调整：%ux%u", cols, rows);
    return true;
}

bool SshChannel::driveSendEof()
{
    // EOF 在字节流上须排在待发数据之后：队列未空时暂缓（对端停读则一致地都不发）
    if (!eofRequested_ || eofSent_ || !writeQueue_.empty()) {
        return false;
    }
    const int rc = ::libssh2_channel_send_eof(channel_);
    if (rc == LIBSSH2_ERROR_EAGAIN) {
        noteBlocked();
        return false;
    }
    blockedOutbound_ = false;
    if (rc != 0) {
        // EOF 发送失败不致命（对端多半已异常）：放弃发送， EOF 缺失导致的
        // 对端挂起最终由对端退出/会话断开兜底
        SSH_LOG("send_eof 失败：%s", lastLibssh2Error().c_str());
        eofRequested_ = false;
        return false;
    }
    eofSent_ = true;
    return true;
}

bool SshChannel::flushWrites()
{
    bool progress = false;
    while (!writeQueue_.empty()) {
        std::string &head = writeQueue_.front();
        const ssize_t n = ::libssh2_channel_write_ex(channel_, 0,
                                                     head.data() + writeQueueHeadOffset_,
                                                     head.size() - writeQueueHeadOffset_);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            noteBlocked();
            return progress;
        }
        if (n < 0) {
            // 对端已 close（CHANNEL_CLOSED）等：剩余数据无处可达，弃队列；
            // 不单独报错——对端退出信息/会话断线检测会给出最终关闭原因
            SSH_LOG("通道写失败（%s），丢弃 %zu 字节待发数据", lastLibssh2Error().c_str(),
                    pendingBytes_.load(std::memory_order_acquire));
            dropWriteQueue();
            blockedOutbound_ = false;
            return progress;
        }
        if (n == 0) {
            return progress; // 防御：写 0 字节无进展，防死循环
        }
        progress = true;
        blockedOutbound_ = false;
        pendingBytes_.fetch_sub(static_cast<size_t>(n), std::memory_order_release);
        writeQueueHeadOffset_ += static_cast<size_t>(n);
        if (writeQueueHeadOffset_ == head.size()) {
            writeQueue_.pop_front();
            writeQueueHeadOffset_ = 0;
        }
    }
    return progress;
}

bool SshChannel::drainReads()
{
    bool progress = false;
    char buf[32768]; // LIBSSH2_CHANNEL_PACKET_DEFAULT 粒度，栈上缓冲即可
    // 双流交替直到双双 EAGAIN：EXTENDED_DATA_NORMAL（默认）模式下 stderr 独立成流，
    // 只抽 stdout 会让 stderr 积压抑制窗口回补，进而卡死 stdout
    for (;;) {
        bool roundProgress = false;
        for (const int stream : {0, SSH_EXTENDED_DATA_STDERR}) {
            for (;;) {
                const ssize_t n =
                    ::libssh2_channel_read_ex(channel_, stream, buf, sizeof(buf));
                if (n > 0) {
                    progress = true;
                    roundProgress = true;
                    if (callbacks_.onData) {
                        callbacks_.onData(
                            std::string(buf, static_cast<size_t>(n)),
                            stream == 0 ? ChannelStream::kStdout : ChannelStream::kStderr);
                    }
                    continue;
                }
                if (n == 0) {
                    eofSeen_ = true; // 通道 EOF（read 返回 0）
                    break;
                }
                if (n == LIBSSH2_ERROR_EAGAIN) {
                    break;
                }
                // 读错误（CHANNEL_CLOSED 等对端异常收尾）：按 EOF 路径收尾，
                // 最终关闭原因由退出信息/会话断线检测给出，这里不单独报错
                SSH_LOG("通道读失败（stream %d）：%s", stream, lastLibssh2Error().c_str());
                eofSeen_ = true;
                break;
            }
        }
        if (!roundProgress) {
            break;
        }
    }
    // remote close 在 libssh2 内部同时置 eof（packet.c），对端直接 close 的
    // abrupt 路径也能被这里观测到
    if (!eofSeen_ && ::libssh2_channel_eof(channel_) != 0) {
        eofSeen_ = true;
    }
    return progress;
}

// ------------------------------------------------------------------ 关闭路径（循环线程）

bool SshChannel::driveClose()
{
    bool progress = false;
    if (!closeCompleted_) {
        // 尽力冲刷待发队列；冲不动（对端停读/已 close）不阻塞关闭，
        // 残留字节随 channel_free 丢弃
        if (!writeQueue_.empty() && flushWrites()) {
            progress = true;
        }
        const int rc = ::libssh2_channel_close(channel_);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            noteBlocked();
            return progress;
        }
        if (rc != 0) {
            const std::string message = "通道 close 失败: " + lastLibssh2Error();
            if (channel_ != nullptr) {
                ::libssh2_channel_free(channel_); // 尽力释放；失败随 session_free 兜底
                channel_ = nullptr;
            }
            finishClose(ChannelCloseReason::kError, message);
            return true;
        }
        closeCompleted_ = true;
        collectExitInfo(); // close 握手完成后 exit-status/exit-signal 才保证可读
        progress = true;
    }
    if (channel_ != nullptr) {
        const int rc = ::libssh2_channel_free(channel_);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            // 防御：close 已完成时 free 不再发报文，理论上不会 EAGAIN
            noteBlocked();
            return progress;
        }
        channel_ = nullptr;
        progress = true;
    }
    // 关闭原因：信号 > 退出码 > 纯 EOF/close 收尾（优先级注释见头注）
    ChannelCloseReason reason;
    std::string message;
    if (!exitSignal_.empty()) {
        reason = ChannelCloseReason::kExitSignal;
    } else if (eofSeen_) {
        reason = ChannelCloseReason::kExitStatus;
    } else {
        reason = ChannelCloseReason::kPeerEof;
        message = localCloseRequested_ ? "本地主动关闭，close 握手完成"
                                       : "对端关闭通道，未见 EOF/退出信息";
    }
    finishClose(reason, message);
    return true;
}

void SshChannel::collectExitInfo()
{
    exitStatus_ = ::libssh2_channel_get_exit_status(channel_);
    char *signal = nullptr;
    size_t signalLen = 0;
    if (::libssh2_channel_get_exit_signal(channel_, &signal, &signalLen, nullptr, nullptr,
                                          nullptr, nullptr) == 0 &&
        signal != nullptr) {
        exitSignal_.assign(signal, signalLen);
        // get_exit_signal 经会话分配器分配（channel.c LIBSSH2_ALLOC），配对释放
        ::libssh2_free(session_.session_, signal);
    }
}

void SshChannel::failOpen(SshChannelError error, const std::string &message)
{
    SSH_LOG("通道打开失败（%s）：%s", toString(error), message.c_str());
    openFailed_ = true; // finishClose 据此不再发 onClose
    if (callbacks_.onOpen) {
        callbacks_.onOpen({false, error, message});
    }
    if (channel_ != nullptr) {
        // 打开半途失败（pty/startup 被拒）：走正常 close 收尾释放句柄
        transitionTo(ChannelState::kClosing);
        driveClose();
        return;
    }
    finishClose(ChannelCloseReason::kError, message); // 仅注销 + 终态（回调已抑制）
}

void SshChannel::finishClose(ChannelCloseReason reason, const std::string &message)
{
    session_.unregisterChannel(this);
    dropWriteQueue();
    transitionTo(ChannelState::kClosed);
    if (openFailed_ || !callbacks_.onClose) {
        return;
    }
    ChannelCloseInfo info;
    info.reason = reason;
    info.exitStatus = exitStatus_;
    info.exitSignal = exitSignal_;
    info.message = message;
    callbacks_.onClose(info);
}

void SshChannel::onSessionLost()
{
    // 循环线程：SshSession::releaseResources 内调用。free 可能 EAGAIN（对端停读、
    // close 报文冲不进满的发送缓冲）——此时句柄留在会话通道表内，由随后
    // releaseResources 的 session_free 重试路径兜底释放（见 session.cpp 注释），
    // 这里只需停止引用
    if (channel_ != nullptr) {
        ::libssh2_channel_free(channel_);
        channel_ = nullptr;
    }
    const ChannelState st = state_.load(std::memory_order_acquire);
    if (st == ChannelState::kOpen || st == ChannelState::kClosing) {
        transitionTo(ChannelState::kClosed);
        dropWriteQueue();
        if (!openFailed_ && callbacks_.onClose) {
            ChannelCloseInfo info;
            info.reason = ChannelCloseReason::kError;
            info.message = "会话断开/关闭，通道强制清理";
            callbacks_.onClose(info);
        }
        return;
    }
    if (st == ChannelState::kOpening || st == ChannelState::kRequestingPty ||
        st == ChannelState::kStarting) {
        // 打开半途撞上会话断开：按 onOpen 失败回报（契约：打开失败不再有 onClose）
        openFailed_ = true;
        transitionTo(ChannelState::kClosed);
        dropWriteQueue();
        if (callbacks_.onOpen) {
            callbacks_.onOpen(
                {false, SshChannelError::kSessionLost, "会话断开/关闭，通道强制清理"});
        }
    }
    // kIdle（未注册，不会发生）/ kClosed（已终结）：空操作
}

// ------------------------------------------------------------------ 内部工具（循环线程）

void SshChannel::dropWriteQueue()
{
    size_t dropped = 0;
    for (const auto &chunk : writeQueue_) {
        dropped += chunk.size();
    }
    dropped -= writeQueueHeadOffset_; // 队首已发部分早已退账
    writeQueue_.clear();
    writeQueueHeadOffset_ = 0;
    if (dropped > 0) {
        pendingBytes_.fetch_sub(dropped, std::memory_order_release);
    }
}

void SshChannel::noteBlocked()
{
    const int dirs = ::libssh2_session_block_directions(session_.session_);
    blockedOutbound_ = (dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0;
}

void SshChannel::transitionTo(ChannelState to)
{
    const ChannelState from = state_.load(std::memory_order_acquire);
    if (!isLegalTransition(from, to)) {
        SSH_LOG("拒绝非法通道迁移 %s -> %s", toString(from), toString(to));
        return;
    }
    if (to == ChannelState::kClosing || to == ChannelState::kClosed) {
        acceptWrites_.store(false, std::memory_order_release); // 收尾起不再受理写入
    }
    state_.store(to, std::memory_order_release);
    SSH_LOG("通道状态 %s -> %s", toString(from), toString(to));
}

std::string SshChannel::lastLibssh2Error()
{
    char *errmsg = nullptr;
    int errmsgLen = 0;
    ::libssh2_session_last_error(session_.session_, &errmsg, &errmsgLen, 0);
    return errmsg != nullptr ? std::string(errmsg, errmsgLen) : std::string("未知错误");
}

// ------------------------------------------------------------------ 字符串化

const char *toString(ChannelState state)
{
    switch (state) {
    case ChannelState::kIdle:          return "idle";
    case ChannelState::kOpening:       return "opening";
    case ChannelState::kRequestingPty: return "pty";
    case ChannelState::kStarting:      return "starting";
    case ChannelState::kOpen:          return "open";
    case ChannelState::kClosing:       return "closing";
    case ChannelState::kClosed:        return "closed";
    }
    return "unknown";
}

const char *toString(ChannelCloseReason reason)
{
    switch (reason) {
    case ChannelCloseReason::kPeerEof:    return "peer_eof";
    case ChannelCloseReason::kExitStatus: return "exit_status";
    case ChannelCloseReason::kExitSignal: return "exit_signal";
    case ChannelCloseReason::kError:      return "error";
    }
    return "unknown";
}

const char *toString(SshChannelError error)
{
    switch (error) {
    case SshChannelError::kNone:           return "none";
    case SshChannelError::kNotEstablished: return "not_established";
    case SshChannelError::kOpenFailed:     return "open_failed";
    case SshChannelError::kPtyFailed:      return "pty_failed";
    case SshChannelError::kStartupFailed:  return "startup_failed";
    case SshChannelError::kSessionLost:    return "session_lost";
    }
    return "unknown";
}

} // namespace ssh
} // namespace sshclient
