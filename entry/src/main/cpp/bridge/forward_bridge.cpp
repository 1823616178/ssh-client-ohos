/**
 * 端口转发 NAPI 桥接实现 —— 任务 N15/N16。契约见 forward_bridge.h 与 index.d.ts。
 */
#include "forward_bridge.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"
#include "hilog/log.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

#include "../ssh/forward.h"
#include "../ssh/session.h"
#include "internal.h"

namespace sshclient {
namespace bridge {

struct ForwardHandle {
    napi_env env = nullptr;
    uint64_t handle = 0;
    uint64_t sessionHandleId = 0;
    std::shared_ptr<SessionHandle> session;
    /** data 通道（direct-tcpip / remote accept）；remote 监听时为 null */
    std::shared_ptr<ssh::SshForwardChannel> data;
    /** remote -R 监听器；data 通道时为 null */
    std::shared_ptr<ssh::SshRemoteForward> remote;
    uint64_t listenHandle = 0; // accept 出的数据通道所归属的监听句柄
    std::atomic<bool> closing{false};
};

namespace {

HandleTable<ForwardHandle> g_fwdTable;

std::shared_ptr<ForwardHandle> LookupFwd(uint64_t handle)
{
    return g_fwdTable.lookup(handle);
}

void SendFwdState(SessionHandle *sh, BridgeEvent *evt)
{
    SendStateEvent(sh, evt);
}

void SendFwdData(SessionHandle *sh, BridgeEvent *evt)
{
    TsfnBridge *d = sh->dataBridge;
    if (!EnqueueEvent(d, evt)) {
        // 丢弃：限量队列满，与 channelData 同一背压策略
    }
}

// 数据通道 callbacks：onOpen/onData/onClose → 事件
ssh::ForwardCallbacks MakeDataCallbacks(std::weak_ptr<ForwardHandle> weak)
{
    ssh::ForwardCallbacks cb;
    cb.onOpen = [weak](const ssh::ForwardOpenResult &r) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kForwardOpen;
        evt->forward = th->handle;
        evt->success = r.success;
        evt->text1 = ssh::forwardErrorName(r.error);
        evt->text2 = r.message;
        SendFwdState(th->session.get(), evt);
    };
    cb.onData = [weak](const std::string &data) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kForwardData;
        evt->forward = th->handle;
        evt->bytes = data;
        SendFwdData(th->session.get(), evt);
    };
    cb.onClose = [weak](const ssh::ForwardCloseInfo &info) {
        auto th = weak.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kForwardClose;
        evt->forward = th->handle;
        evt->text1 = info.reason;
        evt->text2 = info.message;
        SendFwdState(th->session.get(), evt);
        // 延后摘表：回调内不得析构（同 ScheduleChannelErase 纪律）
        SessionHandle *sh = th->session.get();
        const uint64_t id = th->handle;
        sh->thread.post([sh, id]() {
            g_fwdTable.erase(id);
            std::lock_guard<std::mutex> lock(sh->forwardsMutex);
            sh->forwards.erase(id);
        });
    };
    return cb;
}

// 远程监听 callbacks
ssh::ForwardCallbacks MakeRemoteCallbacks(std::weak_ptr<ForwardHandle> weakListen)
{
    ssh::ForwardCallbacks cb;
    cb.onOpen = [weakListen](const ssh::ForwardOpenResult &r) {
        auto th = weakListen.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kForwardListen;
        evt->forward = th->handle;
        evt->success = r.success;
        evt->number = static_cast<long>(r.boundPort);
        evt->text1 = ssh::forwardErrorName(r.error);
        evt->text2 = r.message;
        SendFwdState(th->session.get(), evt);
    };
    cb.onClose = [weakListen](const ssh::ForwardCloseInfo &info) {
        auto th = weakListen.lock();
        if (!th || !th->session) {
            return;
        }
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kForwardClose;
        evt->forward = th->handle;
        evt->text1 = info.reason;
        evt->text2 = info.message;
        SendFwdState(th->session.get(), evt);
        SessionHandle *sh = th->session.get();
        const uint64_t id = th->handle;
        sh->thread.post([sh, id]() {
            g_fwdTable.erase(id);
            std::lock_guard<std::mutex> lock(sh->forwardsMutex);
            sh->forwards.erase(id);
        });
    };
    cb.onAccepted = [weakListen](struct _LIBSSH2_CHANNEL *raw, const ssh::ForwardOpenResult &meta) {
        auto listenTh = weakListen.lock();
        if (!listenTh || !listenTh->session || raw == nullptr) {
            return;
        }
        SessionHandle *sh = listenTh->session.get();
        auto dataTh = std::make_shared<ForwardHandle>();
        dataTh->env = listenTh->env;
        dataTh->sessionHandleId = listenTh->sessionHandleId;
        dataTh->session = listenTh->session;
        dataTh->listenHandle = listenTh->handle;
        dataTh->data = std::make_shared<ssh::SshForwardChannel>(*sh->session,
                                                                 MakeDataCallbacks(dataTh));
        const uint64_t id = g_fwdTable.insert(dataTh);
        if (id == 0) {
            return;
        }
        dataTh->handle = id;
        {
            std::lock_guard<std::mutex> lock(sh->forwardsMutex);
            sh->forwards.emplace(id, dataTh);
        }
        dataTh->data->adoptAccepted(raw, meta);
        auto *evt = new BridgeEvent();
        evt->kind = EventKind::kForwardAccept;
        evt->forward = id;
        evt->transferId = listenTh->handle;
        evt->success = true;
        evt->text1 = meta.origin;
        SendFwdState(sh, evt);
    };
    return cb;
}

// ---------------------------------------------------------------- NAPI 方法

napi_value OpenDirectTcpip(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t sessionHandle = 0;
    std::string host;
    uint32_t port = 0;
    if (argc < 3 || !GetHandleArg(env, argv[0], sessionHandle) ||
        !GetStringArg(env, argv[1], host) || !GetUint32Arg(env, argv[2], port)) {
        return MakeHandleValue(env, 0);
    }
    auto sh = LookupLive(sessionHandle);
    if (!sh || !sh->session || sh->session->state() != ssh::SshSessionState::kEstablished) {
        return MakeHandleValue(env, 0);
    }
    if (!ssh::isValidForwardTarget({host, port})) {
        return MakeHandleValue(env, 0);
    }
    auto th = std::make_shared<ForwardHandle>();
    th->env = env;
    th->sessionHandleId = sessionHandle;
    th->session = sh;
    th->data = std::make_shared<ssh::SshForwardChannel>(*sh->session, MakeDataCallbacks(th));
    const uint64_t id = g_fwdTable.insert(th);
    if (id == 0) {
        return MakeHandleValue(env, 0);
    }
    th->handle = id;
    {
        std::lock_guard<std::mutex> lock(sh->forwardsMutex);
        sh->forwards.emplace(id, th);
    }
    const bool ok = th->data->openDirectTcpip(std::move(host), port);
    if (!ok) {
        g_fwdTable.erase(id);
        std::lock_guard<std::mutex> lock(sh->forwardsMutex);
        sh->forwards.erase(id);
        return MakeHandleValue(env, 0);
    }
    return MakeHandleValue(env, id);
}

std::shared_ptr<ForwardHandle> RequireDataFwd(uint64_t id)
{
    auto th = LookupFwd(id);
    if (!th || th->closing.load() || !th->data || !th->session) {
        return nullptr;
    }
    return th;
}

napi_value ForwardWrite(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    std::string bytes;
    if (argc < 2 || !GetHandleArg(env, argv[0], id) || !GetBytesArg(env, argv[1], bytes)) {
        return MakeBool(env, false);
    }
    auto th = RequireDataFwd(id);
    if (!th) {
        return MakeBool(env, false);
    }
    return MakeBool(env, th->data->write(bytes.data(), bytes.size()));
}

napi_value ForwardClose(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t id = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], id)) {
        return MakeBool(env, false);
    }
    auto th = g_fwdTable.erase(id);
    if (!th) {
        return MakeBool(env, true); // 幂等
    }
    th->closing.store(true);
    if (th->data) {
        th->data->close();
    }
    if (th->remote) {
        th->remote->cancel();
    }
    if (th->session) {
        std::lock_guard<std::mutex> lock(th->session->forwardsMutex);
        th->session->forwards.erase(id);
    }
    return MakeBool(env, true);
}

