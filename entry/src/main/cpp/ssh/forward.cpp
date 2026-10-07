#include "forward.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <utility>

#include <libssh2.h>

#include "../io/SessionThread.h"
#include "session.h"

#define SSH_LOG(...)                                 \
    do {                                             \
        std::fprintf(stderr, "[ssh-fwd] " __VA_ARGS__); \
        std::fprintf(stderr, "\n");                  \
    } while (0)

namespace sshclient {
namespace ssh {

// ---------------------------------------------------------------- 纯逻辑

bool isLegalForwardTransition(ForwardState from, ForwardState to)
{
    using S = ForwardState;
    switch (from) {
    case S::kIdle:
        return to == S::kOpening;
    case S::kOpening:
        return to == S::kOpen || to == S::kClosing || to == S::kClosed;
    case S::kOpen:
        return to == S::kClosing || to == S::kClosed;
    case S::kClosing:
        return to == S::kClosed;
    case S::kClosed:
        return false;
    }
    return false;
}

bool isValidForwardTarget(const ForwardTarget &target)
{
    return !target.host.empty() && target.port >= 1 && target.port <= 65535;
}

std::vector<ProxyJumpHop> parseProxyJumpSpec(const std::string &spec)
{
    std::vector<ProxyJumpHop> hops;
    if (spec.empty()) {
        return hops;
    }
    size_t start = 0;
    while (start <= spec.size()) {
        size_t comma = spec.find(',', start);
        if (comma == std::string::npos) {
            comma = spec.size();
        }
        std::string token = spec.substr(start, comma - start);
        // 去首尾空白
        while (!token.empty() && std::isspace(static_cast<unsigned char>(token.front()))) {
            token.erase(token.begin());
        }
        while (!token.empty() && std::isspace(static_cast<unsigned char>(token.back()))) {
            token.pop_back();
        }
        if (!token.empty()) {
            ProxyJumpHop hop;
            std::string rest = token;
            // user@host[:port] —— host 可为 IPv6 字面量 [addr]:port
            const size_t at = rest.rfind('@');
            if (at != std::string::npos) {
                hop.username = rest.substr(0, at);
                rest = rest.substr(at + 1);
            }
            if (rest.empty()) {
                return {}; // 非法：@ 后无 host
            }
            if (rest.front() == '[') {
                const size_t br = rest.find(']');
                if (br == std::string::npos || br == 1) {
                    return {};
                }
                hop.host = rest.substr(1, br - 1);
                if (br + 1 < rest.size()) {
                    if (rest[br + 1] != ':' || br + 2 >= rest.size()) {
                        return {};
                    }
                    const std::string portStr = rest.substr(br + 2);
                    int port = 0;
                    for (char c : portStr) {
                        if (!std::isdigit(static_cast<unsigned char>(c))) {
                            return {};
                        }
                        port = port * 10 + (c - '0');
                        if (port > 65535) {
                            return {};
                        }
                    }
                    if (port <= 0) {
                        return {};
                    }
                    hop.port = static_cast<uint16_t>(port);
                }
            } else {
                // 最后一个 : 分割端口（IPv4/主机名）
                const size_t colon = rest.rfind(':');
                if (colon != std::string::npos && rest.find(':') == colon) {
                    hop.host = rest.substr(0, colon);
                    const std::string portStr = rest.substr(colon + 1);
                    int port = 0;
                    if (portStr.empty()) {
                        return {};
                    }
                    for (char c : portStr) {
                        if (!std::isdigit(static_cast<unsigned char>(c))) {
                            return {};
                        }
                        port = port * 10 + (c - '0');
                        if (port > 65535) {
                            return {};
                        }
                    }
                    if (port <= 0) {
                        return {};
                    }
                    hop.port = static_cast<uint16_t>(port);
                } else if (colon != std::string::npos) {
                    // 多个冒号且非 []：当作 IPv6 无端口（保守拒绝，避免误解析）
                    return {};
                } else {
                    hop.host = rest;
                }
            }
            if (hop.host.empty()) {
                return {};
            }
            hops.push_back(std::move(hop));
        }
        if (comma >= spec.size()) {
            break;
        }
        start = comma + 1;
    }
    return hops;
}

std::vector<ProxyJumpHop> planProxyJumpHops(std::vector<ProxyJumpHop> hops)
{
    return hops; // 顺序即执行计划；空输入空输出
}

std::string proxyJumpTransportNotes()
{
    return
        "ProxyJump design (N16):\n"
        "1) connect hop1 over real TCP + authenticate;\n"
        "2) openDirectTcpip(hop1_session, hop2.host, hop2.port);\n"
        "3) for hop2 session, replace transport via\n"
        "   libssh2_session_callback_set(session, LIBSSH2_CALLBACK_RECV/SEND)\n"
        "   pointing at the jump channel read/write;\n"
        "4) repeat until the final target.\n"
        "GAP: SshSession is bound to a real TCP fd + epoll; channel-as-transport\n"
        "is not yet abstracted. Multi-hop orchestration stays in ArkTS until that\n"
        "transport layer lands. Intermediate hop loss must fail the lower session\n"
        "(error callback) rather than hang — enforce when implementing.\n";
}

const char *toString(ForwardKind kind)
{
    switch (kind) {
    case ForwardKind::kDirectTcpip:  return "direct_tcpip";
    case ForwardKind::kRemoteListen: return "remote_listen";
    }
    return "unknown";
}

const char *toString(ForwardState state)
{
    switch (state) {
    case ForwardState::kIdle:    return "idle";
    case ForwardState::kOpening: return "opening";
    case ForwardState::kOpen:    return "open";
    case ForwardState::kClosing: return "closing";
    case ForwardState::kClosed:  return "closed";
    }
    return "unknown";
}

const char *toString(ForwardError error)
{
    return forwardErrorName(error);
}

const char *forwardErrorName(ForwardError error)
{
    switch (error) {
    case ForwardError::kNone:           return "none";
    case ForwardError::kNotEstablished: return "not_established";
    case ForwardError::kOpenFailed:     return "open_failed";
    case ForwardError::kTargetInvalid:  return "target_invalid";
    case ForwardError::kSessionLost:    return "session_lost";
    case ForwardError::kNotSupported:   return "not_supported";
    case ForwardError::kInternal:       return "internal";
    }
    return "unknown";
}

// ================================================================ SshForwardChannel

SshForwardChannel::SshForwardChannel(SshSession &session, ForwardCallbacks callbacks)
    : session_(session), callbacks_(std::move(callbacks))
{
}

SshForwardChannel::~SshForwardChannel()
{
    if (channel_ != nullptr) {
        SSH_LOG("警告：SshForwardChannel 在句柄存活期间被析构（可能泄漏）");
    }
}

bool SshForwardChannel::isLegalTransition(ForwardState from, ForwardState to)
{
    return isLegalForwardTransition(from, to);
}

bool SshForwardChannel::openDirectTcpip(std::string host, uint32_t port)
{
    if (!isValidForwardTarget({host, port})) {
        SSH_LOG("openDirectTcpip 拒绝：目标非法 host=%s port=%u", host.c_str(), port);
        return false;
    }
    return admitOpen(std::move(host), port);
}

bool SshForwardChannel::admitOpen(std::string host, uint32_t port)
{
    if (session_.state() != SshSessionState::kEstablished) {
        SSH_LOG("forward open 拒绝：会话状态 %s", toString(session_.state()));
        return false;
    }
    bool expected = false;
    if (!openAdmitted_.compare_exchange_strong(expected, true)) {
        SSH_LOG("forward open 拒绝：已打开过");
        return false;
    }
    kind_ = ForwardKind::kDirectTcpip;
    host_ = std::move(host);
    port_ = port;
    acceptWrites_.store(true, std::memory_order_release);
    session_.thread_.post([this] { begin(); });
    return true;
}

void SshForwardChannel::adoptAccepted(struct _LIBSSH2_CHANNEL *channel, ForwardOpenResult meta)
{
    // 仅循环线程调用
    bool expected = false;
    if (!openAdmitted_.compare_exchange_strong(expected, true)) {
        return;
    }
    kind_ = ForwardKind::kRemoteListen; // accepted data path
    channel_ = channel;
    openMeta_ = meta;
    acceptWrites_.store(true, std::memory_order_release);
    transitionTo(ForwardState::kOpening);
    transitionTo(ForwardState::kOpen);
    if (callbacks_.onOpen) {
        ForwardOpenResult r = meta;
        r.success = true;
        r.error = ForwardError::kNone;
        callbacks_.onOpen(r);
    }
}

bool SshForwardChannel::write(const char *data, size_t len)
{
    if (data == nullptr || !acceptWrites_.load(std::memory_order_acquire)) {
        return false;
    }
    if (len == 0) {
        return true;
    }
    const size_t prev = pendingBytes_.fetch_add(len, std::memory_order_acq_rel);
    if (prev + len > kMaxPendingWriteBytes) {
        pendingBytes_.fetch_sub(len, std::memory_order_release);
        SSH_LOG("forward write 背压拒收：%zu + %zu", prev, len);
        return false;
    }
    session_.thread_.post([this, chunk = std::string(data, len)]() mutable {
        const ForwardState st = state_.load(std::memory_order_acquire);
        if (st == ForwardState::kClosing || st == ForwardState::kClosed) {
            pendingBytes_.fetch_sub(chunk.size(), std::memory_order_release);
            return;
        }
        writeQueue_.push_back(std::move(chunk));
        pump();
        session_.updateFdInterest();
    });
    return true;
}

void SshForwardChannel::close()
{
    if (!openAdmitted_.load(std::memory_order_acquire)) {
        return;
    }
    bool expected = false;
    if (!closeRequested_.compare_exchange_strong(expected, true)) {
        return;
    }
    session_.thread_.post([this] {
        localCloseRequested_ = true;
        pump();
        session_.updateFdInterest();
    });
}

void SshForwardChannel::begin()
{
    transitionTo(ForwardState::kOpening);
    if (session_.state() != SshSessionState::kEstablished || session_.session_ == nullptr) {
        failOpen(ForwardError::kNotEstablished, "会话已离开 established 态");
        return;
    }
    session_.registerForwardChannel(this);
    pump();
    session_.updateFdInterest();
}

bool SshForwardChannel::pump()
{
    bool progress = false;
    const ForwardState st = state_.load(std::memory_order_acquire);
    switch (st) {
    case ForwardState::kOpening:
        progress = driveOpen();
        if (state_.load(std::memory_order_acquire) != ForwardState::kOpen) {
            break;
        }
        progress = true;
        [[fallthrough]];
    case ForwardState::kOpen: {
        if (drainReads()) {
            progress = true;
        }
        if (flushWrites()) {
            progress = true;
        }
        if (eofSeen_ || localCloseRequested_) {
            transitionTo(ForwardState::kClosing);
            progress = true;
        }
        if (state_.load(std::memory_order_acquire) == ForwardState::kClosing && driveClose()) {
            progress = true;
        }
        break;
    }
    case ForwardState::kClosing:
        if (driveClose()) {
            progress = true;
        }
        break;
    default:
        break;
    }
    return progress;
}

bool SshForwardChannel::driveOpen()
{
    if (kind_ != ForwardKind::kDirectTcpip) {
        return false; // adopted channel already open
    }
    LIBSSH2_CHANNEL *ch = ::libssh2_channel_direct_tcpip_ex(
        session_.session_, host_.c_str(), static_cast<int>(port_), "127.0.0.1", 0);
    if (ch == nullptr) {
        if (::libssh2_session_last_errno(session_.session_) == LIBSSH2_ERROR_EAGAIN) {
            noteBlocked();
            return false;
        }
        failOpen(ForwardError::kOpenFailed, lastLibssh2Error());
        return true;
    }
    channel_ = ch;
    blockedOutbound_ = false;
    transitionTo(ForwardState::kOpen);
    if (callbacks_.onOpen) {
        ForwardOpenResult r;
        r.success = true;
        r.error = ForwardError::kNone;
        callbacks_.onOpen(r);
    }
    return true;
}

bool SshForwardChannel::flushWrites()
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
            SSH_LOG("forward write 失败（%s），丢弃待发", lastLibssh2Error().c_str());
            dropWriteQueue();
            blockedOutbound_ = false;
            return progress;
        }
        if (n == 0) {
            return progress;
        }
        progress = true;
        blockedOutbound_ = false;
        pendingBytes_.fetch_sub(static_cast<size_t>(n), std::memory_order_release);
        writeQueueHeadOffset_ += static_cast<size_t>(n);
        if (writeQueueHeadOffset_ == head.size()) {
            writeQueue_.erase(writeQueue_.begin());
            writeQueueHeadOffset_ = 0;
        }
    }
    return progress;
}

