/**
 * SSH 通道与 PTY —— 任务 N10（DESIGN §7.2，依赖 N6 会话状态机与 N8 认证完成态）。
 *
 * SshChannel 绑定一个 SshSession 实例，覆盖三种打开形态（均为三步 EAGAIN 续跑）：
 *   - openShell：channel_open_session → request_pty → process_startup("shell")
 *   - exec：channel_open_session → process_startup("exec", command)（无 PTY）
 *   - execWithPty：open_session → request_pty → process_startup("exec", command)
 *     （stty size 这类需要 PTY 的一次性命令走这条）
 * 内部步骤状态机 idle → opening → pty → starting → open，每一步都可能 EAGAIN，
 * 在事件循环上按 libssh2_session_block_directions 声明的方向挂 EPOLLIN/EPOLLOUT
 * 续跑，模式与 N6 握手 / N8 认证一致。
 *
 * 数据面：
 *   - 读：socket 事件由 SshSession 分发（driveChannels）泵送，libssh2_channel_read_ex
 *     双流抽干——stream 0 = stdout、SSH_EXTENDED_DATA_STDERR = stderr（libssh2 1.11
 *     没有把 extended data 单独取走的公开 API，stderr 只能走 stream 读；默认
 *     EXTENDED_DATA_NORMAL 模式下 stderr 不会混入 stdout），经 DataCallback 上抛；
 *   - 写：write() 任意线程可调，受理后 post 进循环线程入内部待发队列；EAGAIN 时
 *     留存剩余部分，可写后续发；队列上限 4 MiB，超出整次拒收（背压，返回 false）。
 *     发送停滞按 libssh2 声明的阻塞方向挂事件：对端不读导致窗口耗尽时是 INBOUND
 *     停滞，靠常开的 EPOLLIN 等窗口调整报文，不会挂 EPOLLOUT 空转；
 *   - resize：libssh2_channel_request_pty_size_ex（像素维度传 0；DESIGN §4.3.1：
 *     窗格尺寸变化各自向远端发 request_pty_size，远端 sshd ioctl TIOCSWINSZ 后
 *     向前台进程组发 SIGWINCH）。多次调用在途合并，最后一次生效；
 *   - EOF/退出信息：对端 EOF（libssh2_channel_eof；libssh2 内部 remote close 同时
 *     置 eof，对端直接 close 的 abrupt 路径同样覆盖）→ 抽干剩余数据 →
 *     libssh2_channel_close 握手（EAGAIN 续跑）→ 取 exit-status / exit-signal →
 *     free → CloseCallback 通知关闭原因（kPeerEof / kExitStatus / kExitSignal /
 *     kError）。exit-status 是否到达无公开 API 可判（libssh2 只有字段读取），
 *     OpenSSH 的 shell/exec 通道按 RFC 4254 §6.10 总会发送，未发送时报 0；
 *   - sendEof()：本端输入结束告知对端（exec("cat") 这类等 EOF 退出的场景）。
 *
 * 窗口调整：不手工调 libssh2_channel_receive_window_adjust —— 读路径
 * _libssh2_channel_read 内部按消费量自动回补窗口（libssh2 1.11 channel.c），
 * 默认 2 MiB 窗口对终端场景够用；日后 SFTP 大文件（N14）再评估手工调整。
 *
 * 生命周期与回调契约：
 *   - onOpen 恰好触发一次：成功 → 通道进 kOpen；失败（打开被拒/pty 被拒/启动失败/
 *     会话竞态断开）→ 通道直接终结，不再有 onClose；
 *   - onData 仅在 kOpen 期间触发（0..n 次）；
 *   - onClose 仅在打开成功后触发，恰好一次，携带关闭原因与退出信息；
 *   - 会话断开/关闭（含主动 session.close()）时，注册中的全部通道经
 *     onSessionLost 收到 kError 关闭通知（打开中的通道改发 onOpen 失败）并清理。
 *
 * 线程契约（与 SshSession 对齐）：
 *   - openShell/exec/execWithPty/write/resize/sendEof/close/state 任意线程可调，
 *     受理后经 SessionThread::post 切到会话的事件循环线程执行（FIFO 保序）；
 *   - 所有 libssh2 调用与三个回调都在循环线程触发，接收方自行 post 切线程
 *     （N11 bridge 的职责）；回调内不得析构本对象；
 *   - 析构约定：onOpen 失败或收到 onClose 之后才可析构（与 SshSession 的
 *     「终态后析构」同一风格）；SshSession / SessionThread 生命周期须长于本对象。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库、POSIX 与 libssh2 公共头，
 * 禁止 include <napi/native_api.h> / <hilog/log.h>（桥接层是 N11）。
 */
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <optional>
#include <string>
#include <utility>

// 前向声明，避免把 <libssh2.h> 漏进公共头（同 session.h 惯例）
struct _LIBSSH2_CHANNEL;

