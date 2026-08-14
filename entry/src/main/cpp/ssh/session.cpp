#include "session.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <mutex>

#include <fcntl.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/socket.h>

#include <libssh2.h>

#include "../io/SessionThread.h"
#include "channel.h"

#include <algorithm>

// glibc 在 -std=c++17（非 gnu++17）下不暴露 EPOLLRDHUP；musl（OHOS）无条件定义。
// 值为内核 ABI 常量 0x2000，与定义来源无关。
#ifndef EPOLLRDHUP
#define EPOLLRDHUP 0x2000
#endif

// 与 EventLoop.cpp 同款：native 统一日志基建（hilog 封装）是后续任务，先落 stderr
#define SSH_LOG(...)                               \
    do {                                           \
        std::fprintf(stderr, "[ssh] " __VA_ARGS__); \
        std::fprintf(stderr, "\n");                \
    } while (0)

namespace sshclient {
namespace ssh {

namespace {

// libssh2 进程级初始化，只做一次。故意不配对 libssh2_exit()：
// 多会话反复 init/exit 在部分 crypto 后端上行为不安全，进程退出时由 OS 回收。
std::once_flag g_libssh2InitOnce;
bool g_libssh2InitOk = false;

void ensureLibssh2Init()
{
    std::call_once(g_libssh2InitOnce, [] {
        g_libssh2InitOk = (::libssh2_init(0) == 0);
        if (!g_libssh2InitOk) {
            SSH_LOG("libssh2_init 失败");
        }
    });
}

// 创建非阻塞 + CLOEXEC 的 TCP socket；失败返回 -1
int createTcpSocket(int family, int protocol)
{
    // SOCK_NONBLOCK/SOCK_CLOEXEC 旗标 glibc 与 OHOS musl 均支持
    int fd = ::socket(family, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, protocol);
    if (fd < 0) {
        return -1;
    }
    return fd;
}

} // namespace

SshSession::SshSession(io::SessionThread &thread, SshSessionOptions options, StateCallback callback)
    : thread_(thread), options_(options), callback_(std::move(callback))
{
    ensureLibssh2Init();
}

SshSession::~SshSession()
{
    // 析构约定（见头文件）：到达终态后或 SessionThread::stop() 之后析构。
    // 终态迁移前 releaseResources() 已回收 fd_/session_，这里只是兜底，
    // 绝不在运行中的循环上并发 removeFd。
    if (session_ != nullptr) {
        if (::libssh2_session_free(session_) == LIBSSH2_ERROR_EAGAIN && fd_ >= 0) {
            // 同 releaseResources 的 EAGAIN 防护：close 后重试使残留 flush 立即失败
            ::close(fd_);
            fd_ = -1;
            ::libssh2_session_free(session_);
        }
        session_ = nullptr;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

// ------------------------------------------------------------------ 公共 API

bool SshSession::connect(std::string host, uint16_t port, std::string username)
{
    // CAS 受理：仅 idle 态接受一次；并发重复 connect 只有一个胜出
    bool expected = false;
    if (!connectAdmitted_.compare_exchange_strong(expected, true)) {
        SSH_LOG("connect 被拒绝：当前状态 %s（仅 idle 可发起）", toString(state()));
        return false;
    }
    host_ = std::move(host);
    port_ = port;
    username_ = std::move(username);
    // post 的互斥锁保证上面的字段写入对循环线程可见（happens-before）
    thread_.post([this] { doConnect(); });
    return true;
}

void SshSession::close()
{
    const SshSessionState st = state();
    // 幂等：终态 / closing / idle 都是空操作（idle 还没连接，无事可关）
    if (st == SshSessionState::kIdle || st == SshSessionState::kClosing ||
        st == SshSessionState::kClosed || st == SshSessionState::kDisconnected ||
        st == SshSessionState::kError) {
        return;
    }
    thread_.post([this] { doClose(); });
}

SshSessionError SshSession::lastError() const
{
    std::lock_guard<std::mutex> lock(errorMutex_);
    return error_;
}

std::string SshSession::lastErrorMessage() const
{
    std::lock_guard<std::mutex> lock(errorMutex_);
    return errorMessage_;
}

std::optional<HostKeyInfo> SshSession::hostKeyInfo() const
{
    std::lock_guard<std::mutex> lock(hostKeyMutex_);
    return hostKeyInfo_;
}

bool SshSession::isLegalTransition(SshSessionState from, SshSessionState to)
{
    using S = SshSessionState;
    switch (from) {
    case S::kIdle:
        return to == S::kConnecting;
    case S::kConnecting:
        return to == S::kHandshaking || to == S::kError || to == S::kClosed;
    case S::kHandshaking:
        // kClosing：N7 主机密钥被拒时发协议层 disconnect 后优雅断开（见 verifyHostKey）
        return to == S::kAuthenticating || to == S::kError || to == S::kClosed ||
               to == S::kClosing;
    case S::kAuthenticating:
        // kEstablished 由 N8 认证成功进入；本任务内不会走到
        return to == S::kEstablished || to == S::kClosing || to == S::kDisconnected ||
               to == S::kError;
    case S::kEstablished:
        return to == S::kClosing || to == S::kDisconnected || to == S::kError;
    case S::kClosing:
        return to == S::kClosed;
    case S::kClosed:
    case S::kDisconnected:
    case S::kError:
        return false; // 终态不可再迁移
    }
    return false;
}

// ------------------------------------------------------------------ 连接装配（循环线程）

void SshSession::doConnect()
{
    transitionTo(SshSessionState::kConnecting); // idle → connecting

    if (!g_libssh2InitOk) {
        failWith(SshSessionError::kInternal, "libssh2_init 失败");
        return;
    }

    // 同步 getaddrinfo：数值地址近乎零开销；域名解析可能短暂阻塞循环线程，
    // N6 按任务约定保持简单，后续需要时再挪出循环线程。
    struct addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[8];
    std::snprintf(portStr, sizeof(portStr), "%u", static_cast<unsigned>(port_));

    struct addrinfo *results = nullptr;
    const int gai = ::getaddrinfo(host_.c_str(), portStr, &hints, &results);
    if (gai != 0) {
        failWith(SshSessionError::kResolveFailed,
                 std::string("域名解析失败: ") + ::gai_strerror(gai));
        return;
    }

    // 逐个地址尝试非阻塞 connect，直到 EINPROGRESS（挂 epoll 等可写）或立即成功
    int lastErrno = ECONNREFUSED;
    bool connectedNow = false;
    for (struct addrinfo *ai = results; ai != nullptr && fd_ < 0; ai = ai->ai_next) {
        int fd = createTcpSocket(ai->ai_family, ai->ai_protocol);
        if (fd < 0) {
            lastErrno = errno;
            continue;
        }
        if (::connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            fd_ = fd;
            connectedNow = true; // 本地环回可能立即完成三路握手
        } else if (errno == EINPROGRESS) {
            fd_ = fd;
        } else {
            lastErrno = errno;
            ::close(fd);
        }
    }
    ::freeaddrinfo(results);

    if (fd_ < 0) {
        failWith(SshSessionError::kConnectFailed,
                 std::string("TCP 连接失败: ") + std::strerror(lastErrno));
        return;
    }

    // 注册 fd：连接期等可写；EPOLLERR/EPOLLHUP 内核无条件上报，RDHUP 捕获对端 FIN
    if (!thread_.loop().addFd(fd_, EPOLLOUT | EPOLLRDHUP,
                              [this](int fd, uint32_t events) { onSocketEvent(fd, events); })) {
        failWith(SshSessionError::kInternal, "fd 注册事件循环失败");
        return;
    }
    fdRegistered_ = true;

    connectTimer_ = thread_.loop().runAfter(options_.connectTimeoutMs, [this] {
        if (state() == SshSessionState::kConnecting) {
            failWith(SshSessionError::kConnectTimeout, "TCP 连接超时");
        }
    });

    if (connectedNow) {
        thread_.loop().cancelTimer(connectTimer_);
        connectTimer_ = 0;
        beginHandshake();
    }
}

// ------------------------------------------------------------------ fd 事件分发（循环线程）

void SshSession::onSocketEvent(int /*fd*/, uint32_t events)
{
    switch (state()) {
    case SshSessionState::kConnecting: {
        // 非阻塞 connect 完成判定：以 SO_ERROR 为准（HUP 与 OUT 常同时到达）
        int soErr = 0;
        socklen_t len = sizeof(soErr);
        ::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &soErr, &len);
        if (soErr != 0) {
            failWith(SshSessionError::kConnectFailed,
                     std::string("TCP 连接失败: ") + std::strerror(soErr));
            return;
        }
        if ((events & (EPOLLERR | EPOLLHUP)) != 0 && (events & EPOLLOUT) == 0) {
            failWith(SshSessionError::kSocketError, "连接建立前 socket 异常");
            return;
        }
        if ((events & EPOLLOUT) != 0) {
            thread_.loop().cancelTimer(connectTimer_);
            connectTimer_ = 0;
            beginHandshake();
        }
        return;
    }
    case SshSessionState::kHandshaking:
        driveHandshake();
        if (state() != SshSessionState::kHandshaking) {
            return; // 成功进 authenticating 或已失败
        }
        // 对端已走但 libssh2 仍 EAGAIN（读无可读），直接失败，防 LT 空转
        if ((events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0) {
            int soErr = 0;
            socklen_t len = sizeof(soErr);
            ::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &soErr, &len);
            failWith(SshSessionError::kHandshakeFailed,
                     soErr != 0 ? std::string("握手期间 socket 错误: ") + std::strerror(soErr)
                                : "握手期间对端关闭连接");
        }
        return;
    case SshSessionState::kAuthenticating:
    case SshSessionState::kEstablished:
        // 断线检测：RST → EPOLLERR；对端 FIN → EPOLLRDHUP/HUP（均为秒级到达）
        if ((events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0) {
            int soErr = 0;
            socklen_t len = sizeof(soErr);
            ::getsockopt(fd_, SOL_SOCKET, SO_ERROR, &soErr, &len);
            if (soErr != 0) {
                peerLost(SshSessionError::kSocketError,
                         std::string("socket 错误: ") + std::strerror(soErr));
            } else {
                peerLost(SshSessionError::kDisconnectedByPeer, "对端关闭连接");
            }
            return;
        }
        // N8：认证类操作进行中时按 libssh2 声明的阻塞方向挂了 EPOLLIN/OUT
        // （见 updateFdInterest），事件到来即续跑驱动；
        // N10：established 态的 fd 事件分发到全部注册通道（打开续跑/读写/关闭握手）
        if (state() == SshSessionState::kAuthenticating) {
            if (authMethodsCallback_) {
                driveAuthMethodsQuery();
            } else if (authOp_) {
                driveAuth();
            }
        } else if (!channels_.empty()) {
            driveChannels();
        }
        return;
    case SshSessionState::kClosing:
        if ((events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) != 0) {
            // 对端先走了，disconnect 报文冲不出去也不必再冲
            releaseResources();
            transitionTo(SshSessionState::kClosed);
            return;
        }
        if ((events & EPOLLOUT) != 0) {
            // 用成员里的 reason/desc：N7 主机密钥被拒时是 HOST_KEY_NOT_VERIFIABLE，
            // 主动 close() 时是默认的 BY_APPLICATION
            const int rc = ::libssh2_session_disconnect_ex(session_, disconnectReason_,
                                                           disconnectDesc_.c_str(), "");
            if (rc != LIBSSH2_ERROR_EAGAIN) {
                releaseResources();
                transitionTo(SshSessionState::kClosed);
            }
        }
        return;
    default:
        return; // 终态不再有 fd 事件（fd 已摘除），防御性忽略
    }
}

// ------------------------------------------------------------------ 握手驱动（循环线程）

void SshSession::beginHandshake()
{
    // abstract 传 this：N8 keyboard-interactive 认证的 libssh2 C 回调
    // （kbdIntResponseCb，auth.cpp）经它找回会话实例
    session_ = ::libssh2_session_init_ex(nullptr, nullptr, nullptr, this);
    if (session_ == nullptr) {
        failWith(SshSessionError::kInternal, "libssh2_session_init 失败");
        return;
    }
    ::libssh2_session_set_blocking(session_, 0);

    // 算法协商：不调用 libssh2_session_method_pref，用 libssh2 1.11 内置默认偏好——
    // 默认集已覆盖 aes256-gcm@openssh.com / aes128-gcm / aes256-ctr、
    // curve25519-sha256 / ecdh-sha2-nistp* 、ssh-ed25519 / ecdsa-sha2-nistp256 /
    // rsa-sha2-512 等主流算法；chacha20-poly1305 不在其中（风险 R-7 已知，备选后端兜底）。
    // 主机密钥校验（TOFU）在握手完成的瞬间进行，见 driveHandshake → verifyHostKey。

    transitionTo(SshSessionState::kHandshaking);
    handshakeTimer_ = thread_.loop().runAfter(options_.handshakeTimeoutMs, [this] {
        if (state() == SshSessionState::kHandshaking) {
            failWith(SshSessionError::kHandshakeTimeout, "SSH 握手超时");
        }
    });
    driveHandshake();
}

void SshSession::driveHandshake()
{
    const int rc = ::libssh2_session_handshake(session_, fd_);
    if (rc == 0) {
        thread_.loop().cancelTimer(handshakeTimer_);
        handshakeTimer_ = 0;
        // N7 主机密钥校验点：libssh2 握手完成后才能取主机密钥，故 TASKS 验收标准
        // 「指纹变更时不继续握手」落地为——校验不过则不进入 authenticating，
        // 发 SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE 主动断开（closing → closed），
        // 并以 kHostKeyMismatch 作为 lastError() 的返回方向（对应验收的 HOST_KEY_MISMATCH）。
        if (!verifyHostKey()) {
            return;
        }
        transitionTo(SshSessionState::kAuthenticating); // 握手完成、待认证（N8 认证入口）
        updateFdInterest();
        return;
    }
    if (rc == LIBSSH2_ERROR_EAGAIN) {
        // 按 libssh2 声明的阻塞方向重新挂 epoll 事件
        updateFdInterest();
        return;
    }
    char *errmsg = nullptr;
    int errmsgLen = 0;
    ::libssh2_session_last_error(session_, &errmsg, &errmsgLen, 0);
    failWith(SshSessionError::kHandshakeFailed,
             std::string("SSH 握手失败: ") +
                 (errmsg != nullptr ? std::string(errmsg, errmsgLen) : std::string("未知错误")));
}

// ---------------------------------------------------------------- 主机密钥校验（循环线程，N7）

bool SshSession::verifyHostKey()
{
    std::optional<HostKeyInfo> info = extractHostKey(session_);
    if (!info.has_value()) {
        // 握手刚完成却取不到主机密钥：无法自证身份，fail-closed 按不匹配处理
        abortHostKeyMismatch("主机密钥提取失败（握手后 hostkey 不可用）");
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(hostKeyMutex_);
        hostKeyInfo_ = *info; // 含被拒场景也要留档，供上层做指纹对比视图
    }

    HostKeyDecision decision = HostKeyDecision::kAccept;
    if (options_.hostKeyCallback) {
        // 循环线程上同步调用；回调契约（快速返回、异步确认走先拒后重连）见 hostkey.h
        decision = options_.hostKeyCallback(*info);
    } else {
        // 默认策略（仅适合开发联调）：首连放行并报告指纹。
        // 生产路径必须注入回调与 known_hosts 比对，否则中间人替换密钥不会被发现。
        SSH_LOG("主机密钥未比对（默认 TOFU 放行）: %s %s", info->keyType.c_str(),
                info->fingerprintSha256.c_str());
    }
    if (decision == HostKeyDecision::kReject) {
        abortHostKeyMismatch(std::string("主机密钥被上层拒绝: ") + info->keyType + " " +
                             info->fingerprintSha256);
        return false;
    }
    return true;
}

void SshSession::abortHostKeyMismatch(const std::string &message)
{
    {
        std::lock_guard<std::mutex> lock(errorMutex_);
        error_ = SshSessionError::kHostKeyMismatch;
        errorMessage_ = message;
    }
    SSH_LOG("中止连接（主机密钥不可信）：%s", message.c_str());
    // 与主动 close() 同一优雅收尾路径：发协议层 disconnect 告知对端原因
    // （RFC 4253 原因码 9 host key not verifiable），状态 closing → closed。
    disconnectReason_ = SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE;
    disconnectDesc_ = "host key rejected";
    transitionTo(SshSessionState::kClosing);
    closeFlushTimer_ = thread_.loop().runAfter(options_.closeFlushTimeoutMs, [this] {
        if (state() == SshSessionState::kClosing) {
            releaseResources();
            transitionTo(SshSessionState::kClosed);
        }
    });
    const int rc = ::libssh2_session_disconnect_ex(session_, disconnectReason_,
                                                   disconnectDesc_.c_str(), "");
    if (rc != LIBSSH2_ERROR_EAGAIN) {
        releaseResources(); // 内部 cancelTimers() 一并摘掉 closeFlushTimer_
        transitionTo(SshSessionState::kClosed);
        return;
    }
    updateFdInterest(); // EAGAIN：挂 EPOLLOUT 等可写，由 kClosing 分支重试
}

// ------------------------------------------------------------------ 关闭路径（循环线程）

void SshSession::doClose()
{
    const SshSessionState st = state();
    switch (st) {
    case SshSessionState::kIdle:
    case SshSessionState::kClosing:
    case SshSessionState::kClosed:
    case SshSessionState::kDisconnected:
    case SshSessionState::kError:
        return; // 幂等空操作
    case SshSessionState::kConnecting:
    case SshSessionState::kHandshaking:
        // 连接/握手未完成，没有可优雅告别的东西，直接收尾
        releaseResources();
        transitionTo(SshSessionState::kClosed);
        return;
    case SshSessionState::kAuthenticating:
    case SshSessionState::kEstablished:
        break;
    }

    transitionTo(SshSessionState::kClosing);
    // 优雅告别有冲刷上限：对端不收 / 网络卡死时不能无限等
    closeFlushTimer_ = thread_.loop().runAfter(options_.closeFlushTimeoutMs, [this] {
        if (state() == SshSessionState::kClosing) {
            SSH_LOG("disconnect 报文冲刷超时，强制收尾");
            releaseResources();
            transitionTo(SshSessionState::kClosed);
        }
    });

    const int rc = ::libssh2_session_disconnect_ex(session_, disconnectReason_,
                                                   disconnectDesc_.c_str(), "");
    if (rc != LIBSSH2_ERROR_EAGAIN) {
        releaseResources();
        transitionTo(SshSessionState::kClosed);
        return;
    }
    updateFdInterest(); // EAGAIN：挂 EPOLLOUT 等可写再重试
}

// ------------------------------------------------------------------ 内部工具（循环线程）

void SshSession::updateFdInterest()
{
    if (fd_ < 0) {
        return;
    }
    // EPOLLERR/EPOLLHUP 内核无条件上报；RDHUP 用于捕获对端 FIN
    uint32_t mask = EPOLLRDHUP;
    switch (state()) {
    case SshSessionState::kConnecting:
        mask |= EPOLLOUT;
        break;
    case SshSessionState::kHandshaking: {
        const int dirs = ::libssh2_session_block_directions(session_);
        if ((dirs & LIBSSH2_SESSION_BLOCK_INBOUND) != 0) {
            mask |= EPOLLIN;
        }
        if ((dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0) {
            mask |= EPOLLOUT;
        }
        if ((dirs & (LIBSSH2_SESSION_BLOCK_INBOUND | LIBSSH2_SESSION_BLOCK_OUTBOUND)) == 0) {
            mask |= EPOLLIN; // 防御：方向未知时监听可读，事件来了再驱动一次
        }
        break;
    }
    case SshSessionState::kClosing:
        mask |= EPOLLOUT; // disconnect 报文待冲刷
        break;
    case SshSessionState::kAuthenticating:
        // N8：认证类操作进行中时按 libssh2 声明的阻塞方向挂事件；
        // 无操作时只留 RDHUP 做断线检测（与 established 相同）
        if (hasAuthPending()) {
            const int dirs = ::libssh2_session_block_directions(session_);
            if ((dirs & LIBSSH2_SESSION_BLOCK_INBOUND) != 0) {
                mask |= EPOLLIN;
            }
            if ((dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0) {
                mask |= EPOLLOUT;
            }
            if ((dirs & (LIBSSH2_SESSION_BLOCK_INBOUND | LIBSSH2_SESSION_BLOCK_OUTBOUND)) == 0) {
                mask |= EPOLLIN; // 防御：方向未知时监听可读，事件来了再驱动一次
            }
        }
        break;
    case SshSessionState::kEstablished:
        // N10：有注册通道时常开 EPOLLIN（通道数据/EOF/close/窗口调整等入向报文）；
        // EPOLLOUT 仅在某通道最近一次 EAGAIN 为发送方向（OUTBOUND）停滞时挂——
        // 对端停读导致的窗口耗尽是 INBOUND 停滞，挂 EPOLLOUT 会 LT 空转
        if (!channels_.empty()) {
            mask |= EPOLLIN;
            for (const SshChannel *ch : channels_) {
                if (ch->wantsOutboundBlocked()) {
                    mask |= EPOLLOUT;
                    break;
                }
            }
        }
        break;
    default:
        break; // 其余状态：只留 RDHUP 做断线检测
    }
    thread_.loop().modifyFd(fd_, mask);
}

void SshSession::transitionTo(SshSessionState to)
{
    const SshSessionState from = state();
    if (!isLegalTransition(from, to)) {
        SSH_LOG("拒绝非法迁移 %s -> %s", toString(from), toString(to));
        return;
    }
    state_.store(to, std::memory_order_release);
    SSH_LOG("状态 %s -> %s", toString(from), toString(to));
    if (callback_) {
        callback_(from, to);
    }
}

void SshSession::failWith(SshSessionError error, const std::string &message)
{
    {
        std::lock_guard<std::mutex> lock(errorMutex_);
        error_ = error;
        errorMessage_ = message;
    }
    SSH_LOG("失败：%s（%s）", toString(error), message.c_str());
    releaseResources();
    transitionTo(SshSessionState::kError);
}

void SshSession::peerLost(SshSessionError error, const std::string &message)
{
    {
        std::lock_guard<std::mutex> lock(errorMutex_);
        error_ = error;
        errorMessage_ = message;
    }
    SSH_LOG("断线：%s（%s）", toString(error), message.c_str());
    releaseResources();
    transitionTo(SshSessionState::kDisconnected);
}

void SshSession::releaseResources()
{
    cancelTimers();
    // N8：先清认证状态——摘认证定时器并清零内存中的凭据副本（auth.cpp）；
    // 必须在 session_ 释放之前（认证上下文引用它）
    clearAuthState();
    // N10：再清通道——全部注册通道收到 kError 关闭通知并释放 libssh2 句柄；
    // 同样必须在 session_free 之前（通道句柄引用会话）
    notifyChannelsSessionLost();
    if (session_ != nullptr) {
        // libssh2_session_free 可能尝试冲刷剩余报文（仍会写 fd），先于 close 调用
        if (::libssh2_session_free(session_) == LIBSSH2_ERROR_EAGAIN) {
            // 发送缓冲满/对端停读时 free 以 EAGAIN 拒绝释放内存（1.11 行为：
            // 通道 close 报文冲不出去则整个会话对象图都不释放）。内存不能泄——
            // 先摘 fd 并 close，让残留 flush 以真实错误（EBADF/EPIPE）快速失败
            //（channel_free 对非 EAGAIN 错误放行，见 libssh2 channel.c），再重试
            if (fd_ >= 0) {
                if (fdRegistered_) {
                    thread_.loop().removeFd(fd_);
                    fdRegistered_ = false;
                }
                ::close(fd_);
                fd_ = -1;
            }
            ::libssh2_session_free(session_);
        }
        session_ = nullptr;
    }
    if (fd_ >= 0) {
        if (fdRegistered_) {
            thread_.loop().removeFd(fd_);
            fdRegistered_ = false;
        }
        ::close(fd_);
        fd_ = -1;
    }
}

void SshSession::cancelTimers()
{
    if (connectTimer_ != 0) {
        thread_.loop().cancelTimer(connectTimer_);
        connectTimer_ = 0;
    }
    if (handshakeTimer_ != 0) {
        thread_.loop().cancelTimer(handshakeTimer_);
        handshakeTimer_ = 0;
    }
    if (closeFlushTimer_ != 0) {
        thread_.loop().cancelTimer(closeFlushTimer_);
        closeFlushTimer_ = 0;
    }
}

// ------------------------------------------------------------------ N10 通道分发（循环线程）

void SshSession::registerChannel(SshChannel *channel)
{
    channels_.push_back(channel);
    updateFdInterest(); // 首个通道注册后即开 EPOLLIN
}

void SshSession::unregisterChannel(SshChannel *channel)
{
    const auto it = std::find(channels_.begin(), channels_.end(), channel);
    if (it != channels_.end()) {
        channels_.erase(it);
    }
    updateFdInterest(); // 无通道后回到只挂 RDHUP 的断线检测
}

void SshSession::driveChannels()
{
    // 多轮泵送直到一轮无任何进展：A 通道的读会把 B 通道的报文搬进 libssh2
    // 内部队列（socket 上未必再有新数据，不会再触发 EPOLLIN），单轮可能漏掉；
    // 有进展的轮次必然消费了真实字节或推进了状态，轮数封顶纯作防御
    for (int pass = 0; pass < 8; ++pass) {
        bool progress = false;
        const std::vector<SshChannel *> snapshot = channels_; // 泵送中通道可能注销
        for (SshChannel *ch : snapshot) {
            if (std::find(channels_.begin(), channels_.end(), ch) == channels_.end()) {
                continue;
            }
            if (ch->pump()) {
                progress = true;
            }
        }
        if (!progress) {
            break;
        }
    }
    updateFdInterest();
}

void SshSession::notifyChannelsSessionLost()
{
    // 快照防回调内注销；onSessionLost 负责释放各通道的 libssh2 句柄并发通知
    const std::vector<SshChannel *> snapshot = channels_;
    for (SshChannel *ch : snapshot) {
        ch->onSessionLost();
    }
    channels_.clear();
}

// ------------------------------------------------------------------ 字符串化

const char *toString(SshSessionState state)
{
    switch (state) {
    case SshSessionState::kIdle:          return "idle";
    case SshSessionState::kConnecting:    return "connecting";
    case SshSessionState::kHandshaking:   return "handshaking";
    case SshSessionState::kAuthenticating: return "authenticating";
    case SshSessionState::kEstablished:   return "established";
    case SshSessionState::kClosing:       return "closing";
    case SshSessionState::kClosed:        return "closed";
    case SshSessionState::kDisconnected:  return "disconnected";
    case SshSessionState::kError:         return "error";
    }
    return "unknown";
}

const char *toString(SshSessionError error)
{
    switch (error) {
    case SshSessionError::kNone:              return "none";
    case SshSessionError::kResolveFailed:     return "resolve_failed";
    case SshSessionError::kConnectFailed:     return "connect_failed";
    case SshSessionError::kConnectTimeout:    return "connect_timeout";
    case SshSessionError::kHandshakeFailed:   return "handshake_failed";
    case SshSessionError::kHandshakeTimeout:  return "handshake_timeout";
    case SshSessionError::kHostKeyMismatch:   return "host_key_mismatch";
    case SshSessionError::kAuthFailedPassword:    return "auth_failed_password";
    case SshSessionError::kAuthFailedKey:         return "auth_failed_key";
    case SshSessionError::kAuthFailedPassphrase:  return "auth_failed_passphrase";
    case SshSessionError::kAuthFailedInteractive: return "auth_failed_interactive";
    case SshSessionError::kAuthTimeout:           return "auth_timeout";
    case SshSessionError::kDisconnectedByPeer: return "disconnected_by_peer";
    case SshSessionError::kSocketError:       return "socket_error";
    case SshSessionError::kInternal:          return "internal";
    }
    return "unknown";
}

} // namespace ssh
} // namespace sshclient