bool SshForwardChannel::drainReads()
{
    if (channel_ == nullptr) {
        return false;
    }
    bool progress = false;
    char buf[32768];
    for (;;) {
        const ssize_t n = ::libssh2_channel_read_ex(channel_, 0, buf, sizeof(buf));
        if (n > 0) {
            progress = true;
            if (callbacks_.onData) {
                callbacks_.onData(std::string(buf, static_cast<size_t>(n)));
            }
            continue;
        }
        if (n == 0) {
            eofSeen_ = true;
            break;
        }
        if (n == LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        SSH_LOG("forward read 失败：%s", lastLibssh2Error().c_str());
        eofSeen_ = true;
        break;
    }
    if (!eofSeen_ && ::libssh2_channel_eof(channel_) != 0) {
        eofSeen_ = true;
    }
    return progress;
}

bool SshForwardChannel::driveClose()
{
    bool progress = false;
    if (channel_ == nullptr) {
        finishClose("local_close", "通道句柄已释放");
        return true;
    }
    if (!closeCompleted_) {
        if (!writeQueue_.empty() && flushWrites()) {
            progress = true;
        }
        const int rc = ::libssh2_channel_close(channel_);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            noteBlocked();
            return progress;
        }
        if (rc != 0) {
            const std::string message = "forward close 失败: " + lastLibssh2Error();
            ::libssh2_channel_free(channel_);
            channel_ = nullptr;
            finishClose("error", message);
            return true;
        }
        closeCompleted_ = true;
        progress = true;
    }
    if (channel_ != nullptr) {
        const int rc = ::libssh2_channel_free(channel_);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            noteBlocked();
            return progress;
        }
        channel_ = nullptr;
        progress = true;
    }
    const char *reason = localCloseRequested_ ? "local_close" : "peer_eof";
    finishClose(reason, localCloseRequested_ ? "本地关闭" : "对端关闭");
    return true;
}