namespace sshclient {
namespace ssh {

class SshSession;

// 通道步骤状态机：idle → opening → pty → starting → open → closing → closed
// （pty 步仅带 PTY 的形态经过；任何非终态可因失败/本地关闭/会话丢失进 closing/closed）
enum class ChannelState {
    kIdle,
    kOpening,       // libssh2_channel_open_session 驱动中
    kRequestingPty, // libssh2_channel_request_pty_ex 驱动中
    kStarting,      // libssh2_channel_process_startup 驱动中
    kOpen,          // 就绪：读写/resize/sendEof 进行中
    kClosing,       // close 握手驱动中（对端 EOF/本地 close/失败后清理）
    kClosed,        // 终态：句柄已释放、已从会话注销、回调已发完
};

enum class ChannelStream {
    kStdout, // SSH_MSG_CHANNEL_DATA（stream 0）
    kStderr, // SSH_MSG_CHANNEL_EXTENDED_DATA（SSH_EXTENDED_DATA_STDERR）
};

enum class ChannelCloseReason {
    kPeerEof,    // 通道以 EOF/close 语义收尾、无进程退出信息（本端主动 close 的
                 // 干净收尾也归此；exitStatus/exitSignal 无效）
    kExitStatus, // 对端进程正常退出，exitStatus 有效（OpenSSH shell/exec 总会发送）
    kExitSignal, // 对端进程被信号杀死，exitSignal 有效（不含 "SIG" 前缀，如 "KILL"）
    kError,      // 异常：传输/会话丢失、libssh2 错误（message 携带诊断）
};

enum class SshChannelError {
    kNone,
    kNotEstablished, // 受理时会话不在 established（受理后竞态断开也归此）
    kOpenFailed,     // channel_open_session 被拒（对端通道数上限等）
    kPtyFailed,      // request_pty 被拒
    kStartupFailed,  // process_startup（shell/exec）失败
    kSessionLost,    // 会话断开/关闭导致通道被清理
};

struct PtySpec {
    std::string termType = "xterm-256color"; // DESIGN §7.2：xterm-256color 真彩
    uint32_t cols = 80;
    uint32_t rows = 24;
};

struct ChannelOpenResult {
    bool success = false;
    SshChannelError error = SshChannelError::kNone; // success 时 kNone
    std::string message;                            // 失败诊断（libssh2 原始描述）
};

struct ChannelCloseInfo {
    ChannelCloseReason reason = ChannelCloseReason::kPeerEof;
    int exitStatus = 0;       // 仅 kExitStatus 有效
    std::string exitSignal;   // 仅 kExitSignal 有效（如 "KILL"）
    std::string message;      // kError 诊断 / 其他原因的补充说明
};

struct SshChannelCallbacks {
    // 恰好一次（循环线程）；失败即终态，不再有 onClose
    std::function<void(const ChannelOpenResult &result)> onOpen;
    // 0..n 次（循环线程）；data 仅本次回调内有效，接收方须自行复制/切线程
    std::function<void(const std::string &data, ChannelStream stream)> onData;
    // 打开成功后恰好一次（循环线程）；触发后通道进终态，可安全析构
    std::function<void(const ChannelCloseInfo &info)> onClose;
};

class SshChannel {
public:
    // 待发队列上限（背压阈值）：write() 受理后 pendingWriteBytes 超出即整次拒收
    static constexpr size_t kMaxPendingWriteBytes = 4 * 1024 * 1024;

    // 任意线程可构造；callbacks 构造后不可变（无并发问题）。session 生命周期须更长。
    SshChannel(SshSession &session, SshChannelCallbacks callbacks);
    ~SshChannel();

    SshChannel(const SshChannel &) = delete;
    SshChannel &operator=(const SshChannel &) = delete;

    // ---- 打开（任意线程；仅 kIdle 受理，返回 true = 已受理，结果经 onOpen 回报）----
    // 受理语义：会话当前须在 established 态且本通道未被打开过；参数复制后经 post
    // 切到循环线程装配。受理返回后（不必等 onOpen）即可 write/resize/sendEof——
    // 数据在通道就绪前排入待发队列，就绪后按序冲刷。
    bool openShell(PtySpec pty);
    bool exec(std::string command);                       // 无 PTY
    bool execWithPty(PtySpec pty, std::string command);   // 带 PTY 的一次性命令

    // ---- 数据写入（任意线程）----
    // true = 全部受理（入队/直写）；false = 通道已关/未受理打开/背压拒收。
    // 背压语义为整次拒收（不部分接收），调用方应保留数据稍后重试。
    bool write(const char *data, size_t len);
    bool write(const std::string &data) { return write(data.data(), data.size()); }

    // ---- PTY 尺寸调整（任意线程；仅带 PTY 且已受理打开的通道受理）----
    // 在途多次调用合并，最后一次生效；返回 false = 无 PTY / 未受理 / 已关闭。
    bool resize(uint32_t cols, uint32_t rows);

