/**
 * NAPI 终端桥接实现 —— 任务 T3。对外契约、帧协议、生命周期保护与线程纪律
 * 见 terminal_bridge.h 头注；帧同步纯逻辑（发布槽/清脏协议）在 term/frame_sync.h。
 *
 * 实现要点速览：
 *   - TerminalHandle：env + 所属会话（shared_ptr 保活，防 channel 析构时
 *     session 悬空）+ Core（vterm/channel，仅循环线程使用与销毁）+
 *     FrameSync 发布槽 + 自检块；
 *   - 全局终端句柄表 g_termTable（handle_table.h，与 N11 同一风格）；
 *   - 通道与 vterm 回调一律 weak 捕获 TerminalHandle（防循环引用
 *     th→core→channel→callbacks→th），只在循环线程触发；
 *   - Core 销毁编排：通道终态回调（循环线程）post 销毁任务；detachTerminal
 *     只「关门」（摘表 + closing + channel->close()）；会话 Teardown 的
 *     terminals.clear() 是统一兜底（internal.h 头注）；
 *   - external arraybuffer 的 finalize hint = 网格存储/自检块的 shared_ptr
 *     副本，ArkTS GC 回收 buffer 时才释放旧内存（T3 生命周期保护）。
 */
#include "terminal_bridge.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"
#include "hilog/log.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "../ssh/channel.h"
#include "../term/frame_sync.h"
#include "../term/grid.h"
#include "../term/vterm_screen.h"
#include "internal.h"

namespace sshclient {
namespace bridge {
namespace {

// ---------------------------------------------------------------- 自检模式（R-9 探测）

// 32 字节已知模式：magic("SSHTGRID") + 0x01020304（端序校验）+ 0xA5A55A5A +
// 0x00..0x0F 递增。ArkTS 侧 SshTerminal.ets 持有同一模式的构造代码，
// 读回逐字节比对；常量两边各一份，改动必须同步（index.d.ts 有说明）
std::vector<uint8_t> MakeSelfTestPattern()
{
    std::vector<uint8_t> p(32, 0);
    const char *magic = "SSHTGRID";
    std::memcpy(p.data(), magic, 8);
    p[8] = 0x04;
    p[9] = 0x03;
    p[10] = 0x02;
    p[11] = 0x01; // u32 LE 读回应为 0x01020304
    p[12] = 0x5A;
    p[13] = 0x5A;
    p[14] = 0xA5;
    p[15] = 0xA5; // u32 LE 读回应为 0xA5A55A5A
    for (size_t i = 16; i < 32; ++i) {
        p[i] = static_cast<uint8_t>(i - 16);
    }
    return p;
}

} // namespace

// ---------------------------------------------------------------- TerminalHandle
//（internal.h 前向声明 sshclient::bridge::TerminalHandle 的全定义——
//  SessionHandle::terminals 以 shared_ptr 持有本类型，故必须在 bridge 命名空间
//  定义而非匿名命名空间；销毁编排见 internal.h 头注与本文件 ScheduleCoreDestroy）

struct TerminalHandle {
    // Core：仅会话循环线程使用与销毁（terminal_bridge.h 头注「线程纪律」）。
    // ArkTS 线程经 coreCopy() 拿 shared_ptr 副本短时使用（write/回滚拷贝）
    struct Core {
        std::unique_ptr<term::VtermBridge> vterm;
        std::unique_ptr<ssh::SshChannel> channel;
    };

    napi_env env = nullptr;
    uint64_t handle = 0;
    uint64_t sessionHandleId = 0;
    // 保活会话到本体析构：channel 的析构路径依赖 SshSession 存活
    //（回收编排见 internal.h 头注）
    std::shared_ptr<SessionHandle> session;

    mutable std::mutex coreMutex; // 保护 core 指针本身；循环线程内访问免锁（销毁任务同线程串行）
    std::shared_ptr<Core> core;   // null = 已销毁（通道终态后）

    term::FrameSync frameSync; // 帧发布槽（循环线程 publish/endFrame；ArkTS snapshot）

    // 自检块（attach 时填充，之后只读）；shared_ptr 供 external buffer finalize 保活
    std::shared_ptr<std::vector<uint8_t>> selfTest;

    // detachTerminal/通道终态后置位：onData 丢弃、writeTerminal 拒绝
    std::atomic<bool> closing{false};

