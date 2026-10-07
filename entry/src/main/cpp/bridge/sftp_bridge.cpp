/**
 * SFTP NAPI 桥接实现 —— 任务 N14。契约见 sftp_bridge.h 与 index.d.ts。
 */
#include "sftp_bridge.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"
#include "hilog/log.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

#include "../ssh/sftp.h"
#include "../ssh/session.h"
#include "internal.h"

namespace sshclient {
namespace bridge {

// ---------------------------------------------------------------- SftpHandle

struct SftpHandle {
    napi_env env = nullptr;
    uint64_t handle = 0;
    uint64_t sessionHandleId = 0;
    std::shared_ptr<SessionHandle> session;
    std::shared_ptr<ssh::SshSftp> sftp; // null = 已关闭
    std::atomic<bool> closing{false};
};

namespace {

HandleTable<SftpHandle> g_sftpTable;

std::shared_ptr<SftpHandle> LookupSftp(uint64_t handle)
{
    return g_sftpTable.lookup(handle);
}

std::string EscapeJson(const std::string &s)
{
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                char buf[8];
                std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            } else {
                out += c;
            }
        }
    }
    return out;
}

std::string EntryToJson(const ssh::SftpEntry &e)
{
    std::string j = "{\"name\":\"" + EscapeJson(e.name) + "\"";
    j += ",\"path\":\"" + EscapeJson(e.path) + "\"";
    j += ",\"type\":\"" + std::string(ssh::toString(e.type)) + "\"";
    j += ",\"size\":" + std::to_string(e.size);
    j += ",\"mtime\":" + std::to_string(e.mtime);
    j += ",\"mode\":" + std::to_string(e.mode);
    j += ",\"permissions\":\"" + EscapeJson(e.permissions) + "\"";
    j += ",\"linkTarget\":\"" + EscapeJson(e.linkTarget) + "\"}";
    return j;
}

std::string EntriesToJson(const std::vector<ssh::SftpEntry> &entries)
{
    std::string j = "[";
    for (size_t i = 0; i < entries.size(); ++i) {
        if (i > 0) {
            j += ",";
        }
        j += EntryToJson(entries[i]);
    }
    j += "]";
    return j;
}

void SendSftpEvent(SessionHandle *sh, BridgeEvent *evt)
{
    SendStateEvent(sh, evt);
}

ssh::SftpCallbacks MakeSftpCallbacks(std::weak_ptr<SftpHandle> weak)
{
    ssh::SftpCallbacks cb;
    cb.onOpen = [weak](const ssh::SftpOpenResult &r) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kSftpOpen;
        evt->sftp = th->handle;
        evt->success = r.success;
        evt->text1 = ssh::sftpErrorName(r.error);
        evt->text2 = r.message;
        SendSftpEvent(th->session.get(), evt);
    };
    cb.onList = [weak](const ssh::SftpListResult &r) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kSftpList;
        evt->sftp = th->handle;
        evt->success = r.success;
        evt->text1 = r.path;
        evt->text2 = EntriesToJson(r.entries);
        evt->text3 = ssh::sftpErrorName(r.error);
        evt->text4 = r.message;
        SendSftpEvent(th->session.get(), evt);
    };
    cb.onStat = [weak](const ssh::SftpStatResult &r) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kSftpStat;
        evt->sftp = th->handle;
        evt->success = r.success;
        evt->text1 = r.path;
        evt->text2 = r.success ? EntryToJson(r.entry) : "";
        evt->text3 = ssh::sftpErrorName(r.error);
        evt->text4 = r.message;
        SendSftpEvent(th->session.get(), evt);
    };
    cb.onOp = [weak](const ssh::SftpOpResult &r) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kSftpOpDone;
        evt->sftp = th->handle;
        evt->success = r.success;
        evt->text1 = r.op;
        evt->text2 = r.path;
        evt->text3 = ssh::sftpErrorName(r.error);
        evt->text4 = r.message;
        evt->bytes = r.linkTarget;
        SendSftpEvent(th->session.get(), evt);
    };
    cb.onProgress = [weak](const ssh::SftpTransferProgress &p) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kSftpProgress;
        evt->sftp = th->handle;
        evt->transferId = p.transferId;
        evt->number = static_cast<long>(p.transferred);
        evt->text1 = std::to_string(p.total);
        SendSftpEvent(th->session.get(), evt);
    };
    cb.onTransfer = [weak](const ssh::SftpTransferResult &r) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kSftpTransferDone;
        evt->sftp = th->handle;
        evt->transferId = r.transferId;
        evt->success = r.success;
        evt->text1 = ssh::sftpErrorName(r.error);
        evt->text2 = r.message;
        evt->number = static_cast<long>(r.transferred);
        evt->text3 = std::to_string(r.total);
        SendSftpEvent(th->session.get(), evt);
    };
    return cb;
}