napi_value RemoteForwardListen(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t sessionHandle = 0;
    std::string bindAddress;
    uint32_t port = 0;
    if (argc < 3 || !GetHandleArg(env, argv[0], sessionHandle) ||
        !GetStringArg(env, argv[1], bindAddress) || !GetUint32Arg(env, argv[2], port) ||
        port == 0) {
        return MakeHandleValue(env, 0);
    }
    auto sh = LookupLive(sessionHandle);
    if (!sh || !sh->session || sh->session->state() != ssh::SshSessionState::kEstablished) {
        return MakeHandleValue(env, 0);
    }
    auto th = std::make_shared<ForwardHandle>();
    th->env = env;
    th->sessionHandleId = sessionHandle;
    th->session = sh;
    th->remote = std::make_shared<ssh::SshRemoteForward>(*sh->session,
                                                         MakeRemoteCallbacks(th));
    const uint64_t id = g_fwdTable.insert(th);
    if (id == 0) {
        return MakeHandleValue(env, 0);
    }
    th->handle = id;
    {
        std::lock_guard<std::mutex> lock(sh->forwardsMutex);
        sh->forwards.emplace(id, th);
    }
    const bool ok = th->remote->openRemote(std::move(bindAddress), port);
    if (!ok) {
        g_fwdTable.erase(id);
        std::lock_guard<std::mutex> lock(sh->forwardsMutex);
        sh->forwards.erase(id);
        return MakeHandleValue(env, 0);
    }
    return MakeHandleValue(env, id);
}