    // 拿 Core 副本（任意线程）；已销毁返回 nullptr。副本保活到调用方用完——
    // 销毁点（循环线程）reset 后，副本持有处析构 Core：通道已终态前提由编排保证
    std::shared_ptr<Core> coreCopy() const
    {
        std::lock_guard<std::mutex> lock(coreMutex);
        return core;
    }
};

namespace {

HandleTable<TerminalHandle> g_termTable;

std::shared_ptr<TerminalHandle> LookupTerminal(uint64_t handle)
{
    return g_termTable.lookup(handle);
}

// ---------------------------------------------------------------- Core 销毁编排

// 通道终态（onOpen 失败 / onClose，均在循环线程）后调用：post 销毁任务——
// 下一条循环任务执行，满足「回调内不得析构本对象」契约（同 N11
// ScheduleChannelErase 模式）。循环线程回调内 post 的任务不会「滞留失控」：
// loop 停时 clearPendingTasks 回收闭包（释放捕获），此后不再产生回调；
// 任务若被回收，TerminalHandle 仍由 g_termTable / 会话 terminals 表持有，
// 会话 Teardown 的 terminals.clear() 兜底析构（internal.h 头注）。
void ScheduleCoreDestroy(const std::shared_ptr<TerminalHandle> &th)
{
    th->closing.store(true, std::memory_order_relaxed);
    const uint64_t termId = th->handle;
    th->session->thread.post([th, termId]() {
        // 循环线程：从会话终端表摘除（该表只作 teardown 兜底登记）
        {
            std::lock_guard<std::mutex> lock(th->session->terminalsMutex);
            th->session->terminals.erase(termId);
        }
        // 通道已终态（本任务由终态回调触发），Core 析构满足 SshChannel 约定；
        // 网格内容由 frameSync 既有快照的 shared_ptr 保活，ArkTS 继续读到冻结帧
        std::lock_guard<std::mutex> lock(th->coreMutex);
        th->core.reset();
    });
}

// ---------------------------------------------------------------- 事件发送（循环线程）

void SendTerminalEvent(SessionHandle *sh, uint64_t terminal, BridgeEvent *evt)
{
    evt->terminal = terminal;
    SendStateEvent(sh, evt);
}

// ---------------------------------------------------------------- 回调装配（attach 时一次性注入）

// 通道回调：weak 捕获 TerminalHandle（防循环引用）。weak.lock() 失败只可能是
// 本体已析构——而本体析构蕴含 core/channel 已析构、不会再有回调，故仅作防御
ssh::SshChannelCallbacks MakeTerminalCallbacks(SessionHandle *shRaw,
                                               std::weak_ptr<TerminalHandle> weakTh)
{
    ssh::SshChannelCallbacks cb;
    cb.onOpen = [shRaw, weakTh](const ssh::ChannelOpenResult &r) {
        auto th = weakTh.lock();
        if (!th) {
            return;
        }
        auto *evt = new BridgeEvent{EventKind::kTerminalOpen};
        evt->success = r.success;
        evt->text1 = ssh::toString(r.error);
        evt->text2 = r.message;
        SendTerminalEvent(shRaw, th->handle, evt);
        if (!r.success) {
            ScheduleCoreDestroy(th); // 打开失败即终态（不再有 onClose）
        }
    };
    cb.onData = [weakTh](const std::string &data, ssh::ChannelStream /*stream*/) {
        auto th = weakTh.lock();
        if (!th || th->closing.load(std::memory_order_relaxed)) {
            return;
        }
        // 循环线程内 core 不会被并发 reset（destroyCore 任务同线程串行），免锁直读；
        // PTY 通道 stderr 与 stdout 合流，不区分 stream 直接喂 vterm
        auto &core = th->core;
        if (!core || !core->vterm) {
            return;
        }
        core->vterm->feed(data.data(), data.size());
        th->frameSync.publish(*core->vterm);
    };
    cb.onClose = [shRaw, weakTh](const ssh::ChannelCloseInfo &info) {
        auto th = weakTh.lock();
        if (!th) {
            return;
        }
        auto *evt = new BridgeEvent{EventKind::kTerminalClose};
        evt->text1 = ssh::toString(info.reason);
        evt->number = info.exitStatus;
        evt->text2 = info.exitSignal;
        evt->text3 = info.message;
        SendTerminalEvent(shRaw, th->handle, evt);
        ScheduleCoreDestroy(th);
    };
    return cb;
}

// vterm 事件（title/bell/mouseMode 变更）：feed 路径内触发，同在循环线程
void WireVtermCallbacks(SessionHandle *shRaw, std::weak_ptr<TerminalHandle> weakTh,
                        term::VtermBridge &vterm)
{
    vterm.setTitleCallback([shRaw, weakTh](const std::string &title) {
        auto th = weakTh.lock();
        if (!th) {
            return;
        }
        auto *evt = new BridgeEvent{EventKind::kTerminalTitle};
        evt->text1 = title;
        SendTerminalEvent(shRaw, th->handle, evt);
    });
    vterm.setBellCallback([shRaw, weakTh]() {
        auto th = weakTh.lock();
        if (!th) {
            return;
        }
        SendTerminalEvent(shRaw, th->handle, new BridgeEvent{EventKind::kTerminalBell});
    });
    vterm.setMouseModeCallback([shRaw, weakTh](term::MouseMode mode) {
        auto th = weakTh.lock();
        if (!th) {
            return;
        }
        auto *evt = new BridgeEvent{EventKind::kTerminalMouseMode};
        evt->number = static_cast<long>(mode);
        SendTerminalEvent(shRaw, th->handle, evt);
    });
}

// ---------------------------------------------------------------- external buffer（生命周期保护核心）

// 网格存储的 finalize hint：shared_ptr 副本。GC 回收 buffer 时（finalize）
// 释放本副本——native 早已 resize/teardown 的旧内存此刻才真正归还
void GridStorageFinalize(napi_env /*env*/, void * /*finalizeData*/, void *finalizeHint)
{
    delete static_cast<std::shared_ptr<const std::vector<term::Cell>> *>(finalizeHint);
}

void SelfTestFinalize(napi_env /*env*/, void * /*finalizeData*/, void *finalizeHint)
{
    delete static_cast<std::shared_ptr<std::vector<uint8_t>> *>(finalizeHint);
}

// 把网格存储包成 external arraybuffer；失败（R-9 第一道防线）返回 nullptr
napi_value MakeExternalGridView(napi_env env,
                                const std::shared_ptr<const std::vector<term::Cell>> &storage)
{
    if (!storage || storage->empty()) {
        return nullptr;
    }
    napi_value ab = nullptr;
    auto *hint = new std::shared_ptr<const std::vector<term::Cell>>(storage);
    const size_t bytes = storage->size() * sizeof(term::Cell);
    napi_status st = napi_create_external_arraybuffer(
        env, const_cast<term::Cell *>(storage->data()), bytes, GridStorageFinalize, hint, &ab);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "beginFrame: external arraybuffer 创建失败（%{public}d），回落拷贝路径",
                    static_cast<int>(st));
        delete hint;
        return nullptr;
    }
    return ab;
}

// 整屏/区间拷贝进普通 arraybuffer（兜底路径与 dirty 位图共用）
napi_value MakeCopiedArrayBuffer(napi_env env, const void *src, size_t bytes)
{
    void *data = nullptr;
    napi_value ab = nullptr;
    if (napi_create_arraybuffer(env, bytes, &data, &ab) != napi_ok) {
        return nullptr;
    }
    if (bytes > 0 && data != nullptr && src != nullptr) {
        std::memcpy(data, src, bytes);
    }
    return ab;
}

// napi 回调必须返回有效 napi_value：失败语义统一用 JS null（裸 nullptr 是无效句柄）
napi_value MakeNull(napi_env env)
{
    napi_value r = nullptr;
    napi_get_null(env, &r);
    return r;
}

// ---------------------------------------------------------------- napi 方法实现

napi_value AttachTerminal(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t sessionHandle = 0;
    std::string termType;
    uint32_t cols = 0, rows = 0;
    if (argc < 4 || !GetHandleArg(env, argv[0], sessionHandle) ||
        !GetStringArg(env, argv[1], termType) || !GetUint32Arg(env, argv[2], cols) ||
        !GetUint32Arg(env, argv[3], rows) || cols == 0 || rows == 0 || cols > 1000 ||
        rows > 1000) {
        return MakeHandleValue(env, 0);
    }
    auto sh = LookupLive(sessionHandle);
    if (!sh || !sh->session) {
        return MakeHandleValue(env, 0);
    }

    auto th = std::make_shared<TerminalHandle>();
    th->env = env;
    th->session = sh;
    th->sessionHandleId = sessionHandle;
    th->selfTest = std::make_shared<std::vector<uint8_t>>(MakeSelfTestPattern());

    // 装配期单线程（ArkTS 线程）：core 尚未暴露给循环线程，免锁
    auto core = std::make_shared<TerminalHandle::Core>();
    core->vterm = std::make_unique<term::VtermBridge>(static_cast<int>(cols), static_cast<int>(rows));
    WireVtermCallbacks(sh.get(), th, *core->vterm);
    th->frameSync.publish(*core->vterm); // 初始空白屏快照，attach 后即可 beginFrame
    core->channel =
        std::make_unique<ssh::SshChannel>(*sh->session, MakeTerminalCallbacks(sh.get(), th));
    th->core = core;

    // 受理语义同 N11 openShell：会话须 established；受理后结果经 terminalOpen 事件
    ssh::PtySpec pty;
    pty.termType = termType;
    pty.cols = cols;
    pty.rows = rows;
    if (!core->channel->openShell(std::move(pty))) {
        // 未受理：无任何回调将触发（channel.h 契约）；th 从未登记，随局部
        // shared_ptr 析构（kIdle 通道未持 libssh2 句柄，析构静默安全）
        return MakeHandleValue(env, 0);
    }

    const uint64_t h = g_termTable.insert(th);
    th->handle = h;
    {
        std::lock_guard<std::mutex> lock(sh->terminalsMutex);
        sh->terminals.emplace(h, th);
    }
    OH_LOG_INFO(LOG_APP, "attachTerminal: session=%{public}llu terminal=%{public}llu",
                (unsigned long long)sessionHandle, (unsigned long long)h);
    return MakeHandleValue(env, h);
}

napi_value DetachTerminal(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], h)) {
        return MakeBool(env, false);
    }
    auto th = g_termTable.erase(h);
    if (!th) {
        return MakeBool(env, false); // 幂等：不存在/已随会话回收视为已关闭
    }
    th->closing.store(true, std::memory_order_relaxed);
    // 本体留在会话 terminals 表：通道 close 的终态回调里编排 Core 销毁；
    // 会话已 teardown 的场景由 terminals.clear() 兜底（internal.h 头注）
    if (auto core = th->coreCopy()) {
        core->channel->close(); // 任意线程可调、幂等
    }
    return MakeBool(env, true);
}

