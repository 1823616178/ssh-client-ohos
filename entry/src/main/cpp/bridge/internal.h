/**
 * bridge 模块内部共享件 —— N11 会话桥与 T3 终端桥（terminal_bridge）共用。
 *
 * 本头只在 bridge/ 目录内部使用（session_bridge.cpp / terminal_bridge.cpp），
 * 不参与对外接口；允许 include napi（本目录是唯一允许碰 napi 的位置之一）。
 *
 * 内容：
 *   - BridgeEvent / EventKind：跨线程事件载体（循环线程 → TSFN → ArkTS）；
 *     T3 新增 terminalOpen/terminalClose/terminalBell/terminalTitle/
 *     terminalMouseMode 五种终端事件类型，随事件携带 terminal 句柄；
 *   - TsfnBridge + EnqueueEvent：TSFN 上下文与 non-blocking 入队（语义见
 *     session_bridge.h 头注）；
 *   - napi 参数/组包小工具（Get*Arg / Set*Prop / Make*）；
 *   - ChannelEntry / SessionHandle：会话句柄全定义（terminal_bridge 需要
 *     访问 thread/stateBridge/terminals 等成员）；Teardown 定义仍在
 *     session_bridge.cpp；
 *   - g_table / LookupLive / SendStateEvent：会话句柄表与状态事件发送。
 *
 * SessionHandle::terminals（T3）：本会话 attach 的终端句柄表
 * （terminalHandle → TerminalHandle，TerminalHandle 定义在 terminal_bridge.cpp）。
 * 回收编排：closeTerminal 只「关门」（摘全局表 + post 关闭任务），本体留在
 * 本表随会话 Teardown 统一析构——保证通道/vterm 的销毁晚于「循环线程不再
 * 回调」，且 channel 析构不晚于 session.reset()（SshChannel 析构约定）。
 */
#pragma once

#include "napi/native_api.h"

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>

#include "../io/SessionThread.h"
#include "../ssh/reconnect_policy.h" // N12：BackoffSchedule（每会话重连退避策略）
#include "../ssh/session.h"         // SshSessionState（IsTerminal 用）与完整会话类型
#include "data_aggregator.h"
#include "handle_table.h"

namespace sshclient {

namespace ssh {
class SshChannel;
} // namespace ssh

namespace bridge {

struct TerminalHandle; // terminal_bridge.cpp 定义（shared_ptr 持有，此处无需完整类型）

// ---------------------------------------------------------------- 事件载体

enum class EventKind {
    kStateChange,
    kHostKey,
    kAuthResult,
    kChannelOpen,
    kChannelData,
    kChannelClose,
    kError,
    // ---- T3 终端事件（经 stateTsfn 投递，terminal 字段携带终端句柄）----
    kTerminalOpen,      // 终端绑定的 shell 通道打开结果（attachTerminal 受理后回报）
    kTerminalClose,     // 终端通道终结（对端退出/会话丢失/closeTerminal 后收尾）
    kTerminalBell,      // vterm bell（UI 触感）
    kTerminalTitle,     // OSC 标题变更
    kTerminalMouseMode, // 鼠标上报模式变更（DECSET 1000/1002/1003）
};

// 各字段按 kind 取用（命名含义见 session_bridge.cpp CallJs 的组包分支）；
// 统一结构避免按类型拆堆对象
struct BridgeEvent {
    EventKind kind;
    uint32_t channelId = 0; // kChannelOpen / kChannelData / kChannelClose
    uint64_t terminal = 0;  // kTerminal*：终端句柄
    int stream = 0;         // kChannelData：0=stdout 1=stderr
    long number = 0;        // attemptsLeft / exitStatus / droppedCount / kStateChange 终态的统一错误码（N13）/ kTerminalMouseMode 的模式值
    bool success = false;   // kAuthResult / kChannelOpen / kTerminalOpen / kStateChange 终态的 reconnectHint 值
    bool hasHint = false;   // kStateChange：终态（disconnected/error/closed）附重连提示（N12）
    std::string text1;      // from / keyType / method / openError / closeReason / code / terminalTitle
    std::string text2;      // to / sha256 / authError / openMessage / exitSignal / message
    std::string text3;      // md5 / authMessage / closeMessage / kStateChange 终态的 errorCodeName
    std::string text4;      // randomart / kStateChange 终态的 errorMessage（N13）
    std::string bytes;      // kChannelData 聚合批次（原始字节，可能切断 UTF-8 序列）
};

// ---------------------------------------------------------------- TSFN 上下文

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

void StopAccepting(TsfnBridge *ctx);

// non-blocking 入队（native 线程永不被 ArkTS 堵死）。
// false = 未入队（入口已关/队列满/TSFN 关闭），事件已由本函数回收
bool EnqueueEvent(TsfnBridge *ctx, BridgeEvent *evt);

// ---------------------------------------------------------------- napi 值构造小工具
//（全部仅 ArkTS 线程调用；定义在 session_bridge.cpp）

void SetStrProp(napi_env env, napi_value obj, const char *name, const std::string &value);
void SetNumProp(napi_env env, napi_value obj, const char *name, double value);
void SetBoolProp(napi_env env, napi_value obj, const char *name, bool value);
void SetBytesProp(napi_env env, napi_value obj, const char *name, const std::string &bytes);

napi_value MakeBool(napi_env env, bool v);
napi_value MakeHandleValue(napi_env env, uint64_t h);
bool GetHandleArg(napi_env env, napi_value v, uint64_t &out);
bool GetUint32Arg(napi_env env, napi_value v, uint32_t &out);
bool GetStringArg(napi_env env, napi_value v, std::string &out);
bool GetBytesArg(napi_env env, napi_value v, std::string &out);

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

    // T3：本会话 attach 的终端（terminalHandle → TerminalHandle）。
    // closeTerminal 不从此摘除（只关通道，见本文件头注）；本表是会话
    // Teardown 时统一回收终端本体的依据
    std::mutex terminalsMutex;
    std::map<uint64_t, std::shared_ptr<TerminalHandle>> terminals;

    // 两条 TSFN 上下文：由各自 TSFN 的 finalize 释放，本对象不 delete
    TsfnBridge *stateBridge = nullptr;
    TsfnBridge *dataBridge = nullptr;

    // N12：每会话重连退避策略（ArkTS 线程经 setReconnectPolicy 写、
    // nextReconnectDelaySec 读；与既有方法同一 ArkTS 串行调用约定，无需加锁）
    ssh::BackoffSchedule reconnectPolicy;

    std::atomic<bool> tornDown{false};

    ~SessionHandle();

    // 幂等回收（定义在 session_bridge.cpp，顺序约定见该处注释）
    void Teardown();

    static bool IsTerminal(ssh::SshSessionState st);
};

// ---------------------------------------------------------------- 全局注册表与协作入口

// 会话句柄表（定义在 session_bridge.cpp）
extern HandleTable<SessionHandle> g_table;

// 查找存活会话（teardown 中的会话视为已关闭）
std::shared_ptr<SessionHandle> LookupLive(uint64_t handle);

// 状态类事件发送（循环线程；stateTsfn 无限队列绝不丢）
void SendStateEvent(SessionHandle *sh, BridgeEvent *evt);

// T3：从终端全局句柄表摘除（幂等）；Teardown 回收终端本体前同步摘掉，
// 此后 ArkTS 侧的 terminal 句柄调用全部落空（定义在 terminal_bridge.cpp）
void ForgetTerminal(uint64_t terminalHandle);

} // namespace bridge
} // namespace sshclient