// ---------------------------------------------------------------- NAPI 方法

napi_value SftpOpen(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t sessionHandle = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], sessionHandle)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(sessionHandle);
    if (!sh || !sh->session) {
        return MakeBool(env, false);
    }
    if (sh->session->state() != ssh::SshSessionState::kEstablished) {
        return MakeBool(env, false);
    }

    auto th = std::make_shared<SftpHandle>();
    th->env = env;
    th->sessionHandleId = sessionHandle;
    th->session = sh;
    th->sftp = std::make_shared<ssh::SshSftp>(*sh->session, MakeSftpCallbacks(th));
    const uint64_t id = g_sftpTable.insert(th);
    if (id == 0) {
        return MakeBool(env, false);
    }
    th->handle = id;
    {
        std::lock_guard<std::mutex> lock(sh->sftpMutex);
        sh->sfpts.emplace(id, th);
    }
    const bool ok = th->sftp->open();
    if (!ok) {
        g_sftpTable.erase(id);
        std::lock_guard<std::mutex> lock(sh->sftpMutex);
        sh->sfpts.erase(id);
        return MakeBool(env, false);
    }
    return MakeHandleValue(env, id);
}

std::shared_ptr<SftpHandle> RequireSftp(uint64_t id)
{
    auto th = LookupSftp(id);
    if (!th || th->closing.load() || !th->sftp || !th->session) {
        return nullptr;
    }
    return th;
}

napi_value SftpClose(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], id)) {
        return MakeBool(env, false);
    }
    auto th = g_sftpTable.erase(id);
    if (!th) {
        return MakeBool(env, true); // 幂等
    }
    th->closing.store(true);
    if (th->sftp) {
        th->sftp->close();
    }
    if (th->session) {
        std::lock_guard<std::mutex> lock(th->session->sftpMutex);
        th->session->sfpts.erase(id);
    }
    return MakeBool(env, true);
}

napi_value SftpList(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->list(std::move(path)));
}

napi_value SftpStat(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->stat(std::move(path)));
}

napi_value SftpDownload(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    uint64_t transferId = 0;
    std::string remote;
    std::string local;
    if (argc < 4 || !GetHandleArg(env, argv[0], id) ||
        !GetHandleArg(env, argv[1], transferId) || !GetStringArg(env, argv[2], remote) ||
        !GetStringArg(env, argv[3], local)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->download(transferId, std::move(remote), std::move(local)));
}

napi_value SftpUpload(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    uint64_t transferId = 0;
    std::string local;
    std::string remote;
    if (argc < 4 || !GetHandleArg(env, argv[0], id) ||
        !GetHandleArg(env, argv[1], transferId) || !GetStringArg(env, argv[2], local) ||
        !GetStringArg(env, argv[3], remote)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->upload(transferId, std::move(local), std::move(remote)));
}

napi_value SftpRename(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string from;
    std::string to;
    if (argc < 3 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], from) ||
        !GetStringArg(env, argv[2], to)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->rename(std::move(from), std::move(to)));
}

napi_value SftpMkdir(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    uint32_t mode = 0755;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path)) {
        return MakeBool(env, false);
    }
    if (argc >= 3) {
        uint32_t m = 0;
        if (GetUint32Arg(env, argv[2], m) && m != 0) {
            mode = m;
        }
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->mkdir(std::move(path), mode));
}

napi_value SftpRmdir(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->rmdir(std::move(path)));
}

napi_value SftpUnlink(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->unlink(std::move(path)));
}

napi_value SftpChmod(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    uint32_t mode = 0;
    if (argc < 3 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path) ||
        !GetUint32Arg(env, argv[2], mode)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->chmod(std::move(path), mode));
}

napi_value SftpReadlink(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string path;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetStringArg(env, argv[1], path)) {
        return MakeBool(env, false);
    }
    auto th = RequireSftp(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->sftp->readlink(std::move(path)));
}

} // namespace

void ForgetSftp(uint64_t sftpHandle)
{
    auto th = g_sftpTable.erase(sftpHandle);
    if (!th) {
        return;
    }
    th->closing.store(true);
    if (th->sftp) {
        th->sftp->close();
    }
}

void RegisterSftpBridge(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"sftpOpen", nullptr, SftpOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpClose", nullptr, SftpClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpList", nullptr, SftpList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpStat", nullptr, SftpStat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpDownload", nullptr, SftpDownload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpUpload", nullptr, SftpUpload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpRename", nullptr, SftpRename, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpMkdir", nullptr, SftpMkdir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpRmdir", nullptr, SftpRmdir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpUnlink", nullptr, SftpUnlink, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpChmod", nullptr, SftpChmod, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sftpReadlink", nullptr, SftpReadlink, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterSftpBridge: napi_define_properties failed");
    }
}

} // namespace bridge
} // namespace sshclient