// beginFrame：拷出帧快照并组装 napi 对象（ArkTS 线程，同步返回）。
// external 创建失败自动回落整屏拷贝（gridZeroCopy=false）
napi_value BeginFrame(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], h)) {
        return MakeNull(env);
    }
    auto th = LookupTerminal(h);
    if (!th) {
        return MakeNull(env);
    }
    const term::GridFrame frame = th->frameSync.snapshot();

    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetNumProp(env, obj, "revision", static_cast<double>(frame.revision));
    SetNumProp(env, obj, "cols", frame.cols);
    SetNumProp(env, obj, "rows", frame.rows);
    SetNumProp(env, obj, "cursorRow", frame.cursorRow);
    SetNumProp(env, obj, "cursorCol", frame.cursorCol);
    SetBoolProp(env, obj, "cursorVisible", frame.cursorVisible);
    SetBoolProp(env, obj, "altScreen", frame.altScreen);
    SetNumProp(env, obj, "mouseMode", static_cast<double>(frame.mouseMode));
    SetNumProp(env, obj, "bellCount", static_cast<double>(frame.bellCount));
    SetNumProp(env, obj, "scrollbackOldest", static_cast<double>(frame.scrollbackOldest));
    SetNumProp(env, obj, "scrollbackTotal", static_cast<double>(frame.scrollbackTotal));

    // 网格主路径：external 零拷贝；失败回落整屏拷贝
    napi_value grid = MakeExternalGridView(env, frame.storage);
    bool zeroCopy = (grid != nullptr);
    if (!zeroCopy && frame.storage && !frame.storage->empty()) {
        grid = MakeCopiedArrayBuffer(env, frame.storage->data(), frame.byteSize());
    }
    if (grid != nullptr) {
        napi_set_named_property(env, obj, "grid", grid);
        SetBoolProp(env, obj, "gridZeroCopy", zeroCopy);
    } else {
        SetBoolProp(env, obj, "gridZeroCopy", false);
    }

    // 脏行位图：普通 arraybuffer 拷贝（语义为该帧时刻切片，见 frame_sync.h）
    if (!frame.dirty.empty()) {
        napi_value dirty =
            MakeCopiedArrayBuffer(env, frame.dirty.data(), frame.dirty.size() * sizeof(uint64_t));
        if (dirty != nullptr) {
            napi_set_named_property(env, obj, "dirty", dirty);
        }
    }
    return obj;
}

