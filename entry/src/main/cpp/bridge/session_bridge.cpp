/**
 * NAPI 会话桥接实现 —— 任务 N11。对外契约与线程模型见 session_bridge.h 头注。
 *
 * 实现要点速览：
 *   - BridgeEvent：跨线程事件载体（堆分配，入队 TSFN，CallJs 消费后释放）；
 *   - TsfnBridge：每条 TSFN 的上下文（入口开关 + inFlight 跟踪 + 丢弃计数），
 *     由 TSFN finalize 回调释放——TSFN 可能晚于 SessionHandle 销毁，二者解耦；
 *   - SessionHandle：SessionThread + SshSession + 通道表 + 两条 TSFN 上下文；
 *   - 全局句柄表 g_table（handle_table.h，纯逻辑单测覆盖）；
 *   - closeSession 幂等：摘表后立即返回，teardown 在独立线程执行；
 *   - env 销毁（OnEnvCleanup）：全量 teardown 并等待异步 teardown 收尾。
 */
#include "session_bridge.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"
#include "hilog/log.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_set>

#include "../io/EventLoop.h"
#include "../io/SessionThread.h"
#include "../ssh/auth.h" // secureZero（OPENSSL_cleanse 封装）
#include "../ssh/channel.h"
#include "../ssh/session.h"
#include "data_aggregator.h"
#include "handle_table.h"