    // ---- 本端 EOF（任意线程；exec("cat") 等等待 stdin 结束的对端程序用）----
    bool sendEof();

    // 关闭（任意线程，幂等）：打开中则等打开完成后立即收尾；kOpen 态尽力冲刷
    // 待发队列后走 close 握手。结果经 onClose 回报（原因视对端退出信息而定）。
    void close();

    ChannelState state() const { return state_.load(std::memory_order_acquire); }
    // 背压观测：当前待发字节数（任意线程可读，测试/bridge 用）
    size_t pendingWriteBytes() const { return pendingBytes_.load(std::memory_order_acquire); }

    // 步骤状态机迁移合法性表（静态纯函数，供单测校验边界；同 SshSession 惯例）
    static bool isLegalTransition(ChannelState from, ChannelState to);

private:
    friend class SshSession; // 事件分发（pump）与会话清理（onSessionLost）回呼

    enum class RequestKind { kShell, kExec };

    // open* 的公共受理路径（任意线程）：CAS 占位 → 暂存参数 → post 装配
    bool admitOpen(RequestKind kind, bool withPty, PtySpec pty, std::string command);

    // ---- 以下方法全部只在事件循环线程执行 ----
    void begin();                 // open* 受理后的装配入口（post 进循环线程）
    bool pump();                  // 总泵：推进状态机/冲刷/抽干/收尾；返回是否有进展
    bool driveOpen();             // opening → pty → starting 三步续跑（一次可连过多步）
    bool driveResize();           // 待生效 resize 续跑
    bool driveSendEof();          // 待发送 EOF 续跑
    bool flushWrites();           // 待发队列冲刷（EAGAIN 留存）
    bool drainReads();            // stdout/stderr 双流抽干 + EOF 观测
    bool driveClose();            // close 握手 → 取退出信息 → free → 收尾
    void failOpen(SshChannelError error, const std::string &message); // 打开失败终结
    void finishClose(ChannelCloseReason reason, const std::string &message); // 注销+回调
    void collectExitInfo();       // close 完成后取 exit-status / exit-signal
    void onSessionLost();         // 会话断开/关闭时的强制清理（releaseResources 内调用）
    bool wantsOutboundBlocked() const { return blockedOutbound_; } // session 挂 EPOLLOUT 依据
    void noteBlocked();           // EAGAIN 后按 libssh2 声明方向记录 blockedOutbound_
    void transitionTo(ChannelState to);
    void dropWriteQueue();        // 丢弃待发队列并退账（关闭/失败路径）
    std::string lastLibssh2Error(); // 取 libssh2 session 级错误描述（诊断）

    SshSession &session_;
    SshChannelCallbacks callbacks_;

    // ---- 跨线程可见状态 ----
    std::atomic<ChannelState> state_{ChannelState::kIdle}; // 循环线程写、任意线程读
    std::atomic<bool> openAdmitted_{false};   // open* 受理占位（CAS 防重复打开）
    std::atomic<bool> acceptWrites_{false};   // write/resize/sendEof 受理开关
    std::atomic<size_t> pendingBytes_{0};     // 待发队列字节数（背压记账）
    std::atomic<bool> closeRequested_{false}; // close() 幂等占位
    std::atomic<bool> hasPty_{false};         // 受理时定型（resize 受理判断用）

    // ---- open* 受理暂存（受理线程 post 前写入，经 post 互斥锁与循环线程
    //      构成 happens-before；同 SshSession::connect 惯例）----
    RequestKind kind_ = RequestKind::kShell;
    PtySpec pty_;
    std::string command_;

    // ---- 以下成员仅事件循环线程访问 ----
    struct _LIBSSH2_CHANNEL *channel_ = nullptr;
    bool blockedOutbound_ = false;     // 最近一次 EAGAIN 的发送方向为 OUTBOUND
    std::deque<std::string> writeQueue_; // 待发队列（分块；flush 从队首消费）
    size_t writeQueueHeadOffset_ = 0;    // 队首块已发送偏移
    std::optional<std::pair<uint32_t, uint32_t>> pendingResize_; // 待生效尺寸（合并语义）
    bool eofRequested_ = false;        // sendEof 已受理
    bool eofSent_ = false;             // libssh2_channel_send_eof 已成功
    bool eofSeen_ = false;             // 对端 EOF/close 已观测（含 read==0）
    bool localCloseRequested_ = false; // close() 已到达循环线程
    bool openFailed_ = false;          // 打开失败后的清理路径：finishClose 不再发 onClose
    bool closeCompleted_ = false;      // libssh2_channel_close 已返回 0
    int exitStatus_ = 0;               // collectExitInfo 采集结果
    std::string exitSignal_;
};

const char *toString(ChannelState state);
const char *toString(ChannelCloseReason reason);
const char *toString(SshChannelError error);

} // namespace ssh
} // namespace sshclient