napi_value EndFrame(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    double seen = 0;
    if (argc < 2 || !GetHandleArg(env, argv[0], h) ||
        napi_get_value_double(env, argv[1], &seen) != napi_ok || seen < 0) {
        return MakeBool(env, false);
    }
    auto th = LookupTerminal(h);
    if (!th || th->closing.load(std::memory_order_relaxed)) {
        return MakeBool(env, false);
    }
    const uint64_t seenRevision = static_cast<uint64_t>(seen);
    // post 进循环线程做「revision 比对 + 清脏」——与 feed 串行，无并发；
    // weak 捕获：晚于 loop 停的任务会被回收，强捕获会形成滞留环（头注）
    std::weak_ptr<TerminalHandle> weakTh = th;
    th->session->thread.post([weakTh, seenRevision]() {
        auto th2 = weakTh.lock();
        if (!th2) {
            return;
        }
        auto core = th2->coreCopy();
        if (!core || !core->vterm) {
            return; // core 已销毁：网格冻结，脏位图无消费意义
        }
        th2->frameSync.endFrame(*core->vterm, seenRevision);
    });
    return MakeBool(env, true);
}

napi_value GetRevision(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    double result = -1;
    if (argc >= 1 && GetHandleArg(env, argv[0], h)) {
        if (auto th = LookupTerminal(h)) {
            result = static_cast<double>(th->frameSync.publishedRevision());
        }
    }
    napi_value r = nullptr;
    napi_create_double(env, result, &r);
    return r;
}