namespace sshclient {
namespace bridge {
namespace {

// ---------------------------------------------------------------- 事件载体

enum class EventKind {
    kStateChange,
    kHostKey,
    kAuthResult,
    kChannelOpen,
    kChannelData,
    kChannelClose,
    kError,
};

// 各字段按 kind 取用（命名含义见 CallJs 的组包分支）；统一结构避免按类型拆堆对象
struct BridgeEvent {
    EventKind kind;
    uint32_t channelId = 0; // kChannelOpen / kChannelData / kChannelClose
    int stream = 0;         // kChannelData：0=stdout 1=stderr
    long number = 0;        // attemptsLeft / exitStatus / droppedCount
    bool success = false;   // kAuthResult / kChannelOpen
    std::string text1;      // from / keyType / method / openError / closeReason / code
    std::string text2;      // to / sha256 / authError / openMessage / exitSignal / message
    std::string text3;      // md5 / authMessage / closeMessage
    std::string text4;      // randomart
    std::string bytes;      // kChannelData 聚合批次（原始字节，可能切断 UTF-8 序列）
};

// ---------------------------------------------------------------- TSFN 上下文

// 数据队列上限：256 批 × 16 KiB ≈ 4 MiB/会话的背压天花板
constexpr size_t kDataQueueMaxBatches = 256;

struct TsfnBridge {
    napi_threadsafe_function tsfn = nullptr;
    // 生产者入口开关：teardown 首先关掉它，此后 EnqueueEvent 即弃即收
    std::atomic<bool> accepting{true};
    // inFlight：已入队未消费的堆事件；TSFN abort/env 销毁导致事件不再投递时，
    // 由 finalize 统一回收，保证任何路径都不泄漏
    std::mutex mutex;
    std::unordered_set<BridgeEvent *> inFlight;
    // 数据队列连续丢弃计数（仅循环线程写）：用于「丢弃边沿」补发 error 事件
    uint64_t droppedSinceOk = 0;
};

void StopAccepting(TsfnBridge *ctx)
{
    if (ctx == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(ctx->mutex);
    ctx->accepting.store(false, std::memory_order_relaxed);
}

// non-blocking 入队（native 线程永不被 ArkTS 堵死）。
// false = 未入队（入口已关/队列满/TSFN 关闭），事件已由本函数回收
bool EnqueueEvent(TsfnBridge *ctx, BridgeEvent *evt)
{
    if (ctx == nullptr || ctx->tsfn == nullptr) {
        delete evt;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(ctx->mutex);
        if (!ctx->accepting.load(std::memory_order_relaxed)) {
            delete evt; // BridgeEvent 析构平凡，持锁内回收无风险
            return false;
        }
        ctx->inFlight.insert(evt);
    }
    if (napi_call_threadsafe_function(ctx->tsfn, evt, napi_tsfn_nonblocking) != napi_ok) {
        // napi_queue_full / napi_closing 等：回滚登记并回收
        std::lock_guard<std::mutex> lock(ctx->mutex);
        ctx->inFlight.erase(evt);
        delete evt;
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- napi 值构造小工具

void SetStrProp(napi_env env, napi_value obj, const char *name, const std::string &value)
{
    napi_value val = nullptr;
    if (napi_create_string_utf8(env, value.c_str(), value.size(), &val) == napi_ok) {
        napi_set_named_property(env, obj, name, val);
    }
}

void SetNumProp(napi_env env, napi_value obj, const char *name, double value)
{
    napi_value val = nullptr;
    if (napi_create_double(env, value, &val) == napi_ok) {
        napi_set_named_property(env, obj, name, val);
    }
}

void SetBoolProp(napi_env env, napi_value obj, const char *name, bool value)
{
    napi_value val = nullptr;
    if (napi_get_boolean(env, value, &val) == napi_ok) {
        napi_set_named_property(env, obj, name, val);
    }
}

// channelData 是原始字节（可能切断 UTF-8 序列），用 ArrayBuffer 投递，
// ArkTS 侧以流式 TextDecoder 解码；复制一次（T3 前的过渡路径，成本可忽略）
void SetBytesProp(napi_env env, napi_value obj, const char *name, const std::string &bytes)
{
    void *data = nullptr;
    napi_value ab = nullptr;
    if (napi_create_arraybuffer(env, bytes.size(), &data, &ab) == napi_ok) {
        if (!bytes.empty() && data != nullptr) {
            std::memcpy(data, bytes.data(), bytes.size());
        }
        napi_set_named_property(env, obj, name, ab);
    }
}

// TSFN 的 JS 侧投递回调（ArkTS 线程执行）
void CallJs(napi_env env, napi_value jsCb, void *context, void *data)
{
    auto *ctx = static_cast<TsfnBridge *>(context);
    std::unique_ptr<BridgeEvent> evt(static_cast<BridgeEvent *>(data));
    if (ctx != nullptr) {
        std::lock_guard<std::mutex> lock(ctx->mutex);
        ctx->inFlight.erase(evt.get());
    }
    if (jsCb == nullptr) {
        return;
    }

    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    switch (evt->kind) {
    case EventKind::kStateChange:
        SetStrProp(env, obj, "type", "stateChange");
        SetStrProp(env, obj, "from", evt->text1);
        SetStrProp(env, obj, "to", evt->text2);
        break;
    case EventKind::kHostKey:
        SetStrProp(env, obj, "type", "hostKey");
        SetStrProp(env, obj, "keyType", evt->text1);
        SetStrProp(env, obj, "fingerprintSha256", evt->text2);
        SetStrProp(env, obj, "fingerprintMd5", evt->text3);
        SetStrProp(env, obj, "randomart", evt->text4);
        break;
    case EventKind::kAuthResult:
        SetStrProp(env, obj, "type", "authResult");
        SetStrProp(env, obj, "method", evt->text1);
        SetBoolProp(env, obj, "success", evt->success);
        SetStrProp(env, obj, "error", evt->text2);
        SetStrProp(env, obj, "message", evt->text3);
        SetNumProp(env, obj, "attemptsLeft", static_cast<double>(evt->number));
        break;
    case EventKind::kChannelOpen:
        SetStrProp(env, obj, "type", "channelOpen");
        SetNumProp(env, obj, "channelId", static_cast<double>(evt->channelId));
        SetBoolProp(env, obj, "success", evt->success);
        SetStrProp(env, obj, "error", evt->text1);
        SetStrProp(env, obj, "message", evt->text2);
        break;
    case EventKind::kChannelData:
        SetStrProp(env, obj, "type", "channelData");
        SetNumProp(env, obj, "channelId", static_cast<double>(evt->channelId));
        SetNumProp(env, obj, "stream", static_cast<double>(evt->stream));
        SetBytesProp(env, obj, "data", evt->bytes);
        break;
    case EventKind::kChannelClose:
        SetStrProp(env, obj, "type", "channelClose");
        SetNumProp(env, obj, "channelId", static_cast<double>(evt->channelId));
        SetStrProp(env, obj, "reason", evt->text1);
        SetNumProp(env, obj, "exitStatus", static_cast<double>(evt->number));
        SetStrProp(env, obj, "exitSignal", evt->text2);
        SetStrProp(env, obj, "message", evt->text3);
        break;
    case EventKind::kError:
        SetStrProp(env, obj, "type", "error");
        SetStrProp(env, obj, "code", evt->text1);
        SetStrProp(env, obj, "message", evt->text2);
        SetNumProp(env, obj, "count", static_cast<double>(evt->number));
        break;
    }

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value argv[] = {obj};
    napi_value result = nullptr;
    if (napi_call_function(env, undefined, jsCb, 1, argv, &result) == napi_pending_exception) {
        // ArkTS 回调抛异常不能向 native 扩散：清掉异常仅记日志
        napi_value exc = nullptr;
        napi_get_and_clear_last_exception(env, &exc);
        OH_LOG_WARN(LOG_APP, "onEvent 回调抛出异常，已吞掉（type=%{public}s 事件丢失）",
                    evt->kind == EventKind::kChannelData ? "channelData" : "state/other");
    }
}

// TSFN 销毁回调（API 语义保证此时不再有 CallJs 并发）：回收残留事件与上下文
void TsfnFinalize(napi_env /*env*/, void *finalizeData, void * /*hint*/)
{
    auto *ctx = static_cast<TsfnBridge *>(finalizeData);
    for (BridgeEvent *evt : ctx->inFlight) {
        delete evt;
    }
    ctx->inFlight.clear();
    delete ctx;
}

// ---------------------------------------------------------------- 会话句柄

struct ChannelEntry {
    std::unique_ptr<ssh::SshChannel> channel;
    DataAggregator aggOut;   // stdout 聚合
    DataAggregator aggErr;   // stderr 聚合
    bool flushArmed = false; // 聚合冲刷定时器在途（仅循环线程访问）
};

struct SessionHandle {
    napi_env env = nullptr;
    uint64_t handle = 0;

    // 成员声明顺序保证析构顺序（反向）：thread 最后析构，
    // 满足「SessionThread 寿命长于 SshSession/SshChannel」的契约（ssh/session.h 头注）
    io::SessionThread thread;
    std::unique_ptr<ssh::SshSession> session;
    // 通道表：map 节点指针稳定；JS 线程经 shared_ptr 副本短时持有条目做
    // write/resize/close，循环线程的 deferred erase / teardown 的 clear 不与其竞争
    std::mutex channelsMutex;
    std::map<uint32_t, std::shared_ptr<ChannelEntry>> channels;
    std::atomic<uint32_t> nextChannelId{1}; // 会话内单调递增，不复用

    // 两条 TSFN 上下文：由各自 TSFN 的 finalize 释放，本对象不 delete
    TsfnBridge *stateBridge = nullptr;
    TsfnBridge *dataBridge = nullptr;

    std::atomic<bool> tornDown{false};

    ~SessionHandle()
    {
        // 防御：正常路径已被 Teardown 收尾（CAS 幂等，此处空操作）；
        // 仅 createSession 半途失败等异常路径才真正在本析构里执行
        Teardown();
    }

    // 幂等回收（顺序即任务约定的「先停线程再释放」）：
    //   1. 关 TSFN 入口：此后循环线程事件即弃即收；
    //   2. 优雅关闭会话并等终态（close 自带冲刷上限；idle 空操作）；
    //   3. 停循环线程（wakeup → join → 清遗留任务），此后不再有任何回调；
    //   4. 析构通道与会话（SshChannel 析构约定：终止回调已送达）；
    //   5. 释放 TSFN：release 模式让已入队事件继续投递完；env 销毁等
    //      无法投递的场景由 finalize 兜底回收 inFlight。
    void Teardown()
    {
        bool expected = false;
        if (!tornDown.compare_exchange_strong(expected, true)) {
            return;
        }
        StopAccepting(stateBridge);
        StopAccepting(dataBridge);

        if (session) {
            if (session->state() != ssh::SshSessionState::kIdle) {
                session->close();
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
                while (!IsTerminal(session->state()) && std::chrono::steady_clock::now() < deadline) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(20));
                }
                if (!IsTerminal(session->state())) {
                    // 超时兜底：不再等。下方 thread.stop 后 SshSession 析构会直接
                    // 回收 libssh2 会话与 fd（session.h 析构约定）；通道侧若有未释放
                    // 句柄，SshChannel 析构仅告警不崩（正常不会走到：close 冲刷上限 2s）
                    OH_LOG_WARN(LOG_APP, "会话关闭等待终态超时，走兜底回收");
                }
            }
        }

        thread.stop();

        {
            std::lock_guard<std::mutex> lock(channelsMutex);
            channels.clear();
        }
        session.reset();

        if (dataBridge != nullptr && dataBridge->tsfn != nullptr) {
            napi_release_threadsafe_function(dataBridge->tsfn, napi_tsfn_release);
        }
        if (stateBridge != nullptr && stateBridge->tsfn != nullptr) {
            napi_release_threadsafe_function(stateBridge->tsfn, napi_tsfn_release);
        }
    }

    static bool IsTerminal(ssh::SshSessionState st)
    {
        return st == ssh::SshSessionState::kClosed || st == ssh::SshSessionState::kDisconnected ||
               st == ssh::SshSessionState::kError;
    }
};

// ---------------------------------------------------------------- 全局注册表

HandleTable<SessionHandle> g_table;
std::mutex g_teardownMutex;
std::condition_variable g_teardownCv;
int g_activeTeardowns = 0; // 进行中的异步 teardown 计数（g_teardownMutex 保护）

// ---------------------------------------------------------------- 事件发送（循环线程）

void SendStateEvent(SessionHandle *sh, BridgeEvent *evt)
{
    EnqueueEvent(sh->stateBridge, evt);
}

void SendDataEvent(SessionHandle *sh, BridgeEvent *evt)
{
    TsfnBridge *d = sh->dataBridge;
    if (EnqueueEvent(d, evt)) {
        d->droppedSinceOk = 0;
        return;
    }
    // 丢弃（限量队列满 = ArkTS 消费过慢）：边沿触发补发一条 error 事件，
    // 避免每丢一批发一条把状态队列也打爆
    ++d->droppedSinceOk;
    if (d->droppedSinceOk == 1) {
        auto *err = new BridgeEvent{EventKind::kError};
        err->text1 = "data_queue_full";
        err->text2 = "ArkTS 消费过慢，channelData 批次被丢弃（限量队列背压）";
        EnqueueEvent(sh->stateBridge, err);
    }
}

std::shared_ptr<ChannelEntry> FindChannel(SessionHandle *sh, uint32_t channelId)
{
    std::lock_guard<std::mutex> lock(sh->channelsMutex);
    auto it = sh->channels.find(channelId);
    return it != sh->channels.end() ? it->second : nullptr;
}

void FlushAggregator(SessionHandle *sh, uint32_t channelId, int stream, DataAggregator &agg)
{
    if (agg.empty()) {
        return;
    }
    auto *evt = new BridgeEvent{EventKind::kChannelData};
    evt->channelId = channelId;
    evt->stream = stream;
    evt->bytes = agg.takeBatch();
    SendDataEvent(sh, evt);
}

// 以下两个函数仅循环线程调用（onData / 冲刷定时器内）
void ArmFlushTimerIfNeeded(SessionHandle *sh, uint32_t channelId);

void OnFlushTimer(SessionHandle *sh, uint32_t channelId)
{
    auto entry = FindChannel(sh, channelId);
    if (!entry) {
        return;
    }
    entry->flushArmed = false;
    const auto now = DataAggregator::Clock::now();
    if (auto ms = entry->aggOut.msUntilTimeFlush(now); ms && *ms <= 0) {
        FlushAggregator(sh, channelId, 0, entry->aggOut);
    }
    if (auto ms = entry->aggErr.msUntilTimeFlush(now); ms && *ms <= 0) {
        FlushAggregator(sh, channelId, 1, entry->aggErr);
    }
    // 仍有未到期积压（定时器按最早到期武装，另一流可能稍后到期）→ 重新武装
    ArmFlushTimerIfNeeded(sh, channelId);
}

void ArmFlushTimerIfNeeded(SessionHandle *sh, uint32_t channelId)
{
    auto entry = FindChannel(sh, channelId);
    if (!entry || entry->flushArmed) {
        return;
    }
    const auto now = DataAggregator::Clock::now();
    auto msOut = entry->aggOut.msUntilTimeFlush(now);
    auto msErr = entry->aggErr.msUntilTimeFlush(now);
    std::optional<int64_t> delay;
    if (msOut) {
        delay = *msOut;
    }
    if (msErr && (!delay || *msErr < *delay)) {
        delay = *msErr;
    }
    if (!delay) {
        return; // 无积压
    }
    entry->flushArmed = true;
    // 已到期（负值）按 0 立即触发
    const uint64_t delayMs = static_cast<uint64_t>(*delay > 0 ? *delay : 0);
    sh->thread.loop().runAfter(delayMs, [sh, channelId]() { OnFlushTimer(sh, channelId); });
}

void OnChannelData(SessionHandle *sh, uint32_t channelId, ssh::ChannelStream stream,
                   const std::string &data)
{
    auto entry = FindChannel(sh, channelId);
    if (!entry) {
        return;
    }
    const bool isOut = (stream == ssh::ChannelStream::kStdout);
    DataAggregator &agg = isOut ? entry->aggOut : entry->aggErr;
    if (agg.feed(data)) {
        // 尺寸阈值：立即冲刷（定时器到点发现空批次自然空转，无需取消）
        FlushAggregator(sh, channelId, isOut ? 0 : 1, agg);
    } else {
        ArmFlushTimerIfNeeded(sh, channelId);
    }
}

// 通道终结后摘除条目：必须在回调外（下一条循环任务）执行——
// 「回调内不得析构本对象」（ssh/channel.h 契约）
void ScheduleChannelErase(SessionHandle *sh, uint32_t channelId)
{
    sh->thread.post([sh, channelId]() {
        std::lock_guard<std::mutex> lock(sh->channelsMutex);
        sh->channels.erase(channelId);
    });
}

ssh::SshChannelCallbacks MakeChannelCallbacks(SessionHandle *sh, uint32_t channelId)
{
    ssh::SshChannelCallbacks cb;
    cb.onOpen = [sh, channelId](const ssh::ChannelOpenResult &r) {
        auto *evt = new BridgeEvent{EventKind::kChannelOpen};
        evt->channelId = channelId;
        evt->success = r.success;
        evt->text1 = ssh::toString(r.error);
        evt->text2 = r.message;
        SendStateEvent(sh, evt);
        if (!r.success) {
            ScheduleChannelErase(sh, channelId); // 打开失败即终态，不再有 onClose
        }
    };
    cb.onData = [sh, channelId](const std::string &data, ssh::ChannelStream stream) {
        OnChannelData(sh, channelId, stream, data);
    };
    cb.onClose = [sh, channelId](const ssh::ChannelCloseInfo &info) {
        // 先冲刷聚合残余再发关闭事件（同一数据队列内保序；
        // 数据队列与状态队列之间的顺序不保证，见 session_bridge.h 头注）
        if (auto entry = FindChannel(sh, channelId)) {
            FlushAggregator(sh, channelId, 0, entry->aggOut);
            FlushAggregator(sh, channelId, 1, entry->aggErr);
        }
        auto *evt = new BridgeEvent{EventKind::kChannelClose};
        evt->channelId = channelId;
        evt->text1 = ssh::toString(info.reason);
        evt->number = info.exitStatus;
        evt->text2 = info.exitSignal;
        evt->text3 = info.message;
        SendStateEvent(sh, evt);
        ScheduleChannelErase(sh, channelId);
    };
    return cb;
}

ssh::AuthCallback MakeAuthCallback(SessionHandle *sh, const char *method)
{
    return [sh, method](const ssh::AuthResult &r) {
        auto *evt = new BridgeEvent{EventKind::kAuthResult};
        evt->text1 = method;
        evt->success = r.success;
        evt->text2 = ssh::toString(r.error);
        evt->text3 = r.message;
        evt->number = static_cast<long>(r.attemptsLeft);
        SendStateEvent(sh, evt);
    };
}

// ---------------------------------------------------------------- napi 参数读取

napi_value MakeBool(napi_env env, bool v)
{
    napi_value r = nullptr;
    napi_get_boolean(env, v, &r);
    return r;
}

napi_value MakeHandleValue(napi_env env, uint64_t h)
{
    napi_value r = nullptr;
    // 句柄经 double 传递：2^53 以内的单调递增句柄精确无损失
    napi_create_double(env, static_cast<double>(h), &r);
    return r;
}

bool GetHandleArg(napi_env env, napi_value v, uint64_t &out)
{
    double d = 0;
    if (napi_get_value_double(env, v, &d) != napi_ok || d < 1) {
        return false;
    }
    out = static_cast<uint64_t>(d);
    return true;
}

bool GetUint32Arg(napi_env env, napi_value v, uint32_t &out)
{
    double d = 0;
    if (napi_get_value_double(env, v, &d) != napi_ok || d < 0) {
        return false;
    }
    out = static_cast<uint32_t>(d);
    return true;
}

bool GetStringArg(napi_env env, napi_value v, std::string &out)
{
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, v, &vt) != napi_ok || vt != napi_string) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    size_t copied = 0;
    // 缓冲区给 len+1 容纳 NUL 终止符；copied 为实际字节数（不含终止符）
    if (napi_get_value_string_utf8(env, v, out.data(), len + 1, &copied) != napi_ok) {
        return false;
    }
    out.resize(copied);
    return true;
}

// 字节参数：ArrayBuffer（私钥/写入数据）或 string（便捷路径）
bool GetBytesArg(napi_env env, napi_value v, std::string &out)
{
    bool isAb = false;
    if (napi_is_arraybuffer(env, v, &isAb) == napi_ok && isAb) {
        void *data = nullptr;
        size_t len = 0;
        if (napi_get_arraybuffer_info(env, v, &data, &len) != napi_ok) {
            return false;
        }
        out.assign(static_cast<const char *>(data), len);
        return true;
    }
    return GetStringArg(env, v, out);
}

// 查找存活会话（teardown 中的会话视为已关闭）
std::shared_ptr<SessionHandle> LookupLive(uint64_t handle)
{
    auto sh = g_table.lookup(handle);
    if (!sh || sh->tornDown.load(std::memory_order_acquire)) {
        return nullptr;
    }
    return sh;
}

// ---------------------------------------------------------------- napi 方法实现

napi_value CreateSession(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_valuetype vt = napi_undefined;
    if (argc < 1 || argv[0] == nullptr || napi_typeof(env, argv[0], &vt) != napi_ok ||
        vt != napi_function) {
        OH_LOG_ERROR(LOG_APP, "createSession: 需要 onEvent 回调参数");
        return MakeHandleValue(env, 0);
    }

    auto sh = std::make_shared<SessionHandle>();
    sh->env = env;

    // 每会话两条 TSFN（session_bridge.h 头注：state 无限队列绝不丢，
    // data 限量队列 + 聚合背压）。指针先挂进 sh：下方任何失败路径都让
    // shared_ptr 析构走 Teardown 统一回收，不手写分散清理。
    napi_value name = nullptr;
    auto *stateCtx = new TsfnBridge();
    napi_create_string_utf8(env, "sshStateEvents", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, argv[0], nullptr, name, 0 /* unlimited */, 1, stateCtx,
                                        TsfnFinalize, stateCtx, CallJs,
                                        &stateCtx->tsfn) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "createSession: state TSFN 创建失败");
        delete stateCtx; // 未创建成功，无 finalize，自行回收
        return MakeHandleValue(env, 0);
    }
    sh->stateBridge = stateCtx;

