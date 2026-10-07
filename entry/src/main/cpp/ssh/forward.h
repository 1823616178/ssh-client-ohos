/**
 * 端口转发 native 层 —— 任务 N15/N16（DESIGN §7.3，依赖 N6 会话 / N10 通道模式）。
 *
 * 分层：
 *   1. 纯逻辑（状态机迁移、ProxyJump 规格解析、direct-tcpip 目标校验）——
 *      宿主单测直接覆盖，不依赖 sshd；
 *   2. SshForwardChannel：libssh2_channel_direct_tcpip_ex / forward_accept
 *      封装。数据面读写与 SshChannel 同一风格：任意线程受理，post 进会话
 *      事件循环执行；回调在循环线程触发，bridge 自行切线程。
 *   3. SshRemoteForward：libssh2_channel_forward_listen_ex 监听 + accept。
 *      pump 时尽力 accept 入站连接，经 onAccepted 上抛（新数据通道由
 *      bridge 装配成 SshForwardChannel）。
 *   4. ProxyJump（N16）：libssh2 无内建跳板，设计是在跳板会话上开
 *      direct-tcpip 到下一跳:22，再把该通道读写注册为下级会话的
 *      LIBSSH2_CALLBACK_SEND/RECV 传输层（见 proxyJumpTransportNotes）。
 *      **当前 SshSession 只支持真实 TCP fd，不支持通道传输层**，故
 *      多级 ProxyJump 的会话级串联尚未打通；本文件提供：
 *        - parseProxyJumpSpec / planProxyJumpHops 纯函数（规格 → 跳列表）
 *        - 设计注记（proxyJumpTransportNotes）
 *      ArkTS 侧编排注释见 SessionManager / service/portforward/ProxyJump.ets。
 *
 * 已知缺口（best effort，文档化）：
 *   - 远程转发 accept 后无法从 libssh2 公开 API 取到 originator host:port
 *     （channel open extra data 未暴露），事件里 origin 字段为空；
 *   - 远程转发 bound_port 经 forwardListen 事件回报；sshd 需 AllowTcpForwarding；
 *   - 动态转发（-D）SOCKS5 握手在 ArkTS（Socks5.ets），CONNECT 解析完成后的
 *     数据通道复用 openDirectTcpip；
 *   - ProxyJump 多级串联：见上方第 4 点，native 只到「规划 + 单跳 direct-tcpip」。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库、POSIX 与 libssh2 公共头，
 * 禁止 include <napi/native_api.h> / <hilog/log.h>（桥接层是 forward_bridge）。
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// 前向声明，避免把 <libssh2.h> 漏进公共头（同 session.h/channel.h 惯例）
struct _LIBSSH2_CHANNEL;
struct _LIBSSH2_LISTENER;

namespace sshclient {
namespace ssh {

class SshSession;

// ---------------------------------------------------------------- 纯逻辑

enum class ForwardKind {
    kDirectTcpip,  // -L / -D（SOCKS5 CONNECT 之后）
    kRemoteListen, // -R 监听器（不走数据面）
};

enum class ForwardState {
    kIdle,
    kOpening,  // direct-tcpip 或 forward_listen 驱动中
    kOpen,     // 数据通道就绪 / 远程监听就绪
    kClosing,
    kClosed,
};

enum class ForwardError {
    kNone,
    kNotEstablished, // 会话不在 established
    kOpenFailed,     // direct-tcpip / forward_listen 被拒
    kTargetInvalid,  // host 空 / port 0
    kSessionLost,    // 会话断开导致强制清理
    kNotSupported,   // 能力未打通（如 ProxyJump 会话串联）
    kInternal,
};

struct ForwardTarget {
    std::string host;
    uint32_t port = 0;
};

/** 状态迁移合法性（静态纯函数，供单测） */
bool isLegalForwardTransition(ForwardState from, ForwardState to);

/** direct-tcpip / -R 目标校验：host 非空且 port ∈ [1,65535] */
bool isValidForwardTarget(const ForwardTarget &target);