// R-9 探测点：返回自检块的 external 视图；失败返回 null（ArkTS 侧据此切兜底）
napi_value SelfTestGrid(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    if (argc < 1 || !GetHandleArg(env, argv[0], h)) {
        return MakeNull(env);
    }
    auto th = LookupTerminal(h);
    if (!th || !th->selfTest) {
        return MakeNull(env);
    }
    napi_value ab = nullptr;
    auto *hint = new std::shared_ptr<std::vector<uint8_t>>(th->selfTest);
    napi_status st = napi_create_external_arraybuffer(
        env, th->selfTest->data(), th->selfTest->size(), SelfTestFinalize, hint, &ab);
    if (st != napi_ok) {
        OH_LOG_WARN(LOG_APP, "selfTestGrid: external arraybuffer 创建失败（%{public}d）",
                    static_cast<int>(st));
        delete hint;
        return MakeNull(env);
    }
    return ab;
}

// 兜底路径：从最新发布快照拷贝 [startRow, startRow+count) 行区间
//（拷快照而非活网格：与 beginFrame 同一数据源，core 销毁后仍可用）
napi_value CopyGridRows(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    uint32_t startRow = 0, count = 0;
    if (argc < 3 || !GetHandleArg(env, argv[0], h) || !GetUint32Arg(env, argv[1], startRow) ||
        !GetUint32Arg(env, argv[2], count)) {
        return MakeNull(env);
    }
    auto th = LookupTerminal(h);
    if (!th) {
        return MakeNull(env);
    }
    const term::GridFrame frame = th->frameSync.snapshot();
    if (!frame.storage || startRow >= static_cast<uint32_t>(frame.rows) || count == 0) {
        return MakeNull(env);
    }
    const uint32_t clamped = std::min(count, static_cast<uint32_t>(frame.rows) - startRow);
    const size_t rowCells = static_cast<size_t>(frame.cols);
    const term::Cell *src = frame.storage->data() + static_cast<size_t>(startRow) * rowCells;
    napi_value ab = MakeCopiedArrayBuffer(env, src, clamped * rowCells * sizeof(term::Cell));
    return ab != nullptr ? ab : MakeNull(env);
}

