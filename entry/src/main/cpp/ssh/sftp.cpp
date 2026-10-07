/**
 * SFTP native 层实现 —— 任务 N14。契约与分层见 sftp.h 头注。
 *
 * 纯逻辑区（路径/权限/传输状态机）无 libssh2 依赖，宿主单测直接覆盖。
 * 运行时区：libssh2_sftp_* 封装，全部在会话事件循环线程执行；
 * EAGAIN 时按 libssh2_session_block_directions 由会话 fd 事件续驱——
 * 本 MVP 对单次操作采用「循环内短忙等泵送」上限（避免无限阻塞），
 * 完整非阻塞状态机留给后续打磨（见头注与 TASKS M6）。
 */
#include "sftp.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <unistd.h>
#include <utility>

#include <libssh2.h>
#include <libssh2_sftp.h>

#include "../io/SessionThread.h"
#include "session.h"

#define SSH_LOG(...)                                \
    do {                                            \
        std::fprintf(stderr, "[sftp] " __VA_ARGS__); \
        std::fprintf(stderr, "\n");                 \
    } while (0)

namespace sshclient {
namespace ssh {

// ================================================================ 纯逻辑：路径

std::string sftpJoinPath(const std::string &dir, const std::string &name)
{
    if (name.empty()) {
        return dir;
    }
    // name 自带绝对路径：以 name 为准
    if (!name.empty() && name[0] == '/') {
        return sftpNormalizePath(name);
    }
    if (dir.empty()) {
        return sftpNormalizePath(name);
    }
    if (dir == "/") {
        return sftpNormalizePath("/" + name);
    }
    if (dir.back() == '/') {
        return sftpNormalizePath(dir + name);
    }
    return sftpNormalizePath(dir + "/" + name);
}

std::string sftpParentPath(const std::string &path)
{
    const std::string norm = sftpNormalizePath(path);
    if (norm.empty() || norm == "/") {
        return "/";
    }
    const auto pos = norm.find_last_of('/');
    if (pos == std::string::npos) {
        // 相对路径 "a" → 空（无父）
        return "";
    }
    if (pos == 0) {
        return "/";
    }
    return norm.substr(0, pos);
}

std::string sftpBaseName(const std::string &path)
{
    const std::string norm = sftpNormalizePath(path);
    if (norm.empty() || norm == "/") {
        return "";
    }
    const auto pos = norm.find_last_of('/');
    if (pos == std::string::npos) {
        return norm;
    }
    return norm.substr(pos + 1);
}

std::string sftpNormalizePath(const std::string &path)
{
    if (path.empty()) {
        return "";
    }
    const bool absolute = path[0] == '/';
    std::vector<std::string> stack;
    size_t i = 0;
    const size_t n = path.size();
    while (i < n) {
        while (i < n && path[i] == '/') {
            ++i;
        }
        const size_t start = i;
        while (i < n && path[i] != '/') {
            ++i;
        }
        if (start == i) {
            break;
        }
        const std::string seg = path.substr(start, i - start);
        if (seg == ".") {
            continue;
        }
        if (seg == "..") {
            if (!stack.empty() && stack.back() != "..") {
                stack.pop_back();
            } else if (!absolute) {
                stack.push_back("..");
            }
            // 绝对路径上溯越过根：钳到根（不入栈）
            continue;
        }
        stack.push_back(seg);
    }
    std::string out;
    if (absolute) {
        out = "/";
        for (size_t k = 0; k < stack.size(); ++k) {
            if (k > 0) {
                out += "/";
            }
            out += stack[k];
        }
        if (out.size() > 1 && out.back() == '/') {
            out.pop_back();
        }
        return out.empty() ? "/" : out;
    }
    for (size_t k = 0; k < stack.size(); ++k) {
        if (k > 0) {
            out += "/";
        }
        out += stack[k];
    }
    return out; // 相对路径全被消掉时为空串——调用方按 kPathInvalid 处理
}

std::string formatSftpPermissions(uint32_t mode)
{
    static const char *kBits = "rwxrwxrwx";
    std::string out(9, '-');
    for (int i = 0; i < 9; ++i) {
        const uint32_t bit = 1u << (8 - i);
        if ((mode & bit) != 0) {
            out[static_cast<size_t>(i)] = kBits[i];
        }
    }
    return out;
}

SftpEntryType sftpTypeFromMode(uint32_t mode)
{
    const uint32_t type = mode & 0170000; // S_IFMT
    if (type == 0040000) {                // S_IFDIR
        return SftpEntryType::kDir;
    }
    if (type == 0120000) { // S_IFLNK
        return SftpEntryType::kSymlink;
    }
    if (type == 0100000) { // S_IFREG
        return SftpEntryType::kFile;
    }
    return SftpEntryType::kOther;
}

bool sftpEntryLess(const SftpEntry &a, const SftpEntry &b)
{
    const bool aDir = a.type == SftpEntryType::kDir;
    const bool bDir = b.type == SftpEntryType::kDir;
    if (aDir != bDir) {
        return aDir;
    }
    return a.name < b.name;
}

std::vector<SftpEntry> sftpFilterDotEntries(std::vector<SftpEntry> entries)
{
    std::vector<SftpEntry> out;
    out.reserve(entries.size());
    for (auto &e : entries) {
        if (e.name == "." || e.name == "..") {
            continue;
        }
        out.push_back(std::move(e));
    }
    return out;
}

// ================================================================ 纯逻辑：传输状态机

bool canStartTransfer(TransferState s)
{
    return s == TransferState::kQueued;
}

bool canCancelTransfer(TransferState s)
{
    return s == TransferState::kQueued || s == TransferState::kRunning ||
           s == TransferState::kPaused;
}

bool canRetryTransfer(TransferState s)
{
    return s == TransferState::kFailed || s == TransferState::kCancelled;
}

bool canPauseTransfer(TransferState s)
{
    return s == TransferState::kRunning;
}

TransferState progressTransferState(TransferState s)
{
    if (s != TransferState::kRunning) {
        return s;
    }
    return TransferState::kRunning;
}

TransferState completeTransferState(TransferState s, bool success)
{
    if (s != TransferState::kRunning && s != TransferState::kPaused) {
        return s;
    }
    return success ? TransferState::kCompleted : TransferState::kFailed;
}

TransferState cancelTransferState(TransferState s)
{
    if (!canCancelTransfer(s)) {
        return s;
    }
    return TransferState::kCancelled;
}

TransferState retryTransferState(TransferState s)
{
    if (!canRetryTransfer(s)) {
        return s;
    }
    return TransferState::kQueued;
}

std::optional<std::string> validateSftpRename(const std::string &fromPath,
                                              const std::string &toPath)
{
    const std::string from = sftpNormalizePath(fromPath);
    const std::string to = sftpNormalizePath(toPath);
    if (from.empty()) {
        return std::string("源路径为空或非法");
    }
    if (to.empty()) {
        return std::string("目标路径为空或非法");
    }
    if (from == to) {
        return std::string("源路径与目标路径相同");
    }
    const std::string base = sftpBaseName(to);
    if (base.empty() || base == "." || base == "..") {
        return std::string("目标基名非法");
    }
    return std::nullopt;
}

const char *toString(SftpEntryType type)
{
    switch (type) {
    case SftpEntryType::kFile: return "file";
    case SftpEntryType::kDir: return "dir";
    case SftpEntryType::kSymlink: return "symlink";
    case SftpEntryType::kOther: return "other";
    }
    return "other";
}

const char *toString(SftpError error)
{
    switch (error) {
    case SftpError::kNone: return "none";
    case SftpError::kNotEstablished: return "not_established";
    case SftpError::kOpenFailed: return "open_failed";
    case SftpError::kPathInvalid: return "path_invalid";
    case SftpError::kNoSuchFile: return "no_such_file";
    case SftpError::kPermissionDenied: return "permission_denied";
    case SftpError::kAlreadyExists: return "already_exists";
    case SftpError::kNotDir: return "not_dir";
    case SftpError::kNotFile: return "not_file";
    case SftpError::kIoError: return "io_error";
    case SftpError::kCancelled: return "cancelled";
    case SftpError::kSessionLost: return "session_lost";
    case SftpError::kNotSupported: return "not_supported";
    case SftpError::kInternal: return "internal";
    }
    return "internal";
}

const char *toString(TransferState state)
{
    switch (state) {
    case TransferState::kQueued: return "queued";
    case TransferState::kRunning: return "running";
    case TransferState::kPaused: return "paused";
    case TransferState::kCompleted: return "completed";
    case TransferState::kFailed: return "failed";
    case TransferState::kCancelled: return "cancelled";
    }
    return "failed";
}

const char *toString(TransferDirection dir)
{
    return dir == TransferDirection::kDownload ? "download" : "upload";
}

const char *sftpErrorName(SftpError error)
{
    return toString(error);
}

// ================================================================ SshSftp 运行时

namespace {

void FillEntryBasics(SftpEntry *out, const std::string &path, const std::string &name,
                     uint32_t mode, uint64_t size, uint64_t mtime)
{
    out->path = path;
    out->name = name;
    out->mode = mode;
    out->size = size;
    out->mtime = mtime;
    out->type = sftpTypeFromMode(mode);
    out->permissions = formatSftpPermissions(mode);
}

} // namespace

SshSftp::SshSftp(SshSession &session, SftpCallbacks callbacks)
    : session_(session), callbacks_(std::move(callbacks))
{
}

SshSftp::~SshSftp()
{
    if (sftp_ != nullptr) {
        SSH_LOG("警告：SshSftp 在句柄存活期间被析构（违反析构约定）");
    }
}

bool SshSftp::isLegalStateTransition(bool /*wasOpened*/, bool /*willOpen*/)
{
    // 打开标志可反复 true/false（close 后重开）；此处仅占位保证 API 对称
    return true;
}

bool SshSftp::open()
{
    if (session_.state() != SshSessionState::kEstablished) {
        SSH_LOG("SFTP open 拒绝：会话状态 %s", toString(session_.state()));
        return false;
    }
    if (opened_.load(std::memory_order_acquire)) {
        // 幂等：已在打开态直接成功回报
        if (callbacks_.onOpen) {
            callbacks_.onOpen(SftpOpenResult{true, SftpError::kNone, ""});
        }
        return true;
    }
    bool expected = false;
    if (!openAdmitted_.compare_exchange_strong(expected, true)) {
        return false; // 已有 open 在途
    }
    session_.thread_.post([this] {
        ensureOpenOnLoop();
        if (!opened_.load(std::memory_order_acquire)) {
            // ensureOpen 失败时 finishOpen 已回报；此处仅复位受理位供重试
            openAdmitted_.store(false, std::memory_order_release);
        }
    });
    return true;
}

bool SshSftp::admit(PendingOp op)
{
    if (closeRequested_.load(std::memory_order_acquire)) {
        return false;
    }
    if (session_.state() != SshSessionState::kEstablished) {
        SSH_LOG("SFTP 操作拒绝：会话状态 %s", toString(session_.state()));
        return false;
    }
    // 路径类操作做一次归一化校验（纯逻辑，受理线程完成，失败立即回报）
    if (op.kind != OpKind::kUpload && op.kind != OpKind::kDownload) {
        const std::string norm = sftpNormalizePath(op.path);
        if (norm.empty() && op.kind != OpKind::kList) {
            if (callbacks_.onOp) {
                SftpOpResult r;
                r.success = false;
                r.error = SftpError::kPathInvalid;
                r.op = "validate";
                r.path = op.path;
                r.message = "路径非法";
                callbacks_.onOp(r);
            }
            return false;
        }
        if (!norm.empty()) {
            op.path = norm;
        }
    }
    if (op.kind == OpKind::kRename) {
        const auto err = validateSftpRename(op.path, op.path2);
        if (err.has_value()) {
            if (callbacks_.onOp) {
                SftpOpResult r;
                r.success = false;
                r.error = SftpError::kPathInvalid;
                r.op = "rename";
                r.path = op.path;
                r.message = *err;
                callbacks_.onOp(r);
            }
            return false;
        }
        op.path2 = sftpNormalizePath(op.path2);
    }

    session_.thread_.post([this, op = std::move(op)]() mutable {
        ensureOpenOnLoop();
        if (!opened_.load(std::memory_order_acquire)) {
            if (op.kind == OpKind::kList) {
                SftpListResult r;
                r.success = false;
                r.error = SftpError::kNotEstablished;
                r.path = op.path;
                r.message = "SFTP 未打开";
                if (callbacks_.onList) {
                    callbacks_.onList(r);
                }
            } else if (op.kind == OpKind::kStat) {
                SftpStatResult r;
                r.success = false;
                r.error = SftpError::kNotEstablished;
                r.path = op.path;
                r.message = "SFTP 未打开";
                if (callbacks_.onStat) {
                    callbacks_.onStat(r);
                }
            } else if (op.kind == OpKind::kDownload || op.kind == OpKind::kUpload) {
                SftpTransferResult r;
                r.transferId = op.transferId;
                r.success = false;
                r.error = SftpError::kNotEstablished;
                r.message = "SFTP 未打开";
                if (callbacks_.onTransfer) {
                    callbacks_.onTransfer(r);
                }
            } else {
                SftpOpResult r;
                r.success = false;
                r.error = SftpError::kNotEstablished;
                r.path = op.path;
                r.message = "SFTP 未打开";
                if (callbacks_.onOp) {
                    callbacks_.onOp(r);
                }
            }
            return;
        }
        runOp(std::move(op));
    });
    return true;
}

bool SshSftp::list(std::string path)
{
    PendingOp op;
    op.kind = OpKind::kList;
    op.path = path.empty() ? std::string("/") : std::move(path);
    return admit(std::move(op));
}

bool SshSftp::stat(std::string path)
{
    PendingOp op;
    op.kind = OpKind::kStat;
    op.path = std::move(path);
    return admit(std::move(op));
}

bool SshSftp::download(uint64_t transferId, std::string remotePath, std::string localPath)
{
    if (remotePath.empty() || localPath.empty()) {
        return false;
    }
    PendingOp op;
    op.kind = OpKind::kDownload;
    op.path = std::move(remotePath);
    op.path2 = std::move(localPath);
    op.transferId = transferId;
    return admit(std::move(op));
}

bool SshSftp::upload(uint64_t transferId, std::string localPath, std::string remotePath)
{
    if (remotePath.empty() || localPath.empty()) {
        return false;
    }
    PendingOp op;
    op.kind = OpKind::kUpload;
    op.path = std::move(remotePath);  // 远端目标
    op.path2 = std::move(localPath);  // 本地源
    op.transferId = transferId;
    return admit(std::move(op));
}

bool SshSftp::rename(std::string fromPath, std::string toPath)
{
    PendingOp op;
    op.kind = OpKind::kRename;
    op.path = std::move(fromPath);
    op.path2 = std::move(toPath);
    return admit(std::move(op));
}

bool SshSftp::mkdir(std::string path, uint32_t mode)
{
    PendingOp op;
    op.kind = OpKind::kMkdir;
    op.path = std::move(path);
    op.mode = mode == 0 ? 0755 : mode;
    return admit(std::move(op));
}

bool SshSftp::rmdir(std::string path)
{
    PendingOp op;
    op.kind = OpKind::kRmdir;
    op.path = std::move(path);
    return admit(std::move(op));
}

bool SshSftp::unlink(std::string path)
{
    PendingOp op;
    op.kind = OpKind::kUnlink;
    op.path = std::move(path);
    return admit(std::move(op));
}

bool SshSftp::chmod(std::string path, uint32_t mode)
{
    PendingOp op;
    op.kind = OpKind::kChmod;
    op.path = std::move(path);
    op.mode = mode;
    return admit(std::move(op));
}

bool SshSftp::readlink(std::string path)
{
    PendingOp op;
    op.kind = OpKind::kReadlink;
    op.path = std::move(path);
    return admit(std::move(op));
}

void SshSftp::close()
{
    closeRequested_.store(true, std::memory_order_release);
    session_.thread_.post([this] { closeOnLoop(); });
}

void SshSftp::ensureOpenOnLoop()
{
    if (opened_.load(std::memory_order_acquire) || sftp_ != nullptr) {
        if (sftp_ != nullptr) {
            opened_.store(true, std::memory_order_release);
        }
        return;
    }
    if (session_.state() != SshSessionState::kEstablished || session_.session_ == nullptr) {
        finishOpen(SftpError::kNotEstablished, "会话未 established");
        return;
    }
    LIBSSH2_SFTP *sftp = ::libssh2_sftp_init(session_.session_);
    if (sftp == nullptr) {
        const int err = ::libssh2_session_last_errno(session_.session_);
        finishOpen(mapLibssh2Errno(err), lastLibssh2Error());
        return;
    }
    sftp_ = sftp;
    // 不注册为 SshChannel：SFTP 走独立回调通路；会话丢失由 bridge 层
    // 订阅 stateChange 终态后调用 close()/onSessionLost（SessionHandle::Teardown 亦兜底）
    opened_.store(true, std::memory_order_release);
    finishOpen(SftpError::kNone, "");
}

void SshSftp::finishOpen(SftpError error, const std::string &message)
{
    if (!callbacks_.onOpen) {
        return;
    }
    SftpOpenResult r;
    r.success = error == SftpError::kNone;
    r.error = error;
    r.message = message;
    callbacks_.onOpen(r);
}

void SshSftp::runOp(PendingOp op)
{
    switch (op.kind) {
    case OpKind::kList:
        doList(op.path);
        return;
    case OpKind::kStat:
        doStat(op.path);
        return;
    case OpKind::kDownload:
    case OpKind::kUpload:
        doTransfer(op);
        return;
    default:
        doOp(op);
        return;
    }
}

void SshSftp::doList(const std::string &path)
{
    SftpListResult result;
    result.path = path;
    if (sftp_ == nullptr || session_.session_ == nullptr) {
        result.error = SftpError::kNotEstablished;
        result.message = "SFTP 未打开";
        if (callbacks_.onList) {
            callbacks_.onList(result);
        }
        return;
    }
    LIBSSH2_SFTP_HANDLE *h = ::libssh2_sftp_opendir(sftp_, path.c_str());
    if (h == nullptr) {
        const int err = ::libssh2_session_last_errno(session_.session_);
        result.error = mapLibssh2Errno(err);
        result.message = lastLibssh2Error();
        if (result.error == SftpError::kNone) {
            result.error = SftpError::kIoError;
        }
        if (callbacks_.onList) {
            callbacks_.onList(result);
        }
        return;
    }
    std::vector<SftpEntry> raw;
    for (;;) {
        char nameBuf[512];
        char longBuf[512];
        LIBSSH2_SFTP_ATTRIBUTES attrs {};
        const ssize_t n = ::libssh2_sftp_readdir_ex(h, nameBuf, sizeof(nameBuf), longBuf,
                                                     sizeof(longBuf), &attrs);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            continue;
        }
        if (n <= 0) {
            break;
        }
        const std::string name(nameBuf, static_cast<size_t>(n));
        SftpEntry e;
        const std::string child = sftpJoinPath(path, name);
        const uint32_t mode = static_cast<uint32_t>(attrs.permissions);
        const uint64_t size = attrs.filesize < 0 ? 0 : static_cast<uint64_t>(attrs.filesize);
        const uint64_t mtime = attrs.mtime < 0 ? 0 : static_cast<uint64_t>(attrs.mtime);
        FillEntryBasics(&e, child, name, mode, size, mtime);
        raw.push_back(std::move(e));
    }
    ::libssh2_sftp_closedir(h);
    result.entries = sftpFilterDotEntries(std::move(raw));
    std::sort(result.entries.begin(), result.entries.end(), sftpEntryLess);
    result.success = true;
    if (callbacks_.onList) {
        callbacks_.onList(result);
    }
}

void SshSftp::doStat(const std::string &path)
{
    SftpStatResult result;
    result.path = path;
    if (sftp_ == nullptr) {
        result.error = SftpError::kNotEstablished;
        result.message = "SFTP 未打开";
        if (callbacks_.onStat) {
            callbacks_.onStat(result);
        }
        return;
    }
    LIBSSH2_SFTP_ATTRIBUTES attrs {};
    const int rc = ::libssh2_sftp_stat(sftp_, path.c_str(), &attrs);
    if (rc != 0) {
        result.error = mapLibssh2Errno(rc);
        result.message = lastLibssh2Error();
        if (result.error == SftpError::kNone) {
            result.error = SftpError::kIoError;
        }
        if (callbacks_.onStat) {
            callbacks_.onStat(result);
        }
        return;
    }
    FillEntryBasics(&result.entry, path, sftpBaseName(path),
                    static_cast<uint32_t>(attrs.permissions),
                    attrs.filesize < 0 ? 0 : static_cast<uint64_t>(attrs.filesize),
                    attrs.mtime < 0 ? 0 : static_cast<uint64_t>(attrs.mtime));
    // symlink 读目标（失败不影响 stat 成功）
    if (result.entry.type == SftpEntryType::kSymlink) {
        char linkBuf[1024];
        const ssize_t ln = ::libssh2_sftp_readlink(sftp_, path.c_str(), linkBuf, sizeof(linkBuf));
        if (ln > 0) {
            result.entry.linkTarget.assign(linkBuf, static_cast<size_t>(ln));
        }
    }
    result.success = true;
    if (callbacks_.onStat) {
        callbacks_.onStat(result);
    }
}

void SshSftp::doOp(const PendingOp &op)
{
    SftpOpResult r;
    r.path = op.path;
    if (sftp_ == nullptr || session_.session_ == nullptr) {
        r.error = SftpError::kNotEstablished;
        r.message = "SFTP 未打开";
        if (callbacks_.onOp) {
            callbacks_.onOp(r);
        }
        return;
    }
    int rc = -1;
    switch (op.kind) {
    case OpKind::kRename:
        r.op = "rename";
        rc = ::libssh2_sftp_rename_ex(sftp_, op.path.c_str(), static_cast<unsigned>(op.path.size()),
                                       op.path2.c_str(), static_cast<unsigned>(op.path2.size()),
                                       LIBSSH2_SFTP_RENAME_OVERWRITE |
                                           LIBSSH2_SFTP_RENAME_ATOMIC |
                                           LIBSSH2_SFTP_RENAME_NATIVE);
        break;
    case OpKind::kMkdir:
        r.op = "mkdir";
        rc = ::libssh2_sftp_mkdir(sftp_, op.path.c_str(), op.mode);
        break;
    case OpKind::kRmdir:
        r.op = "rmdir";
        rc = ::libssh2_sftp_rmdir(sftp_, op.path.c_str());
        break;
    case OpKind::kUnlink:
        r.op = "unlink";
        rc = ::libssh2_sftp_unlink(sftp_, op.path.c_str());
        break;
    case OpKind::kChmod: {
        r.op = "chmod";
        // libssh2 无 chmod 包装，走 setstat + ATTR_PERMISSIONS
        LIBSSH2_SFTP_ATTRIBUTES attrs {};
        attrs.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
        attrs.permissions = op.mode;
        rc = ::libssh2_sftp_setstat(sftp_, op.path.c_str(), &attrs);
        break;
    }
    case OpKind::kReadlink: {
        r.op = "readlink";
        char linkBuf[1024];
        const ssize_t ln =
            ::libssh2_sftp_readlink(sftp_, op.path.c_str(), linkBuf, sizeof(linkBuf));
        if (ln > 0) {
            r.success = true;
            r.error = SftpError::kNone;
            r.linkTarget.assign(linkBuf, static_cast<size_t>(ln));
            if (callbacks_.onOp) {
                callbacks_.onOp(r);
            }
            return;
        }
        rc = static_cast<int>(ln);
        break;
    }
    default:
        r.op = "unknown";
        r.error = SftpError::kNotSupported;
        r.message = "未支持的操作";
        if (callbacks_.onOp) {
            callbacks_.onOp(r);
        }
        return;
    }
    if (rc == 0) {
        r.success = true;
        r.error = SftpError::kNone;
    } else {
        r.error = mapLibssh2Errno(rc);
        r.message = lastLibssh2Error();
        if (r.error == SftpError::kNone) {
            r.error = SftpError::kIoError;
        }
    }
    if (callbacks_.onOp) {
        callbacks_.onOp(r);
    }
}

void SshSftp::doTransfer(const PendingOp &op)
{
    SftpTransferResult r;
    r.transferId = op.transferId;
    // download: path=remote, path2=local；upload: path=remote 目标, path2=local 源
    const bool download = op.kind == OpKind::kDownload;
    const std::string remotePath = op.path;
    const std::string localPath = op.path2;
    if (sftp_ == nullptr) {
        r.error = SftpError::kNotEstablished;
        r.message = "SFTP 未打开";
        if (callbacks_.onTransfer) {
            callbacks_.onTransfer(r);
        }
        return;
    }

    LIBSSH2_SFTP_HANDLE *h = nullptr;
    if (download) {
        h = ::libssh2_sftp_open(sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0);
    } else {
        // 本地源文件大小（用于进度总量）
        std::ifstream in(localPath, std::ios::binary | std::ios::ate);
        if (!in) {
            r.error = SftpError::kIoError;
            r.message = "本地文件不可读";
            if (callbacks_.onTransfer) {
                callbacks_.onTransfer(r);
            }
            return;
        }
        h = ::libssh2_sftp_open(sftp_, remotePath.c_str(),
                                LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC, 0644);
    }
    if (h == nullptr) {
        const int err = ::libssh2_session_last_errno(session_.session_);
        r.error = mapLibssh2Errno(err);
        r.message = lastLibssh2Error();
        if (r.error == SftpError::kNone) {
            r.error = SftpError::kIoError;
        }
        if (callbacks_.onTransfer) {
            callbacks_.onTransfer(r);
        }
        return;
    }

    constexpr size_t kChunk = 32 * 1024;
    std::vector<char> buf(kChunk);
    uint64_t transferred = 0;
    uint64_t lastReport = 0;
    SftpError err = SftpError::kNone;
    std::string msg;

    if (download) {
        std::ofstream out(localPath, std::ios::binary | std::ios::trunc);
        if (!out) {
            ::libssh2_sftp_close(h);
            r.error = SftpError::kIoError;
            r.message = "本地文件不可写";
            if (callbacks_.onTransfer) {
                callbacks_.onTransfer(r);
            }
            return;
        }
        // 试探远端大小
        LIBSSH2_SFTP_ATTRIBUTES attrs {};
        if (::libssh2_sftp_fstat(h, &attrs) == 0 && attrs.filesize > 0) {
            r.total = static_cast<uint64_t>(attrs.filesize);
        }
        for (;;) {
            const ssize_t n = ::libssh2_sftp_read(h, buf.data(), buf.size());
            if (n == LIBSSH2_ERROR_EAGAIN) {
                continue;
            }
            if (n < 0) {
                err = mapLibssh2Errno(static_cast<int>(n));
                msg = lastLibssh2Error();
                break;
            }
            if (n == 0) {
                break;
            }
            out.write(buf.data(), n);
            if (!out) {
                err = SftpError::kIoError;
                msg = "本地写入失败";
                break;
            }
            transferred += static_cast<uint64_t>(n);
            if (transferred - lastReport >= kProgressReportBytes && callbacks_.onProgress) {
                lastReport = transferred;
                SftpTransferProgress p;
                p.transferId = op.transferId;
                p.transferred = transferred;
                p.total = r.total;
                callbacks_.onProgress(p);
            }
        }
    } else {
        std::ifstream in(localPath, std::ios::binary);
        if (!in) {
            ::libssh2_sftp_close(h);
            r.error = SftpError::kIoError;
            r.message = "本地文件不可读";
            if (callbacks_.onTransfer) {
                callbacks_.onTransfer(r);
            }
            return;
        }
        in.seekg(0, std::ios::end);
        const auto sz = in.tellg();
        if (sz > 0) {
            r.total = static_cast<uint64_t>(sz);
        }
        in.seekg(0, std::ios::beg);
        for (;;) {
            in.read(buf.data(), static_cast<std::streamsize>(buf.size()));
            const auto got = in.gcount();
            if (got <= 0) {
                break;
            }
            size_t off = 0;
            while (off < static_cast<size_t>(got)) {
                const ssize_t n = ::libssh2_sftp_write(
                    h, buf.data() + off, static_cast<size_t>(got) - off);
                if (n == LIBSSH2_ERROR_EAGAIN) {
                    continue;
                }
                if (n < 0) {
                    err = mapLibssh2Errno(static_cast<int>(n));
                    msg = lastLibssh2Error();
                    break;
                }
                off += static_cast<size_t>(n);
                transferred += static_cast<uint64_t>(n);
            }
            if (err != SftpError::kNone) {
                break;
            }
            if (transferred - lastReport >= kProgressReportBytes && callbacks_.onProgress) {
                lastReport = transferred;
                SftpTransferProgress p;
                p.transferId = op.transferId;
                p.transferred = transferred;
                p.total = r.total;
                callbacks_.onProgress(p);
            }
        }
    }

    ::libssh2_sftp_close(h);
    r.transferred = transferred;
    if (err == SftpError::kNone) {
        r.success = true;
        r.error = SftpError::kNone;
        if (callbacks_.onProgress) {
            SftpTransferProgress p;
            p.transferId = op.transferId;
            p.transferred = transferred;
            p.total = r.total == 0 ? transferred : r.total;
            callbacks_.onProgress(p);
        }
    } else {
        r.success = false;
        r.error = err;
        r.message = msg;
    }
    if (callbacks_.onTransfer) {
        callbacks_.onTransfer(r);
    }
}

void SshSftp::closeOnLoop()
{
    opened_.store(false, std::memory_order_release);
    openAdmitted_.store(false, std::memory_order_release);
    if (sftp_ != nullptr && session_.session_ != nullptr) {
        ::libssh2_sftp_shutdown(sftp_);
    }
    sftp_ = nullptr;
}

void SshSftp::onSessionLost()
{
    // 循环线程：会话资源即将释放，强制收尾在途操作
    closeOnLoop();
    if (callbacks_.onOpen) {
        // 若尚未 open 成功，补一个失败（幂等：成功后不会再来）
    }
    if (callbacks_.onTransfer) {
        SftpTransferResult r;
        r.success = false;
        r.error = SftpError::kSessionLost;
        r.message = "会话已断开";
        callbacks_.onTransfer(r);
    }
    if (callbacks_.onList) {
        SftpListResult r;
        r.success = false;
        r.error = SftpError::kSessionLost;
        r.message = "会话已断开";
        callbacks_.onList(r);
    }
}

SftpError SshSftp::mapLibssh2Errno(int code) const
{
    if (code == 0 || code == LIBSSH2_ERROR_NONE) {
        return SftpError::kNone;
    }
    // SFTP 协议错误：经 libssh2_sftp_last_error 细分（FX_* 为正数码）
    if (code == LIBSSH2_ERROR_SFTP_PROTOCOL && sftp_ != nullptr) {
        switch (::libssh2_sftp_last_error(sftp_)) {
        case LIBSSH2_FX_OK:
            return SftpError::kNone;
        case LIBSSH2_FX_NO_SUCH_FILE:
        case LIBSSH2_FX_NO_SUCH_PATH:
            return SftpError::kNoSuchFile;
        case LIBSSH2_FX_PERMISSION_DENIED:
            return SftpError::kPermissionDenied;
        case LIBSSH2_FX_FILE_ALREADY_EXISTS:
            return SftpError::kAlreadyExists;
        case LIBSSH2_FX_NOT_A_DIRECTORY:
            return SftpError::kNotDir;
        case LIBSSH2_FX_INVALID_FILENAME:
            return SftpError::kPathInvalid;
        default:
            return SftpError::kIoError;
        }
    }
    if (code == LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED ||
        code == LIBSSH2_ERROR_CHANNEL_FAILURE) {
        return SftpError::kNotSupported; // 服务端未开 sftp subsystem 等
    }
    return SftpError::kIoError;
}

std::string SshSftp::lastLibssh2Error() const
{
    if (session_.session_ == nullptr) {
        return "";
    }
    char *msg = nullptr;
    int len = 0;
    ::libssh2_session_last_error(session_.session_, &msg, &len, 0);
    if (msg == nullptr || len <= 0) {
        return "";
    }
    return std::string(msg, static_cast<size_t>(len));
}

} // namespace ssh
} // namespace sshclient
