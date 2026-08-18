/**
 * SSH 会话生命周期与状态机 —— 任务 N6（DESIGN §2.1，依赖 N5 的 SessionThread/EventLoop）。
 *
 * 状态机（终态：kClosed / kDisconnected / kError）：
 *
 *     idle → connecting(tcp) → handshaking → authenticating → established
 *                ↓                 ↓    ↘       ↓      ↓            ↓
 *              error             error  (N7)  error  disconnected  disconnected
 *                ↓(close)          ↓     closing → closed（主机密钥被拒）
 *                                （authenticating：认证失败停留可重试，超时/超限 → error）
 *                               （任意非终态 close → closing → closed）
 *
 *   - N7 主机密钥 TOFU 校验点：握手成功后、进入 authenticating 前
 *     （libssh2 握手完成后才能取主机密钥）。上层回调拒绝（指纹不匹配/用户否认）时
 *     不进入 authenticating，发 SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE 后走
 *     closing → closed 断开，错误码 kHostKeyMismatch 经 lastError() 可读；
 *   - N8 认证（密码/公钥/keyboard-interactive）：authenticate* / queryAuthMethods
 *     在 authenticating 态受理，非阻塞驱动在循环线程续跑（EAGAIN 重挂 epoll）；
 *     成功 → established；失败 → 停留 authenticating 允许重试（authMaxAttempts 上限），
 *     细分错误码经 AuthCallback 与 lastError() 双通道回报。驱动实现独立在 auth.cpp，
 *     纯逻辑辅助（错误映射/方式解析/抗优化清零）在 auth.h/cpp；
 *   - error 终态细分原因由 lastError() / lastErrorMessage() 提供；
 *     N13 统一错误码体系：SshSessionError 经 ssh/error_codes.h 的
 *     toSshErrorCode() 映射为与 ArkTS SshErrorCode 数值一致的统一码跨层传递。
 *
 * 线程契约（与 EventLoop 对齐）：
 *   - connect() / close() / state() / lastError() 任意线程可调；
 *   - 所有真正的状态迁移都发生在 SessionThread 的事件循环线程，
 *     状态回调也在循环线程触发（bridge 层订阅后自行 post 到 JS 线程，N11）；
 *   - 析构约定：会话到达终态、或 SessionThread::stop() 之后再析构
 *     （析构做兜底资源回收，但不会在运行中的循环上并发摘 fd）。
 *
 * 断线检测：socket ERR / 对端 FIN / RST → disconnected（秒级，见 N6 测试）；
 * 「拔网线无 RST」的静默黑洞检测由 N12 keepalive 落地（established 态周期发
 * 全局请求，连续 keepaliveMaxMisses 个周期无入站活动 → kKeepaliveTimeout 进
 * disconnected；判定口径与近似性见 keepalive.h 头注与 onKeepaliveTick）。
 * 30 s × 3 的周期判定对「切网后旧 socket 成黑洞」太慢，故 P1 另给 probeNow()：
 * ArkTS 侧监听到默认网变化时主动开一个 5 s 短判定窗口（见 doProbeNow / KeepaliveProbe）。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库、POSIX 与 libssh2 公共头，
 * 禁止 include <napi/native_api.h> / <hilog/log.h>（桥接层是 N11）。
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "../io/EventLoop.h"
#include "hostkey.h"
#include "keepalive.h"

// 前向声明 libssh2 会话结构与 keyboard-interactive 回调结构，
// 避免把 <libssh2.h> 漏进公共头
// （tag 名与 libssh2 1.11.x 的 typedef 保持一致，pin 版本升级时需核对）
struct _LIBSSH2_SESSION;
struct _LIBSSH2_USERAUTH_KBDINT_PROMPT;
struct _LIBSSH2_USERAUTH_KBDINT_RESPONSE;

namespace sshclient {
namespace io {
class SessionThread;
}
namespace ssh {

enum class SshSessionState {
    kIdle,
    kConnecting,     // TCP 非阻塞连接进行中
    kHandshaking,    // libssh2_session_handshake 驱动中（含算法协商）
    kAuthenticating, // 握手完成、待认证（N8 认证在此驱动，成功后进 established）
    kEstablished,    // 认证成功（N8 authenticate* 成功时进入）
    kClosing,        // 优雅关闭中（libssh2_session_disconnect 冲刷）
    kClosed,         // 终态：主动关闭完成
    kDisconnected,   // 终态：对端关闭 / 连接异常断开
    kError,          // 终态：连接/握手失败或超时（lastError() 查原因）
};

enum class SshSessionError {
    kNone,
    kResolveFailed,      // getaddrinfo 失败
    kConnectFailed,      // TCP connect 被拒（ECONNREFUSED 等）
    kConnectUnreachable, // N13：网络/主机不可达（ENETUNREACH/EHOSTUNREACH；N6 时并入
                         // kConnectFailed，为统一错误码 104 拆出）
    kConnectTimeout,     // TCP connect 超时（含 SO_ERROR 报 ETIMEDOUT 的内核判定）
    kHandshakeFailed,    // SSH 握手失败（banner/协议错误等非算法类）
    kHandshakeTimeout,   // SSH 握手超时
    kAlgorithmNegotiationFailed, // N13：KEX/算法协商失败（无共同算法等；N6 时并入
                                 // kHandshakeFailed，为统一错误码 301 拆出）
    kHostKeyMismatch,    // N7：主机密钥被上层拒绝（指纹不匹配/首连未获信任）；
                         // 终态为 closed（closing → closed 主动断开），此码经 lastError() 读取
    // ---- N8 认证错误：单次失败时经 AuthCallback 回报并同步到 lastError()（会话仍停
    //      留 authenticating 供重试）；达到 authMaxAttempts / 认证超时后进 error 终态 ----
    kAuthFailedPassword,    // 密码认证被拒（密码错误/用户不存在/密码过期）
    kAuthFailedKey,         // 公钥被服务器拒绝（密钥未授权/签名未通过验证）
    kAuthFailedPassphrase,  // 私钥本地加载/解密失败（短语错误、短语缺失或私钥无法解析；
                            // 细分路径与 libssh2 1.11.1 的吞错行为见 auth.h mapAuthError 详注）
    kAuthFailedInteractive, // keyboard-interactive 应答被服务器拒绝
    kAuthTimeout,           // 单次认证尝试超时（authTimeoutMs，终态 error）
    kDisconnectedByPeer, // 对端关闭（FIN/RST）
    kSocketError,        // 底层 socket 错误
    kKeepaliveTimeout,   // N12：keepalive 静默黑洞——连续 keepaliveMaxMisses 个周期
                         // 无入站活动，或 keepalive 发送本身失败（终态 disconnected）
    kInternal,           // 内部错误（资源创建失败等）
};

// N12 keepalive 默认值（DESIGN §7.1：默认 30 s）；SshSessionOptions 默认值与
// 成员初始式共用，避免两处写死漂移
inline constexpr uint32_t kDefaultKeepaliveIntervalSec = 30;
inline constexpr unsigned kDefaultKeepaliveMaxMisses = 3;
// P1 主动探测的默认判定窗口（秒）：网络切换后 5 s 内给出存活/黑洞裁决，
// 与 TASKS.md P1「WiFi ⇄ 蜂窝切换 5 s 内触发重连」的验收标准同口径
inline constexpr uint32_t kDefaultKeepaliveProbeTimeoutSec = 5;
// libssh2 的 keepalive 最小周期（1.11.1 keepalive.c 把 interval < 2 提升为 2）；
// doProbeNow 借它把「按时间门控的发送」逼出来，语义见该函数注释
inline constexpr uint32_t kLibssh2MinKeepaliveIntervalSec = 2;

struct SshSessionOptions {
    uint32_t connectTimeoutMs = 10000;    // TCP 连接超时
    uint32_t handshakeTimeoutMs = 15000;  // SSH 握手整体超时
    uint32_t closeFlushTimeoutMs = 2000;  // 优雅关闭时 disconnect 报文冲刷上限
    uint32_t authTimeoutMs = 15000;       // N8：单次认证尝试超时（到时按终态 error 处理——
                                          // 对端 15 s 不应答通常意味着链路异常，重试无益）
    uint32_t authMaxAttempts = 3;         // N8：认证失败重试上限，达到后转 error 终态

    // ---- N12 keepalive（established 态生效；DESIGN §7.1 默认 30 s）----
    uint32_t keepaliveIntervalSec = kDefaultKeepaliveIntervalSec; // 发送周期秒数；0 = 关闭
    uint32_t keepaliveMaxMisses = kDefaultKeepaliveMaxMisses; // 连续无入站活动周期数达到
                                                              // 该值判静默黑洞 → kKeepaliveTimeout；
                                                              // 0 = 只发不判

    // N7 主机密钥 TOFU 决策回调（构造后不可变，无并发问题）：
    // 握手成功后、进入 authenticating 前在事件循环线程同步调用，须快速返回
    // （回调契约与异步 UI 确认的正确编排见 hostkey.h 注释）。
    // 为空 = 默认策略：放行并仅记日志报告指纹 —— TOFU 首连语义，仅适合开发联调；
    // 生产必须设置回调，与 ArkTS SQLite 的 known_hosts（DESIGN §5.1）比对后决策。
    HostKeyCallback hostKeyCallback;
};

// ---------------------------------------------------------------- N8 认证 API 类型

// 认证方式枚举（顺序无协议含义，仅作标识）
enum class AuthMethod {
    kPassword,
    kPublicKey,
    kKeyboardInteractive,
};

// keyboard-interactive 服务端单条提示（RFC 4256）：text 为提示语原文
// （如 "Password: "），echo 指示输入是否可回显
struct KbdIntPrompt {
    std::string text;
    bool echo = false;
};

// keyboard-interactive 应答提供者：收到服务端提示列表，返回逐条应答
// （条数不足时剩余按空串应答，通常导致认证失败）。
// 在事件循环线程、libssh2 认证回调内同步调用，必须快速返回——2FA 弹窗属异步
// 交互，上层应先集齐答案再发起认证，或在回调外完成交互后重试（与
// HostKeyCallback 同一契约模式，不得阻塞事件循环）。
using KbdIntResponseProvider =
    std::function<std::vector<std::string>(const std::vector<KbdIntPrompt> &prompts)>;

// 单次认证尝试的结果（AuthCallback 在事件循环线程触发，恰好一次）
struct AuthResult {
    AuthMethod method;
    bool success = false;
    SshSessionError error = SshSessionError::kNone; // 细分错误码；success 时 kNone
    std::string message;      // libssh2 原始错误描述（诊断用）
    unsigned attemptsLeft = 0; // 失败时的剩余可重试次数；0 = 已达上限，会话将进 error 终态
};
using AuthCallback = std::function<void(const AuthResult &result)>;

// 服务端声明支持的认证方式（queryAuthMethods 的回报；解析逻辑见 auth.h parseAuthMethodList）
struct AuthMethodSet {
    bool password = false;
    bool publicKey = false;
    bool keyboardInteractive = false;
    std::vector<std::string> unsupported; // 服务端声明但本端不识别的方式（hostbased 等）
    std::string raw;                      // 服务端返回的原始逗号分隔串（诊断/日志用）
};
// nullopt = 探测失败（详情见 lastErrorMessage / 日志）
using AuthMethodsCallback = std::function<void(std::optional<AuthMethodSet> methods)>;

// N9：应用内 SSH Agent（内存密钥托管），完整定义见 agent.h
class SshAgent;

// N10：shell/exec 通道（channel.h）；经 friend 访问会话内部（libssh2 句柄、
// fd 事件分发、通道注册表），线程契约见 channel.h 头注
class SshChannel;

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

    // ---- N8 认证（任意线程调用；仅 kAuthenticating 态受理，否则返回 false）----
    // 受理语义：凭据被立即复制进会话内部状态，调用方 buffer 随即被 secureZero
    // 清零（「用完即清零」，此后不再被引用；公钥数据等非敏感参数除外——公钥本就会
    // 出现在服务器 authorized_keys 里，无需清零）；返回 false（未受理）时 buffer
    // 原样保留。内部凭据副本在尝试结束（成功/失败/超时/关闭）时同样清零。
    // 结果经 callback 在事件循环线程回报恰好一次：成功 → 状态转 established；
    // 失败 → 停留 authenticating 可再次调用重试，attemptsLeft 耗尽（authMaxAttempts）
    // 或单次尝试超时（authTimeoutMs）→ 转 error 终态。
    // 同一时刻只允许一个认证类操作（含 queryAuthMethods）在进行：并发受理返回 false。
    bool authenticatePassword(std::string &password, AuthCallback callback);
    // 私钥/短语从内存加载（libssh2_userauth_publickey_frommemory）。
    // publicKeyData 为 .pub 公钥文件内容（"ssh-ed25519 AAAA..." 文本）；传空串时
    // libssh2 自行从私钥提取公钥（OpenSSH 格式内嵌公钥）。两条路径下短语错误都
    // 归一化为 kAuthFailedPassphrase（libssh2 1.11.1 两条路径的原始错误码不同且
    // 都会吞掉真实的 KEYFILE_AUTH_FAILED，归一化逻辑见 auth.h mapAuthError 详注）；
    // 推荐显式传入公钥数据：少一次私钥解密，错误语义更贴近真实原因。
    // passphrase 为空串表示无私钥短语。
    // 受理即复制三个 buffer 并清零 privateKeyData / passphrase（公钥非敏感，不清零）。
    bool authenticatePublicKey(std::string &privateKeyData, std::string &publicKeyData,
                               std::string &passphrase, AuthCallback callback);
    // N9：应用内 agent 认证（agent.h）：从 agent 取 keyId 托管的私钥/短语快照，
    // 走 authenticatePublicKey 的同一驱动路径——公钥数据留空，由 libssh2 从私钥
    // 提取（OpenSSH 格式内嵌公钥；两条路径的短语错误归一化见上方注释）。
    // 受理语义与 authenticatePublicKey 相同：快照复制进 AuthOp 后，agent 侧与
    // 本方法内的临时副本随即清零。返回 false = 未受理：会话不在 authenticating /
    // 已有认证类操作进行中 / agent 未解锁或无此 keyId（含超时已惰性清除）——
    // agent 侧取钥失败不算一次认证尝试（不消耗 authMaxAttempts），不回调 callback，
    // 材料快照已在本地清零。
    bool authenticateAgent(const std::string &keyId, SshAgent &agent, AuthCallback callback);
    bool authenticateKeyboardInteractive(KbdIntResponseProvider provider, AuthCallback callback);
    // 探测服务端支持的认证方式（libssh2_userauth_list 非阻塞驱动；与认证尝试互斥）
    bool queryAuthMethods(AuthMethodsCallback callback);

    // ---- N12 keepalive 配置与观测 ----
    // 设置 keepalive 参数（任意线程；仅 idle 态受理——即必须在 connect 之前调用，
    // 返回 false 表示未受理）。进入 established 时生效（libssh2_keepalive_config +
    // 周期定时器），语义见 options 字段注释与 keepalive.h 头注。
    bool setKeepaliveConfig(uint32_t intervalSec, uint32_t maxMisses);
    // P1：主动探测（任意线程；仅 established 受理，返回 false = 未受理）。
    // 网络切换后由 ArkTS 侧调用：立刻发一拍 keepalive 并开 timeoutSec 短窗口，
    // 窗口内无入站活动即以 kKeepaliveTimeout 进 disconnected（走既有重连链）。
    // timeoutSec == 0 用默认 kDefaultKeepaliveProbeTimeoutSec。语义见 keepalive.h KeepaliveProbe。
    bool probeNow(uint32_t timeoutSec);
    // 观测钩子（任意线程，供集成测试与诊断）：进入 established 后 keepalive 的
    // 实际发送次数 / 当前连续无入站活动周期数 / 已受理并执行的主动探测次数
    uint32_t keepaliveSendCount() const { return keepaliveSendCount_.load(std::memory_order_acquire); }
    uint32_t keepaliveMissCount() const { return keepaliveMissCount_.load(std::memory_order_acquire); }
    uint32_t keepaliveProbeCount() const { return keepaliveProbeCount_.load(std::memory_order_acquire); }

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

    // ---- N10 通道支撑（全部仅事件循环线程调用；SshChannel 经 friend 访问）----
    friend class SshChannel;
    void registerChannel(SshChannel *channel);   // established 态装配时注册
    void unregisterChannel(SshChannel *channel); // 通道收尾时注销（幂等）
    void driveChannels();      // established 态 fd 事件分发：泵送全部注册通道
    void notifyChannelsSessionLost(); // releaseResources 前置：全部通道 kError 清理

    // ---- N12 keepalive（全部仅事件循环线程执行）----
    void armKeepalive();    // 进入 established 时装配：libssh2_keepalive_config + 首拍定时
    void onKeepaliveTick(); // 每拍：观测入站活动 → 发送 → 按 seconds_to_next 预约下一拍
    void doProbeNow(uint32_t timeoutSec);        // P1：强发一拍 + 开短判定窗口（probeNow 的循环线程侧）
    void onProbeDeadline(uint32_t timeoutSec);   // P1：短窗口到期裁决——无入站判黑洞，有入站续回周期链

    // ---- N8 认证驱动（循环线程；实现在 auth.cpp，避免 session.cpp 臃肿）----
    // 进行中的认证尝试：方式、凭据副本（受理时复制并清零调用方 buffer）、超时定时器。
    // 析构在 auth.cpp 定义——secureZero 清零内存凭据（成功/失败/中止路径都经由此处）。
    struct AuthOp {
        AuthMethod method = AuthMethod::kPassword;
        std::string password;            // kPassword 的密码副本
        std::string privateKey;          // kPublicKey 的私钥字节副本
        std::string publicKey;           // kPublicKey 的 .pub 公钥文本（可空=从私钥提取）
        std::string passphrase;          // kPublicKey 的私钥短语副本（可空）
        KbdIntResponseProvider provider; // kKeyboardInteractive 的应答提供者
        AuthCallback callback;
        io::EventLoop::TimerId timer = 0;
        ~AuthOp();
    };
    void beginAuthOp();            // 受理装配：接管 authOpStaging_、挂超时、首驱
    void driveAuth();              // 驱动当前认证尝试（EAGAIN 续跑，一次调用推进一步）
    void beginAuthMethodsQuery(AuthMethodsCallback callback); // 受理装配方式探测
    void driveAuthMethodsQuery();  // 驱动 userauth_list 探测
    void finishAuthMethodsQuery(std::optional<AuthMethodSet> result); // 探测收尾回报
    void clearAuthState();         // 摘认证定时器、清零内存凭据、释放受理位（幂等）
    bool hasAuthPending() const { return authOp_ != nullptr || authMethodsCallback_ != nullptr; }
    // keyboard-interactive 的 libssh2 C 回调桥：static 成员以满足 C 回调签名，
    // 经 session abstract（beginHandshake 时传入 this）找回实例
    static void kbdIntResponseCb(const char *name, int nameLen,
                                 const char *instruction, int instructionLen, int numPrompts,
                                 const _LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                                 _LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses, void **abstract);
    void onKbdIntPrompts(int numPrompts, const _LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                         _LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses);

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

    // ---- N8 认证状态 ----
    // authOp_ / authMethodsCallback_ 仅事件循环线程访问；
    // authBusy_ 是认证类操作的受理占位（任意线程 CAS，循环线程释放），
    // 语义与 connectAdmitted_ 相同；authOpStaging_ 由受理线程在 post 前写入、
    // 循环线程在 beginAuthOp 接管（happens-before 依据与 connect 参数相同，
    // 且受理位的 release/acquire 链保证上一次操作的读取先于本次写入）
    std::atomic<bool> authBusy_{false};
    std::unique_ptr<AuthOp> authOpStaging_; // 受理线程 → 循环线程的交接槽
    std::unique_ptr<AuthOp> authOp_;        // 进行中的认证尝试（EAGAIN 续跑上下文）
    AuthMethodsCallback authMethodsCallback_; // 进行中的方式探测回调（与 authOp_ 互斥）
    io::EventLoop::TimerId authMethodsTimer_ = 0;
    unsigned authFailedAttempts_ = 0; // 已连续失败的认证次数（对照 options_.authMaxAttempts）

    // ---- N10 通道注册表（仅事件循环线程访问）----
    // established 态的 fd 事件经 driveChannels 泵送到每个通道；会话断开/关闭时
    // 经 notifyChannelsSessionLost 全部清理。通道完成收尾（finishClose）后自行注销。
    std::vector<SshChannel *> channels_;

    // ---- N12 keepalive 状态（除两个 atomic 计数器外仅事件循环线程访问）----
    io::EventLoop::TimerId keepaliveTimer_ = 0; // 下一拍定时（逐拍 runAfter 预约，见 onKeepaliveTick）
    KeepaliveMissTracker keepaliveMissTracker_{kDefaultKeepaliveMaxMisses}; // 受理配置时重建
    bool keepaliveInboundSeen_ = false;  // 本周期内 fd 事件出现过 EPOLLIN
    long keepalivePendingBaseline_ = 0;  // 上一拍 socket 待读字节数（FIONREAD 基线）
    // P1 主动探测窗口（仅循环线程访问；到期定时器复用 keepaliveTimer_ 槽位，
    // 故断线/关闭时的 cancelTimers 一并覆盖它）
    KeepaliveProbe keepaliveProbe_;
    // 上一次「真正发出」keepalive 的时刻（steady_clock 毫秒；0 = 尚未发过）。
    // doProbeNow 据此判断 libssh2 是否会跳过本次发送（见其实现注释）
    uint64_t keepaliveLastSentMs_ = 0;
    // 观测钩子：循环线程写、任意线程读（集成测试断言 keepalive 在跑且不误判）
    std::atomic<uint32_t> keepaliveSendCount_{0};
    std::atomic<uint32_t> keepaliveMissCount_{0};
    std::atomic<uint32_t> keepaliveProbeCount_{0};
};

const char *toString(SshSessionState state);
const char *toString(SshSessionError error);

// N12：给定终态与错误码，判定「是否值得自动重连」（纯函数，供 bridge 给
// stateChange 终态事件附 reconnectHint 字段；重连编排本身在 ArkTS 侧）：
//   - disconnected：一律 true（对端关闭/socket 错误/keepalive 黑洞都可能是瞬态网络问题）；
//   - error：按错误码分——链路类（解析失败/连接被拒或不可达或超时/握手失败或超时/
//     socket 错误/认证超时，多为瞬态网络问题）true；凭据类（密码/公钥/短语/
//     interactive 被拒，重连同样的凭据必然再败）、协商类（算法不匹配，重连同样的
//     算法集必然再败）与 kInternal（本端资源问题）false；
//   - closed（主动关闭、含主机密钥被拒）与其余非终态：false。
bool isAutoReconnectable(SshSessionState terminalState, SshSessionError error);

} // namespace ssh
} // namespace sshclient