// 回滚窗口拷贝：absoluteIndex ∈ [scrollbackOldest, scrollbackTotal)，
// 返回 count × cols × 16B（越界行填零值 Cell）；回滚量小频次低，不做零拷贝
napi_value GetScrollbackWindow(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    double start = 0;
    uint32_t count = 0;
    if (argc < 3 || !GetHandleArg(env, argv[0], h) ||
        napi_get_value_double(env, argv[1], &start) != napi_ok || start < 0 ||
        !GetUint32Arg(env, argv[2], count) || count == 0 || count > 1000) {
        return MakeNull(env);
    }
    auto th = LookupTerminal(h);
    if (!th) {
        return MakeNull(env);
    }
    auto core = th->coreCopy(); // 副本保活到拷贝完成（销毁点在循环线程，见头注）
    if (!core || !core->vterm) {
        return MakeNull(env);
    }
    const auto &sb = core->vterm->scrollback();
    // 列宽读取与整段拷出在同一把锁内完成（T3 审查修复）：若拆成 cols() + copyWindow
    // 两步，两锁之间 resizeCols 改列宽会让拷贝按新列宽写旧尺寸缓冲（堆越界写）
    std::vector<term::Cell> out;
    sb.copyWindowWithCols(static_cast<uint64_t>(start), count, out);
    napi_value ab = MakeCopiedArrayBuffer(env, out.data(), out.size() * sizeof(term::Cell));
    return ab != nullptr ? ab : MakeNull(env);
}

napi_value WriteTerminal(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    std::string bytes;
    if (argc < 2 || !GetHandleArg(env, argv[0], h) || !GetBytesArg(env, argv[1], bytes)) {
        return MakeBool(env, false);
    }
    auto th = LookupTerminal(h);
    if (!th || th->closing.load(std::memory_order_relaxed)) {
        return MakeBool(env, false);
    }
    auto core = th->coreCopy();
    if (!core || !core->channel) {
        return MakeBool(env, false);
    }
    // 背压语义同 N11 write：待发队列超限整次拒收
    return MakeBool(env, core->channel->write(bytes.data(), bytes.size()));
}

napi_value ResizeTerminal(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    uint32_t cols = 0, rows = 0;
    if (argc < 3 || !GetHandleArg(env, argv[0], h) || !GetUint32Arg(env, argv[1], cols) ||
        !GetUint32Arg(env, argv[2], rows) || cols == 0 || rows == 0 || cols > 1000 ||
        rows > 1000) {
        return MakeBool(env, false);
    }
    auto th = LookupTerminal(h);
    if (!th || th->closing.load(std::memory_order_relaxed)) {
        return MakeBool(env, false);
    }
    // vterm resize 必须在循环线程（与 feed 互斥）；通道 request_pty_size 一并
    // 在同任务内完成（N10 的在途合并语义由 SshChannel 保证）。weak 捕获防滞留环
    std::weak_ptr<TerminalHandle> weakTh = th;
    th->session->thread.post([weakTh, cols, rows]() {
        auto th2 = weakTh.lock();
        if (!th2) {
            return;
        }
        auto core = th2->coreCopy();
        if (!core || !core->vterm) {
            return;
        }
        core->vterm->resize(static_cast<int>(cols), static_cast<int>(rows));
        if (core->channel) {
            core->channel->resize(cols, rows);
        }
        // 网格已换入新存储：立即发布新快照（旧存储由既有 external buffer 保活）
        th2->frameSync.publish(*core->vterm);
    });
    return MakeBool(env, true);
}

} // namespace

void ForgetTerminal(uint64_t terminalHandle)
{
    g_termTable.erase(terminalHandle);
}

void RegisterTerminalBridge(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"attachTerminal", nullptr, AttachTerminal, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"detachTerminal", nullptr, DetachTerminal, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"beginFrame", nullptr, BeginFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"endFrame", nullptr, EndFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRevision", nullptr, GetRevision, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selfTestGrid", nullptr, SelfTestGrid, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"copyGridRows", nullptr, CopyGridRows, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getScrollbackWindow", nullptr, GetScrollbackWindow, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"writeTerminal", nullptr, WriteTerminal, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resizeTerminal", nullptr, ResizeTerminal, nullptr, nullptr, nullptr, napi_default,
         nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterTerminalBridge: napi_define_properties failed");
    }
}

} // namespace bridge
} // namespace sshclient