napi_value RemoteForwardCancel(napi_env env, napi_callback_info info)
{
    return ForwardClose(env, info); // 同一摘表 + cancel/close 路径
}

napi_value ForwardProxyJumpNotes(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    const std::string notes = ssh::proxyJumpTransportNotes();
    napi_create_string_utf8(env, notes.c_str(), notes.size(), &result);
    return result;
}

napi_value ForwardParseJumpSpec(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string spec;
    if (argc < 1 || !GetStringArg(env, argv[0], spec)) {
        return MakeBool(env, false);
    }
    const auto hops = ssh::parseProxyJumpSpec(spec);
    // 返回 JSON 数组字符串（简单组包，无嵌套特殊字符时足够；host 含 " 时由上层校验）
    std::string json = "[";
    for (size_t i = 0; i < hops.size(); ++i) {
        if (i > 0) {
            json += ",";
        }
        json += "{\"username\":\"" + hops[i].username + "\",\"host\":\"" + hops[i].host +
                "\",\"port\":" + std::to_string(hops[i].port) + "}";
    }
    json += "]";
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), json.size(), &result);
    return result;
}

} // namespace

void ForgetForward(uint64_t forwardHandle)
{
    auto th = g_fwdTable.erase(forwardHandle);
    if (!th) {
        return;
    }
    th->closing.store(true);
    if (th->data) {
        th->data->close();
    }
    if (th->remote) {
        th->remote->cancel();
    }
}

void RegisterForwardBridge(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"openDirectTcpip", nullptr, OpenDirectTcpip, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"forwardWrite", nullptr, ForwardWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"forwardClose", nullptr, ForwardClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"remoteForwardListen", nullptr, RemoteForwardListen, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"remoteForwardCancel", nullptr, RemoteForwardCancel, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"forwardProxyJumpNotes", nullptr, ForwardProxyJumpNotes, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"forwardParseJumpSpec", nullptr, ForwardParseJumpSpec, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterForwardBridge: napi_define_properties failed");
    }
}

} // namespace bridge
} // namespace sshclient