void SshForwardChannel::failOpen(ForwardError error, const std::string &message)
{
    SSH_LOG("forward 打开失败（%s）：%s", forwardErrorName(error), message.c_str());
    openFailed_ = true;
    if (callbacks_.onOpen) {
        ForwardOpenResult r;
        r.success = false;
        r.error = error;
        r.message = message;
        callbacks_.onOpen(r);
    }
    if (channel_ != nullptr) {
        transitionTo(ForwardState::kClosing);
        driveClose();
        return;
    }
    finishClose("error", message);
}

void SshForwardChannel::finishClose(const std::string &reason, const std::string &message)
{
    session_.unregisterForwardChannel(this);
    dropWriteQueue();
    transitionTo(ForwardState::kClosed);
    if (openFailed_ || !callbacks_.onClose) {
        return;
    }
    ForwardCloseInfo info;
    info.reason = reason;
    info.message = message;
    callbacks_.onClose(info);
}

void SshForwardChannel::onSessionLost()
{
    if (channel_ != nullptr) {
        ::libssh2_channel_free(channel_);
        channel_ = nullptr;
    }
    const ForwardState st = state_.load(std::memory_order_acquire);
    if (st == ForwardState::kOpen || st == ForwardState::kClosing) {
        transitionTo(ForwardState::kClosed);
        dropWriteQueue();
        if (!openFailed_ && callbacks_.onClose) {
            ForwardCloseInfo info;
            info.reason = "session_lost";
            info.message = "会话断开/关闭，转发通道强制清理";
            callbacks_.onClose(info);
        }
        return;
    }
    if (st == ForwardState::kOpening) {
        openFailed_ = true;
        transitionTo(ForwardState::kClosed);
        dropWriteQueue();
        if (callbacks_.onOpen) {
            ForwardOpenResult r;
            r.success = false;
            r.error = ForwardError::kSessionLost;
            r.message = "会话断开/关闭";
            callbacks_.onOpen(r);
        }
    }
}