/**
 * ProxyJump 规格解析（OpenSSH -J 语法子集）：
 *   "h1" / "user@h1" / "h1:2222" / "user@h1:2222"
 *   多跳逗号分隔："u1@h1:22,u2@h2"
 * 返回跳列表（保持顺序）；规格空/非法返回空 vector。
 * 仅解析字符串，不查库、不拨号——编排在 ArkTS。
 */
struct ProxyJumpHop {
    std::string username; // 可空
    std::string host;
    uint16_t port = 22;   // 未写端口时默认 22
};

std::vector<ProxyJumpHop> parseProxyJumpSpec(const std::string &spec);

/** 多跳串联执行计划（纯逻辑）：hops 为空返回空；否则按 0..n-1 顺序 */
std::vector<ProxyJumpHop> planProxyJumpHops(std::vector<ProxyJumpHop> hops);

/**
 * N16 设计注记（文档函数，返回多行说明；单测断言非空与关键关键字）：
 * 完整 ProxyJump 需要：
 *   1. 连接第 1 跳（真实 TCP + 认证）；
 *   2. 在第 1 跳会话上 openDirectTcpip(next.host, next.port)；
 *   3. 建第 2 跳会话时，把该通道的 read/write 注册为
 *      LIBSSH2_CALLBACK_RECV / LIBSSH2_CALLBACK_SEND（session_callback_set），
 *      替换默认 socket 传输；
 *   4. 重复 2-3 直达终点。
 * 缺口：当前 SshSession 绑定 fd_ + epoll，尚未抽象「传输层」接口；
 * 串联编排与错误传播（中间跳断开 → 下级报错而非挂死）待 N16 完整落地。
 */
std::string proxyJumpTransportNotes();

const char *toString(ForwardKind kind);
const char *toString(ForwardState state);
const char *toString(ForwardError error);
const char *forwardErrorName(ForwardError error); // snake_case，bridge 事件字段

// ---------------------------------------------------------------- 运行时类型

struct ForwardOpenResult {
    bool success = false;
    ForwardError error = ForwardError::kNone;
    std::string message;
    uint32_t boundPort = 0; // 远程监听成功时的实际上报端口
    std::string origin;     // 远程 accept 的 originator（当前 API 拿不到，常为空）
};

struct ForwardCloseInfo {
    std::string reason; // peer_eof | local_close | error | session_lost
    std::string message;
};

struct ForwardCallbacks {
    // 数据通道打开 / 远程监听打开（循环线程，恰好一次）
    std::function<void(const ForwardOpenResult &result)> onOpen;
    // 远端 → 本端字节（0..n 次；data 仅回调内有效）
    std::function<void(const std::string &data)> onData;
    // 打开成功后恰好一次
    std::function<void(const ForwardCloseInfo &info)> onClose;
    // 远程监听：入站连接 accept 成功（循环线程）。raw 为 libssh2 通道句柄
    // 所有权转移给接收方：接收方用**自己的数据面 callbacks** 构造
    // SshForwardChannel 并调用 adoptAccepted(raw, meta) 接管（见该方法）。
    std::function<void(struct _LIBSSH2_CHANNEL *raw, const ForwardOpenResult &meta)> onAccepted;
};

// ---------------------------------------------------------------- 数据通道

/**
 * direct-tcpip（-L/-D）或远程转发 accept 出来的数据通道。
 * 线程契约与 SshChannel 对齐；析构约定：onOpen 失败或 onClose 之后。
 */
class SshForwardChannel {
public:
    static constexpr size_t kMaxPendingWriteBytes = 4 * 1024 * 1024;

    SshForwardChannel(SshSession &session, ForwardCallbacks callbacks);
    ~SshForwardChannel();

    SshForwardChannel(const SshForwardChannel &) = delete;
    SshForwardChannel &operator=(const SshForwardChannel &) = delete;

    /** -L / -D：打开 direct-tcpip 到 host:port（任意线程；结果经 onOpen） */
    bool openDirectTcpip(std::string host, uint32_t port);

    /**
     * 接管已 accept 的 libssh2 通道（循环线程）。由 SshRemoteForward 的
     * onAccepted 回调方（bridge）在用自己的数据面 callbacks 构造本对象后调用；
     * 成功后状态直接进 kOpen 并触发 onOpen。
     */
    void adoptAccepted(struct _LIBSSH2_CHANNEL *channel, ForwardOpenResult meta);