    auto *dataCtx = new TsfnBridge();
    napi_create_string_utf8(env, "sshDataEvents", NAPI_AUTO_LENGTH, &name);
    if (napi_create_threadsafe_function(env, argv[0], nullptr, name, kDataQueueMaxBatches, 1,
                                        dataCtx, TsfnFinalize, dataCtx, CallJs,
                                        &dataCtx->tsfn) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "createSession: data TSFN 创建失败");
        delete dataCtx;
        return MakeHandleValue(env, 0); // stateBridge 已挂 sh，随析构回收
    }
    sh->dataBridge = dataCtx;

    if (!sh->thread.start()) {
        OH_LOG_ERROR(LOG_APP, "createSession: SessionThread 启动失败");
        return MakeHandleValue(env, 0);
    }

    // N7 主机密钥：bridge 层「接受并上报」（任务边界，TOFU 编排留给上层，
    // 见 session_bridge.h 头注）；回调在循环线程同步调用，必须快速返回
    ssh::SshSessionOptions opts;
    SessionHandle *raw = sh.get(); // 裸指针捕获安全依据：回调只在循环线程触发，
                                   // 线程在 SessionHandle 析构前已 join
    opts.hostKeyCallback = [raw](const ssh::HostKeyInfo &info) {
        auto *evt = new BridgeEvent{EventKind::kHostKey};
        evt->text1 = info.keyType;
        evt->text2 = info.fingerprintSha256;
        evt->text3 = info.fingerprintMd5;
        evt->text4 = info.randomart;
        SendStateEvent(raw, evt);
        return ssh::HostKeyDecision::kAccept;
    };

    sh->session = std::make_unique<ssh::SshSession>(
        sh->thread, opts, [raw](ssh::SshSessionState from, ssh::SshSessionState to) {
            auto *evt = new BridgeEvent{EventKind::kStateChange};
            evt->text1 = ssh::toString(from);
            evt->text2 = ssh::toString(to);
            SendStateEvent(raw, evt);
        });

    const uint64_t h = g_table.insert(sh);
    sh->handle = h;
    OH_LOG_INFO(LOG_APP, "createSession: handle=%{public}llu", (unsigned long long)h);
    return MakeHandleValue(env, h);
}