void SshForwardChannel::noteBlocked()
{
    const int dirs = ::libssh2_session_block_directions(session_.session_);
    blockedOutbound_ = (dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0;
}

void SshForwardChannel::transitionTo(ForwardState to)
{
    const ForwardState from = state_.load(std::memory_order_acquire);
    if (!isLegalForwardTransition(from, to)) {
        SSH_LOG("拒绝非法 forward 迁移 %s -> %s", toString(from), toString(to));
        return;
    }
    if (to == ForwardState::kClosing || to == ForwardState::kClosed) {
        acceptWrites_.store(false, std::memory_order_release);
    }
    state_.store(to, std::memory_order_release);
}

void SshForwardChannel::dropWriteQueue()
{
    size_t dropped = 0;
    for (const auto &chunk : writeQueue_) {
        dropped += chunk.size();
    }
    dropped -= writeQueueHeadOffset_;
    writeQueue_.clear();
    writeQueueHeadOffset_ = 0;
    if (dropped > 0) {
        pendingBytes_.fetch_sub(dropped, std::memory_order_release);
    }
}

std::string SshForwardChannel::lastLibssh2Error()
{
    char *errmsg = nullptr;
    int errmsgLen = 0;
    ::libssh2_session_last_error(session_.session_, &errmsg, &errmsgLen, 0);
    return errmsg != nullptr ? std::string(errmsg, errmsgLen) : std::string("未知错误");
}

// ================================================================ SshRemoteForward

SshRemoteForward::SshRemoteForward(SshSession &session, ForwardCallbacks callbacks)
    : session_(session), callbacks_(std::move(callbacks))
{
}

SshRemoteForward::~SshRemoteForward()
{
    if (listener_ != nullptr) {
        SSH_LOG("警告：SshRemoteForward listener 存活期间析构");
    }
}

bool SshRemoteForward::openRemote(std::string bindAddress, uint32_t port)
{
    if (port == 0 || port > 65535) {
        SSH_LOG("openRemote 拒绝：端口非法 %u", port);
        return false;
    }
    return admitOpen(std::move(bindAddress), port);
}

bool SshRemoteForward::admitOpen(std::string bindAddress, uint32_t port)
{
    if (session_.state() != SshSessionState::kEstablished) {
        return false;
    }
    bool expected = false;
    if (!openAdmitted_.compare_exchange_strong(expected, true)) {
        return false;
    }
    bindAddress_ = std::move(bindAddress);
    port_ = port;
    session_.thread_.post([this] { begin(); });
    return true;
}

void SshRemoteForward::cancel()
{
    if (!openAdmitted_.load(std::memory_order_acquire)) {
        return;
    }
    bool expected = false;
    if (!cancelRequested_.compare_exchange_strong(expected, true)) {
        return;
    }
    session_.thread_.post([this] {
        if (state_.load(std::memory_order_acquire) == ForwardState::kOpen) {
            transitionTo(ForwardState::kClosing);
        }
        pump();
        session_.updateFdInterest();
    });
}

void SshRemoteForward::begin()
{
    transitionTo(ForwardState::kOpening);
    if (session_.state() != SshSessionState::kEstablished || session_.session_ == nullptr) {
        failOpen(ForwardError::kNotEstablished, "会话已离开 established 态");
        return;
    }
    session_.registerForwardChannel(this);
    pump();
    session_.updateFdInterest();
}

bool SshRemoteForward::pump()
{
    bool progress = false;
    const ForwardState st = state_.load(std::memory_order_acquire);
    switch (st) {
    case ForwardState::kOpening:
        progress = driveOpen();
        if (state_.load(std::memory_order_acquire) != ForwardState::kOpen) {
            break;
        }
        progress = true;
        [[fallthrough]];
    case ForwardState::kOpen: {
        if (cancelRequested_.load(std::memory_order_acquire)) {
            transitionTo(ForwardState::kClosing);
            progress = true;
        } else if (driveAccept()) {
            progress = true;
        }
        if (state_.load(std::memory_order_acquire) == ForwardState::kClosing) {
            if (listener_ != nullptr) {
                ::libssh2_channel_forward_cancel(listener_);
                listener_ = nullptr;
            }
            finishClose("local_close", "远程监听已取消");
            progress = true;
        }
        break;
    }
    case ForwardState::kClosing:
        if (listener_ != nullptr) {
            ::libssh2_channel_forward_cancel(listener_);
            listener_ = nullptr;
        }
        finishClose("local_close", "远程监听已取消");
        progress = true;
        break;
    default:
        break;
    }
    return progress;
}

bool SshRemoteForward::driveOpen()
{
    int bound = 0;
    const char *host = bindAddress_.empty() ? nullptr : bindAddress_.c_str();
    LIBSSH2_LISTENER *lst = ::libssh2_channel_forward_listen_ex(
        session_.session_, host, static_cast<int>(port_), &bound, 16);
    if (lst == nullptr) {
        if (::libssh2_session_last_errno(session_.session_) == LIBSSH2_ERROR_EAGAIN) {
            noteBlocked();
            return false;
        }
        failOpen(ForwardError::kOpenFailed, lastLibssh2Error());
        return true;
    }
    listener_ = lst;
    boundPort_.store(bound > 0 ? static_cast<uint32_t>(bound) : port_,
                     std::memory_order_release);
    blockedOutbound_ = false;
    transitionTo(ForwardState::kOpen);
    if (callbacks_.onOpen) {
        ForwardOpenResult r;
        r.success = true;
        r.error = ForwardError::kNone;
        r.boundPort = boundPort_.load(std::memory_order_acquire);
        callbacks_.onOpen(r);
    }
    return true;
}

bool SshRemoteForward::driveAccept()
{
    if (listener_ == nullptr) {
        return false;
    }
    bool progress = false;
    // 单次 pump 最多 accept 有限个，避免饿死同会话其它通道
    for (int i = 0; i < 4; ++i) {
        LIBSSH2_CHANNEL *ch = ::libssh2_channel_forward_accept(listener_);
        if (ch == nullptr) {
            const int err = ::libssh2_session_last_errno(session_.session_);
            if (err == LIBSSH2_ERROR_EAGAIN) {
                noteBlocked();
            }
            break; // 空队列 / EAGAIN / 错误：本拍结束
        }
        progress = true;
        ForwardOpenResult meta;
        meta.success = true;
        meta.boundPort = boundPort_.load(std::memory_order_acquire);
        // GAP: originator host:port 不可从 libssh2 公开 API 获取（见头注）
        meta.origin = "";
        if (callbacks_.onAccepted) {
            // 所有权转移：bridge 在回调内构造 SshForwardChannel 并 adoptAccepted(ch)
            callbacks_.onAccepted(ch, meta);
        } else {
            // 无接收方：直接释放，避免泄漏
            ::libssh2_channel_close(ch);
            ::libssh2_channel_free(ch);
        }
    }
    return progress;
}

void SshRemoteForward::failOpen(ForwardError error, const std::string &message)
{
    SSH_LOG("远程监听打开失败（%s）：%s", forwardErrorName(error), message.c_str());
    openFailed_ = true;
    if (callbacks_.onOpen) {
        ForwardOpenResult r;
        r.success = false;
        r.error = error;
        r.message = message;
        callbacks_.onOpen(r);
    }
    finishClose("error", message);
}

void SshRemoteForward::finishClose(const std::string &reason, const std::string &message)
{
    session_.unregisterForwardChannel(this);
    transitionTo(ForwardState::kClosed);
    if (openFailed_ || !callbacks_.onClose) {
        return;
    }
    ForwardCloseInfo info;
    info.reason = reason;
    info.message = message;
    callbacks_.onClose(info);
}

void SshRemoteForward::onSessionLost()
{
    if (listener_ != nullptr) {
        ::libssh2_channel_forward_cancel(listener_);
        listener_ = nullptr;
    }
    const ForwardState st = state_.load(std::memory_order_acquire);
    if (st == ForwardState::kOpen || st == ForwardState::kClosing) {
        transitionTo(ForwardState::kClosed);
        if (!openFailed_ && callbacks_.onClose) {
            ForwardCloseInfo info;
            info.reason = "session_lost";
            info.message = "会话断开，远程监听关闭";
            callbacks_.onClose(info);
        }
        return;
    }
    if (st == ForwardState::kOpening) {
        openFailed_ = true;
        transitionTo(ForwardState::kClosed);
        if (callbacks_.onOpen) {
            ForwardOpenResult r;
            r.success = false;
            r.error = ForwardError::kSessionLost;
            r.message = "会话断开/关闭";
            callbacks_.onOpen(r);
        }
    }
}

void SshRemoteForward::noteBlocked()
{
    const int dirs = ::libssh2_session_block_directions(session_.session_);
    blockedOutbound_ = (dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0;
}

void SshRemoteForward::transitionTo(ForwardState to)
{
    const ForwardState from = state_.load(std::memory_order_acquire);
    if (!isLegalForwardTransition(from, to)) {
        SSH_LOG("拒绝非法 remote-forward 迁移 %s -> %s", toString(from), toString(to));
        return;
    }
    state_.store(to, std::memory_order_release);
}

std::string SshRemoteForward::lastLibssh2Error()
{
    char *errmsg = nullptr;
    int errmsgLen = 0;
    ::libssh2_session_last_error(session_.session_, &errmsg, &errmsgLen, 0);
    return errmsg != nullptr ? std::string(errmsg, errmsgLen) : std::string("未知错误");
}

} // namespace ssh
} // namespace sshclient
