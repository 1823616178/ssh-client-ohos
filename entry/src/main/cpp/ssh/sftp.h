/**
 * SFTP native 层 —— 任务 N14（DESIGN §7.4，依赖 N10 会话/通道）。
 *
 * 分层：
 *   1. 纯逻辑（本头 + sftp.cpp 纯函数区）：路径拼接/归一化、权限格式化、
 *      传输队列状态机、rename 目标校验——宿主单测直接覆盖，不依赖 sshd；
 *   2. SshSftp：libssh2_sftp_* 封装（opendir/readdir/closedir、stat、
 *      open/read/write/close、rename、mkdir、rmdir、unlink、chmod、symlink 读）。
 *      线程契约与 SshChannel 对齐：任意线程受理，post 进会话事件循环执行，
 *      回调在循环线程触发，接收方自行切线程（N11 bridge 职责）。
 *
 * 打开语义：SshSftp 绑定一个已 established 的 SshSession，在首次操作时
 * libssh2_sftp_init（或显式 open()）；会话断开/关闭时 onSessionLost 强制收尾。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库，禁止 include <napi/native_api.h> /
 * <hilog/log.h>（桥接层是 N11/sftp_bridge）。
 */
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// 前向声明，避免把 <libssh2_sftp.h> 漏进公共头（同 session.h/channel.h 惯例）
struct _LIBSSH2_SFTP;
struct _LIBSSH2_SFTP_HANDLE;

namespace sshclient {
namespace ssh {

class SshSession;

// ---------------------------------------------------------------- 纯逻辑：路径与类型

enum class SftpEntryType {
    kFile,
    kDir,
    kSymlink,
    kOther,
};

enum class SftpError {
    kNone,
    kNotEstablished, // 会话未 established / SFTP 未打开
    kOpenFailed,     // libssh2_sftp_init / channel open 失败
    kPathInvalid,    // 空路径 / 非法归一化结果
    kNoSuchFile,     // 路径不存在
    kPermissionDenied,
    kAlreadyExists,
    kNotDir,   // 期望目录却是文件
    kNotFile,  // 期望文件却是目录
    kIoError,
    kCancelled,
    kSessionLost,
    kNotSupported,
    kInternal,
};

struct SftpEntry {
    std::string name;           // 基名（不含目录）
    std::string path;           // 完整远端路径
    SftpEntryType type = SftpEntryType::kFile;
    uint64_t size = 0;          // 字节；目录/链接可为 0
    uint64_t mtime = 0;         // Unix 秒
    uint32_t mode = 0;          // Unix st_mode 低 12 位（含类型位）
    std::string permissions;    // "rwxr-xr-x" 形式（formatSftpPermissions）
    std::string linkTarget;     // symlink 目标；非 symlink 为空
};

/** 路径拼接：dir + '/' + name，处理 dir 为空/根目录、name 自带前导斜杠 */
std::string sftpJoinPath(const std::string &dir, const std::string &name);

/** 父路径："/a/b/c" → "/a/b"；"/a" → "/"；"/" → "/"；相对 "a/b" → "a" */
std::string sftpParentPath(const std::string &path);

/** 基名："/a/b/c" → "c"；"/" → ""；"a" → "a" */
std::string sftpBaseName(const std::string &path);

/**
 * 归一化：折叠重复斜杠、解析 "." 与 ".."。
 * 绝对路径保持绝对；相对路径保持相对；上溯越过根时钳到根。
 * 返回空串表示输入非法（调用方映射 kPathInvalid）。
 */
std::string sftpNormalizePath(const std::string &path);

/** Unix mode（含类型位）→ "rwxr-xr-x"（9 字符；类型位不进字符串） */
std::string formatSftpPermissions(uint32_t mode);

/** 从 LIBSSH2_SFTP_ATTRIBUTES.permissions / LIBSSH2_SFTP_S_XXX 判类型 */
SftpEntryType sftpTypeFromMode(uint32_t mode);

/** 列表排序键：目录优先，再按名称（大小写敏感，locale 无关字节序） */
bool sftpEntryLess(const SftpEntry &a, const SftpEntry &b);

/** 过滤 "." / ".."（UI 列表默认不展示，保留工具函数供测试） */
std::vector<SftpEntry> sftpFilterDotEntries(std::vector<SftpEntry> entries);

// ---------------------------------------------------------------- 纯逻辑：传输队列

enum class TransferDirection { kDownload, kUpload };

enum class TransferState {
    kQueued,
    kRunning,
    kPaused,
    kCompleted,
    kFailed,
    kCancelled,
};

struct TransferJob {
    uint64_t id = 0;
    TransferDirection direction = TransferDirection::kDownload;
    std::string remotePath;
    std::string localPath;
    uint64_t totalBytes = 0;
    uint64_t transferredBytes = 0;
    TransferState state = TransferState::kQueued;
    int errorCode = 0; // SftpError 数值（与 ArkTS SftpErrorName 对齐）
    std::string errorMessage;
};

/** 状态机：能否启动 / 取消 / 重试 / 暂停 */
bool canStartTransfer(TransferState s);
bool canCancelTransfer(TransferState s);
bool canRetryTransfer(TransferState s);
bool canPauseTransfer(TransferState s);

/**
 * 进度推进：仅 kRunning 允许；transferred 钳到 total；相等时保持 kRunning
 *（完成由 completeTransfer 显式宣告，避免「先完成再失败」竞态）。
 * 非法迁移返回原状态（不改写入参以外的状态）。
 */
TransferState progressTransferState(TransferState s);

/** 完成宣告：kRunning/kPaused → kCompleted（success）或 kFailed（!success） */
TransferState completeTransferState(TransferState s, bool success);

/** 取消：kQueued/kRunning/kPaused → kCancelled；终态保持不变 */
TransferState cancelTransferState(TransferState s);

/** 重试：kFailed/kCancelled → kQueued；其余返回原状态 */
TransferState retryTransferState(TransferState s);

/**
 * rename 目标校验（纯逻辑）：源与目标都须非空且归一化后不同；
 * 目标基名不得为 "." / ".."；返回 nullopt = 合法，否则给错误原因。
 */
std::optional<std::string> validateSftpRename(const std::string &fromPath,
                                              const std::string &toPath);

const char *toString(SftpEntryType type);
const char *toString(SftpError error);
const char *toString(TransferState state);
const char *toString(TransferDirection dir);

// SftpError → 统一展示用调试名（snake_case，bridge 事件字段）
const char *sftpErrorName(SftpError error);

// ---------------------------------------------------------------- SshSftp 运行时封装

struct SftpOpenResult {
    bool success = false;
    SftpError error = SftpError::kNone;
    std::string message;
};

struct SftpListResult {
    bool success = false;
    SftpError error = SftpError::kNone;
    std::string path; // 请求的路径（归一化后）
    std::string message;
    std::vector<SftpEntry> entries; // 已滤掉 "." / ".."，目录优先排序
};

struct SftpStatResult {
    bool success = false;
    SftpError error = SftpError::kNone;
    std::string path;
    std::string message;
    SftpEntry entry;
};

struct SftpOpResult {
    bool success = false;
    SftpError error = SftpError::kNone;
    std::string op; // "rename"|"mkdir"|"rmdir"|"unlink"|"chmod"|"readlink"
    std::string path;
    std::string message;
    std::string linkTarget; // 仅 readlink 成功时有效
};

struct SftpTransferProgress {
    uint64_t transferId = 0;
    uint64_t transferred = 0;
    uint64_t total = 0;
};

struct SftpTransferResult {
    uint64_t transferId = 0;
    bool success = false;
    SftpError error = SftpError::kNone;
    std::string message;
    uint64_t transferred = 0;
    uint64_t total = 0;
};

struct SftpCallbacks {
    std::function<void(const SftpOpenResult &)> onOpen;
    std::function<void(const SftpListResult &)> onList;
    std::function<void(const SftpStatResult &)> onStat;
    std::function<void(const SftpOpResult &)> onOp;
    std::function<void(const SftpTransferProgress &)> onProgress; // 可空
    std::function<void(const SftpTransferResult &)> onTransfer;
};

/**
 * 一个会话上的 SFTP 通道。生命周期：构造 → open（或首次操作懒打开）→
 * list/stat/transfer/op* → close。会话丢失时全部在途操作以 kSessionLost 收尾。
 *
 * 线程：open/list/stat/download/upload/op* 任意线程可调（受理即 post）；
 * close 幂等；析构约定与 SshChannel 一致——回调发完后才可析构。
 */
class SshSftp {
public:
    // 进度回调最小间隔（字节）：避免每个 read 都打事件（UI 进度条足够）
    static constexpr uint64_t kProgressReportBytes = 64 * 1024;