napi_value Connect(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    uint32_t port = 0;
    std::string host, username;
    if (argc < 4 || !GetHandleArg(env, argv[0], h) || !GetStringArg(env, argv[1], host) ||
        !GetUint32Arg(env, argv[2], port) || port == 0 || port > 65535 ||
        !GetStringArg(env, argv[3], username)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh || !sh->session) {
        return MakeBool(env, false);
    }
    // 受理语义见 ssh/session.h：非 idle 态/重复调用返回 false；结果经 stateChange 事件
    return MakeBool(env, sh->session->connect(std::move(host), static_cast<uint16_t>(port),
                                              std::move(username)));
}

napi_value AuthenticatePassword(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    std::string password;
    if (argc < 2 || !GetHandleArg(env, argv[0], h) || !GetStringArg(env, argv[1], password)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh || !sh->session) {
        ssh::secureZero(password); // 会话不存在：napi 侧副本自清
        return MakeBool(env, false);
    }
    // 受理时 SshSession 复制凭据并 secureZero 本 buffer（auth.h 受理语义）；
    // 未受理（非 authenticating 态/已有认证进行中）时本层自行清零
    bool ok = sh->session->authenticatePassword(password, MakeAuthCallback(sh.get(), "password"));
    if (!ok) {
        ssh::secureZero(password);
    }
    return MakeBool(env, ok);
}