    /** 写入（任意线程）；true = 全部受理。背压整次拒收，同 SshChannel */
    bool write(const char *data, size_t len);
    bool write(const std::string &data) { return write(data.data(), data.size()); }

    /** 关闭（任意线程，幂等） */
    void close();

    ForwardState state() const { return state_.load(std::memory_order_acquire); }
    bool wantsOutboundBlocked() const { return blockedOutbound_; }

    static bool isLegalTransition(ForwardState from, ForwardState to);

private:
    friend class SshSession;      // pump / onSessionLost
    friend class SshRemoteForward;

    bool admitOpen(std::string host, uint32_t port);
    void begin();
    bool pump();
    bool driveOpen();
    bool flushWrites();
    bool drainReads();
    bool driveClose();
    void failOpen(ForwardError error, const std::string &message);
    void finishClose(const std::string &reason, const std::string &message);
    void onSessionLost();
    void noteBlocked();
    void transitionTo(ForwardState to);
    void dropWriteQueue();
    std::string lastLibssh2Error();

    SshSession &session_;
    ForwardCallbacks callbacks_;
    ForwardKind kind_ = ForwardKind::kDirectTcpip;

    std::atomic<ForwardState> state_{ForwardState::kIdle};
    std::atomic<bool> openAdmitted_{false};
    std::atomic<bool> acceptWrites_{false};
    std::atomic<size_t> pendingBytes_{0};
    std::atomic<bool> closeRequested_{false};

    // 受理暂存（post happens-before）
    std::string host_;
    uint32_t port_ = 0;

    // 仅循环线程
    struct _LIBSSH2_CHANNEL *channel_ = nullptr;
    bool blockedOutbound_ = false;
    std::vector<std::string> writeQueue_;
    size_t writeQueueHeadOffset_ = 0;
    bool eofSeen_ = false;
    bool localCloseRequested_ = false;
    bool openFailed_ = false;
    bool closeCompleted_ = false;
    ForwardOpenResult openMeta_; // adoptAccepted 的元数据
};

// ---------------------------------------------------------------- 远程监听（-R）

/**
 * libssh2_channel_forward_listen_ex 监听器。
 * openRemote 受理后经 onOpen 回报；此后 pump 时 accept 入站连接。
 * 每个 accept 产生一个已在 kOpen 的 SshForwardChannel*，经 onAccepted
 * 上抛所有权（调用方负责 close / 析构）。
 */
class SshRemoteForward {
public:
    SshRemoteForward(SshSession &session, ForwardCallbacks callbacks);
    ~SshRemoteForward();

    SshRemoteForward(const SshRemoteForward &) = delete;
    SshRemoteForward &operator=(const SshRemoteForward &) = delete;

    /** 开启远端监听；bindAddress 空 = 服务器默认（通常 all）；port 0 非法 */
    bool openRemote(std::string bindAddress, uint32_t port);

    /** 取消监听（任意线程，幂等）；已 accept 的数据通道不受影响 */
    void cancel();

    ForwardState state() const { return state_.load(std::memory_order_acquire); }
    uint32_t boundPort() const { return boundPort_.load(std::memory_order_acquire); }

private:
    friend class SshSession;

    bool admitOpen(std::string bindAddress, uint32_t port);
    void begin();
    bool pump();
    bool driveOpen();
    bool driveAccept();
    void failOpen(ForwardError error, const std::string &message);
    void finishClose(const std::string &reason, const std::string &message);
    void onSessionLost();
    void noteBlocked();
    void transitionTo(ForwardState to);
    std::string lastLibssh2Error();

    SshSession &session_;
    ForwardCallbacks callbacks_;

    std::atomic<ForwardState> state_{ForwardState::kIdle};
    std::atomic<bool> openAdmitted_{false};
    std::atomic<bool> cancelRequested_{false};
    std::atomic<uint32_t> boundPort_{0};

    std::string bindAddress_;
    uint32_t port_ = 0;

    struct _LIBSSH2_LISTENER *listener_ = nullptr;
    bool blockedOutbound_ = false;
    bool openFailed_ = false;
};

} // namespace ssh
} // namespace sshclient