    SshSftp(SshSession &session, SftpCallbacks callbacks);
    ~SshSftp();

    SshSftp(const SshSftp &) = delete;
    SshSftp &operator=(const SshSftp &) = delete;

    bool open(); // 受理；结果经 onOpen（幂等：已打开再调直接成功回报）
    bool list(std::string path);
    bool stat(std::string path);
    bool download(uint64_t transferId, std::string remotePath, std::string localPath);
    bool upload(uint64_t transferId, std::string localPath, std::string remotePath);
    bool rename(std::string fromPath, std::string toPath);
    bool mkdir(std::string path, uint32_t mode);
    bool rmdir(std::string path);
    bool unlink(std::string path);
    bool chmod(std::string path, uint32_t mode);
    bool readlink(std::string path);
    void close(); // 幂等

    bool isOpened() const { return opened_.load(std::memory_order_acquire); }

    /** 步骤状态机迁移合法性（静态纯函数，供单测） */
    static bool isLegalStateTransition(bool wasOpened, bool willOpen);

private:
    friend class SshSession; // onSessionLost 回呼

    enum class OpKind {
        kList,
        kStat,
        kRename,
        kMkdir,
        kRmdir,
        kUnlink,
        kChmod,
        kReadlink,
        kDownload,
        kUpload,
    };

    struct PendingOp {
        OpKind kind = OpKind::kList;
        std::string path;
        std::string path2; // rename 目标 / upload 远端
        uint32_t mode = 0;
        uint64_t transferId = 0;
    };

    bool admit(PendingOp op); // 任意线程：CAS/参数暂存/post
    void ensureOpenOnLoop();  // 循环线程：懒打开
    void runOp(PendingOp op); // 循环线程
    void finishOpen(SftpError error, const std::string &message);
    void onSessionLost();
    SftpError mapLibssh2Errno(int code) const;
    std::string lastLibssh2Error() const;
    void closeOnLoop();

    // 循环线程操作实现
    void doList(const std::string &path);
    void doStat(const std::string &path);
    void doOp(const PendingOp &op);
    void doTransfer(const PendingOp &op);

    SshSession &session_;
    SftpCallbacks callbacks_;

    std::atomic<bool> opened_{false};
    std::atomic<bool> closeRequested_{false};
    std::atomic<bool> openAdmitted_{false};

    // ---- 以下成员仅事件循环线程访问 ----
    struct _LIBSSH2_SFTP *sftp_ = nullptr;
    std::vector<PendingOp> queue_;
    bool busy_ = false;
};

} // namespace ssh
} // namespace sshclient