napi_value AuthenticatePublicKey(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    std::string privateKey, publicKey, passphrase;
    if (argc < 4 || !GetHandleArg(env, argv[0], h) || !GetBytesArg(env, argv[1], privateKey) ||
        !GetStringArg(env, argv[2], publicKey) || !GetStringArg(env, argv[3], passphrase)) {
        ssh::secureZero(privateKey);
        ssh::secureZero(passphrase);
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh || !sh->session) {
        ssh::secureZero(privateKey);
        ssh::secureZero(passphrase);
        return MakeBool(env, false);
    }
    // 受理即复制并清零 privateKey/passphrase（公钥非敏感不清零，auth.h 注释）；
    // 未受理本层自清。边界：ArkTS 运行时持有的原始副本无法清零（头注）
    bool ok = sh->session->authenticatePublicKey(privateKey, publicKey, passphrase,
                                                 MakeAuthCallback(sh.get(), "publickey"));
    if (!ok) {
        ssh::secureZero(privateKey);
        ssh::secureZero(passphrase);
    }
    return MakeBool(env, ok);
}

// openShell / exec 的公共路径：建通道条目 → 登记 → 受理打开
bool AdmitChannel(napi_env env, napi_callback_info info, bool withPty)
{
    const size_t cap = 4;
    size_t argc = cap;
    napi_value argv[cap] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    if (argc < 2 || !GetHandleArg(env, argv[0], h)) {
        return false;
    }
    auto sh = LookupLive(h);
    if (!sh || !sh->session) {
        return false;
    }

    std::string termType, command;
    uint32_t cols = 80, rows = 24;
    if (withPty) {
        if (argc < 4 || !GetStringArg(env, argv[1], termType) ||
            !GetUint32Arg(env, argv[2], cols) || !GetUint32Arg(env, argv[3], rows) ||
            cols == 0 || rows == 0) {
            return false;
        }
    } else {
        if (!GetStringArg(env, argv[1], command) || command.empty()) {
            return false;
        }
    }

    const uint32_t channelId = sh->nextChannelId.fetch_add(1, std::memory_order_relaxed);
    auto entry = std::make_shared<ChannelEntry>();
    entry->channel = std::make_unique<ssh::SshChannel>(*sh->session,
                                                       MakeChannelCallbacks(sh.get(), channelId));
    {
        std::lock_guard<std::mutex> lock(sh->channelsMutex);
        sh->channels.emplace(channelId, entry);
    }
    bool admitted = false;
    if (withPty) {
        ssh::PtySpec pty;
        pty.termType = termType;
        pty.cols = cols;
        pty.rows = rows;
        admitted = entry->channel->openShell(std::move(pty));
    } else {
        admitted = entry->channel->exec(command);
    }
    if (!admitted) {
        // 未受理（会话非 established 等）：不会有任何回调触发，直接摘除
        std::lock_guard<std::mutex> lock(sh->channelsMutex);
        sh->channels.erase(channelId);
    }
    // 受理后结果经 channelOpen 事件回报（channelId 在事件中）
    return admitted;
}

