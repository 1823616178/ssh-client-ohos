/**
 * SSH 会话生命周期与状态机 —— 任务 N6（DESIGN §2.1，依赖 N5 的 SessionThread/EventLoop）。
 *
 * 状态机（终态：kClosed / kDisconnected / kError）：
 *
 *     idle → connecting(tcp) → handshaking → authenticating → established
 *                ↓                 ↓    ↘         ↓              ↓
 *              error             error  (N7)  disconnected   disconnected
 *                ↓(close)          ↓     closing → closed（主机密钥被拒）
 *                               （任意非终态 close → closing → closed）
 *
 *   - N7 主机密钥 TOFU 校验点：握手成功后、进入 authenticating 前
 *     （libssh2 握手完成后才能取主机密钥）。上层回调拒绝（指纹不匹配/用户否认）时
 *     不进入 authenticating，发 SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE 后走
 *     closing → closed 断开，错误码 kHostKeyMismatch 经 lastError() 可读；
 *   - authenticating 是「待认证」边界：N6 到此为止，密码/公钥认证是 N8；
 *   - established 由 N8 认证成功后进入，本任务仅保留状态位与迁移校验；
 *   - error 终态细分原因由 lastError() / lastErrorMessage() 提供
 *     （统一错误码体系是 N13，这里先用会话内枚举）。
 *
 * 线程契约（与 EventLoop 对齐）：
 *   - connect() / close() / state() / lastError() 任意线程可调；
 *   - 所有真正的状态迁移都发生在 SessionThread 的事件循环线程，
 *     状态回调也在循环线程触发（bridge 层订阅后自行 post 到 JS 线程，N11）；
 *   - 析构约定：会话到达终态、或 SessionThread::stop() 之后再析构
 *     （析构做兜底资源回收，但不会在运行中的循环上并发摘 fd）。
 *
 * 断线检测：socket ERR / 对端 FIN / RST → disconnected（秒级，见 N6 测试）；
 * 「拔网线无 RST」的静默黑洞检测靠 keepalive，属 N12 范围，不在本任务。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库、POSIX 与 libssh2 公共头，
 * 禁止 include <napi/native_api.h> / <hilog/log.h>（桥接层是 N11）。
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

#include "../io/EventLoop.h"
#include "hostkey.h"

// 前向声明 libssh2 会话结构，避免把 <libssh2.h> 漏进公共头
// （tag 名与 libssh2 1.11.x 的 typedef 保持一致，pin 版本升级时需核对）
struct _LIBSSH2_SESSION;

namespace sshclient {
namespace io {
class SessionThread;
}
namespace ssh {

enum class SshSessionState {
    kIdle,
    kConnecting,     // TCP 非阻塞连接进行中
    kHandshaking,    // libssh2_session_handshake 驱动中（含算法协商）
    kAuthenticating, // 握手完成、待认证（N6 边界；N8 在此之上做认证）
    kEstablished,    // 认证成功（N8 才进入，本任务不到达）
    kClosing,        // 优雅关闭中（libssh2_session_disconnect 冲刷）
    kClosed,         // 终态：主动关闭完成
    kDisconnected,   // 终态：对端关闭 / 连接异常断开
    kError,          // 终态：连接/握手失败或超时（lastError() 查原因）
};

enum class SshSessionError {
    kNone,
    kResolveFailed,      // getaddrinfo 失败
    kConnectFailed,      // TCP connect 被拒/不可达
    kConnectTimeout,     // TCP connect 超时
    kHandshakeFailed,    // SSH 握手/算法协商失败
    kHandshakeTimeout,   // SSH 握手超时
    kHostKeyMismatch,    // N7：主机密钥被上层拒绝（指纹不匹配/首连未获信任）；
                         // 终态为 closed（closing → closed 主动断开），此码经 lastError() 读取
    kDisconnectedByPeer, // 对端关闭（FIN/RST）
    kSocketError,        // 底层 socket 错误
    kInternal,           // 内部错误（资源创建失败等）
};

struct SshSessionOptions {
    uint32_t connectTimeoutMs = 10000;    // TCP 连接超时
    uint32_t handshakeTimeoutMs = 15000;  // SSH 握手整体超时
    uint32_t closeFlushTimeoutMs = 2000;  // 优雅关闭时 disconnect 报文冲刷上限

    // N7 主机密钥 TOFU 决策回调（构造后不可变，无并发问题）：
    // 握手成功后、进入 authenticating 前在事件循环线程同步调用，须快速返回
    // （回调契约与异步 UI 确认的正确编排见 hostkey.h 注释）。
    // 为空 = 默认策略：放行并仅记日志报告指纹 —— TOFU 首连语义，仅适合开发联调；
    // 生产必须设置回调，与 ArkTS SQLite 的 known_hosts（DESIGN §5.1）比对后决策。
    HostKeyCallback hostKeyCallback;
};

class SshSession {
public:
    // 状态迁移回调：(from, to)，在事件循环线程触发；每次合法迁移恰好一次
    using StateCallback = std::function<void(SshSessionState from, SshSessionState to)>;

    // thread 的生命周期必须长于本对象；callback 可为空（不通知）
    SshSession(io::SessionThread &thread, SshSessionOptions options, StateCallback callback);
    ~SshSession();

    SshSession(const SshSession &) = delete;
    SshSession &operator=(const SshSession &) = delete;

    // 发起连接（任意线程；参数复制后经 post 切到循环线程装配）。
    // 仅 idle 态接受：返回 true 表示已受理；重复调用 / 非 idle 态返回 false。
    bool connect(std::string host, uint16_t port, std::string username);

    // 优雅关闭（任意线程，幂等）：authenticating/established 态先经 closing
    // 发 SSH disconnect 报文再收尾；其余非终态直接收尾；终态/idle 为空操作。
    void close();

    SshSessionState state() const { return state_.load(std::memory_order_acquire); }
    SshSessionError lastError() const;
    std::string lastErrorMessage() const;

    // N7：当前主机密钥信息（任意线程，mutex 保护）。握手成功后可用——
    // 包括被上层拒绝的会话（此时状态走 closing/closed，供对比视图展示）；
    // 尚未握手/连接失败返回 nullopt。
    std::optional<HostKeyInfo> hostKeyInfo() const;

    // 迁移合法性表（静态纯函数，供单测直接校验状态机边界）
    static bool isLegalTransition(SshSessionState from, SshSessionState to);

private:
    // ---- 以下方法全部只在事件循环线程执行 ----
    void doConnect();
    void onSocketEvent(int fd, uint32_t events);
    void beginHandshake();
    void driveHandshake();
    bool verifyHostKey(); // N7：提取+回调决策；false = 已走 abortHostKeyMismatch 中止
    void abortHostKeyMismatch(const std::string &message); // 记错误码 → closing → closed
    void doClose();
    void updateFdInterest();
    void transitionTo(SshSessionState to);
    void failWith(SshSessionError error, const std::string &message); // 收尾 → error
    void peerLost(SshSessionError error, const std::string &message); // 收尾 → disconnected
    void releaseResources(); // 摘 fd、关 socket、释放 libssh2 会话（循环线程）
    void cancelTimers();

    io::SessionThread &thread_;
    SshSessionOptions options_;
    StateCallback callback_;

    std::atomic<SshSessionState> state_{SshSessionState::kIdle};

    // 错误信息：循环线程写、任意线程读
    mutable std::mutex errorMutex_;
    SshSessionError error_ = SshSessionError::kNone;
    std::string errorMessage_;

    // N7 主机密钥信息：循环线程写（握手成功后）、任意线程读
    mutable std::mutex hostKeyMutex_;
    std::optional<HostKeyInfo> hostKeyInfo_;

    // connect 受理占位（CAS 防多线程重复 connect）；参数在 post 前写入，
    // 经 EventLoop::post 的互斥锁与循环线程构成 happens-before
    std::atomic<bool> connectAdmitted_{false};
    std::string host_;
    uint16_t port_ = 0;
    std::string username_;

    // ---- 以下成员仅事件循环线程访问 ----
    int fd_ = -1;
    bool fdRegistered_ = false; // fd_ 已 addFd 进事件循环（releaseResources 据此决定是否 removeFd）
    struct _LIBSSH2_SESSION *session_ = nullptr;
    io::EventLoop::TimerId connectTimer_ = 0;
    io::EventLoop::TimerId handshakeTimer_ = 0;
    io::EventLoop::TimerId closeFlushTimer_ = 0;
    // 优雅告别时发给对端的 disconnect 原因（RFC 4253 原因码；11 = by application）。
    // N7 主机密钥被拒时改写为 9（host key not verifiable）再进 closing。
    int disconnectReason_ = 11;
    std::string disconnectDesc_ = "client closing";
};

const char *toString(SshSessionState state);
const char *toString(SshSessionError error);

} // namespace ssh
} // namespace sshclient