napi_value OpenShell(napi_env env, napi_callback_info info)
{
    return MakeBool(env, AdmitChannel(env, info, true));
}

napi_value Exec(napi_env env, napi_callback_info info)
{
    return MakeBool(env, AdmitChannel(env, info, false));
}

napi_value Write(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    uint32_t channelId = 0;
    std::string bytes;
    if (argc < 3 || !GetHandleArg(env, argv[0], h) || !GetUint32Arg(env, argv[1], channelId) ||
        !GetBytesArg(env, argv[2], bytes)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh) {
        return MakeBool(env, false);
    }
    auto entry = FindChannel(sh.get(), channelId);
    if (!entry) {
        return MakeBool(env, false);
    }
    // 背压语义：待发队列超限整次拒收（false），调用方保留数据稍后重试
    return MakeBool(env, entry->channel->write(bytes.data(), bytes.size()));
}

napi_value Resize(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    uint32_t channelId = 0, cols = 0, rows = 0;
    if (argc < 4 || !GetHandleArg(env, argv[0], h) || !GetUint32Arg(env, argv[1], channelId) ||
        !GetUint32Arg(env, argv[2], cols) || !GetUint32Arg(env, argv[3], rows)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh) {
        return MakeBool(env, false);
    }
    auto entry = FindChannel(sh.get(), channelId);
    if (!entry) {
        return MakeBool(env, false);
    }
    return MakeBool(env, entry->channel->resize(cols, rows));
}

napi_value CloseChannel(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    uint32_t channelId = 0;
    if (argc < 2 || !GetHandleArg(env, argv[0], h) || !GetUint32Arg(env, argv[1], channelId)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh) {
        return MakeBool(env, false);
    }
    auto entry = FindChannel(sh.get(), channelId);
    if (!entry) {
        return MakeBool(env, false); // 幂等：不存在视为已关闭
    }
    entry->channel->close(); // 幂等；关闭结果经 channelClose 事件
    return MakeBool(env, true);
}

napi_value CloseSession(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], h)) {
        return MakeBool(env, false);
    }
    auto sh = g_table.erase(h);
    if (!sh) {
        return MakeBool(env, false); // 幂等：重复关闭返回 false
    }
    // 优雅关闭要等会话终态（最长秒级），不能堵 ArkTS 主线程：
    // 摘表后立即返回，回收在独立线程做；shared_ptr 保活到回收完成
    {
        std::lock_guard<std::mutex> lock(g_teardownMutex);
        ++g_activeTeardowns;
    }
    std::thread([sh]() {
        sh->Teardown();
        std::lock_guard<std::mutex> lock(g_teardownMutex);
        if (--g_activeTeardowns == 0) {
            g_teardownCv.notify_all();
        }
    }).detach();
    return MakeBool(env, true);
}

// env 销毁清理钩子：全部会话同步优雅停掉（VM 正在关闭，阻塞可接受），
// 并等待进行中的异步 teardown 收尾——它们的 TSFN 属于本 env，必须先放完。
// 注意 OHOS 的 napi_add_env_cleanup_hook 签名是 void(*)(void*)（不传 env，
// 见 napi/native_api.h；与 Node 的 (env, arg) 两参形式不同）——注册表是全局的，
// 不需要 env 参数
void OnEnvCleanup(void * /*arg*/)
{
    for (auto &sh : g_table.eraseAll()) {
        sh->Teardown();
    }
    std::unique_lock<std::mutex> lock(g_teardownMutex);
    g_teardownCv.wait(lock, [] { return g_activeTeardowns == 0; });
}

} // namespace

void RegisterSessionBridge(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"createSession", nullptr, CreateSession, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"authenticatePassword", nullptr, AuthenticatePassword, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"authenticatePublicKey", nullptr, AuthenticatePublicKey, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"openShell", nullptr, OpenShell, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exec", nullptr, Exec, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"write", nullptr, Write, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resize", nullptr, Resize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeChannel", nullptr, CloseChannel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeSession", nullptr, CloseSession, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterSessionBridge: napi_define_properties failed");
    }
    if (napi_add_env_cleanup_hook(env, OnEnvCleanup, nullptr) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterSessionBridge: napi_add_env_cleanup_hook failed");
    }
}

} // namespace bridge
} // namespace sshclient
