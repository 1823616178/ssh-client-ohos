/**
 * NAPI 终端桥接 —— 任务 T3「零拷贝快照 NAPI」（DESIGN §2.2，依赖 T1 网格与 N11 会话桥）。
 *
 * 对外模型（与 types/libssh_core/index.d.ts 一致；帧协议的 ArkTS 侧见
 * ets/napi/SshTerminal.ets，改一侧必须同步另一侧）：
 *
 *   attachTerminal(sessionHandle, termType, cols, rows) → terminalHandle
 *     在会话上创建终端：VtermBridge + 绑定一个新 shell 通道（PTY），
 *     通道 onData → vterm feed → FrameSync publish 全部发生在会话循环线程，
 *     终端字节流不再经 channelData TSFN 上抛（零 ArkTS 参与的数据面）。
 *     返回 >0 = 已受理（通道打开结果经 terminalOpen 事件回报）；0 = 未受理。
 *
 *   beginFrame(terminalHandle) → 帧快照对象 | null（ArkTS 线程，同步返回）
 *     { grid, gridZeroCopy, revision, cols, rows, cursorRow, cursorCol,
 *       cursorVisible, altScreen, mouseMode, bellCount,
 *       scrollbackOldest, scrollbackTotal, dirty }
 *     - grid：主路径为 napi_create_external_arraybuffer 的零拷贝视图
 *       （直接映射 native 网格存储；R-9）。创建失败自动回落为整屏拷贝
 *       （普通 arraybuffer）并置 gridZeroCopy=false——双路径设计的第一道防线；
 *     - dirty：脏行位图快照（普通 arraybuffer 拷贝，u64 字数组，每行 1 bit，
 *       每帧数十~数百字节，不做零拷贝——语义必须是「该帧时刻的切片」，
 *       external 暴露一个会被 native 随时清零的位图反而脆弱，见 frame_sync.h）；
 *     - 网格读取与 feed 写入天然并发：单格 16 字节读取可能撕裂，
 *       revision 机制兜底（见 endFrame），撕裂内容最多在屏一帧。
 *
 *   endFrame(terminalHandle, seenRevision) → boolean（受理语义）
 *     post 进循环线程：网格 revision 仍等于 seenRevision ⇒ 清脏位图并重新发布；
 *     不一致 ⇒ 期间又脏了，保留脏位（下帧 beginFrame 仍会拿到这些行，自愈）。
 *     帧循环的推荐用法：每帧先 getRevision 比对本地值，变了才 beginFrame。
 *
 *   生命周期保护（验收标准「native 释放后 ArkTS 再读不崩」的根据）：
 *     网格存储为 shared_ptr（term/grid.h「存储所有权」）。beginFrame 把当前
 *     存储包成 external arraybuffer 时，finalize hint 持有一份 shared_ptr
 *     副本——native 侧 resize/closeTerminal/会话 teardown 都只减引用，
 *     旧内存由 ArkTS GC 触发 finalize 才真正回收。ArkTS 持有旧 buffer 读到
 *     的是冻结的旧内容（尺寸以该帧 cols/rows 为准），永不读到已释放内存。
 *
 *   R-9 双路径（external arraybuffer 在 ArkTS 运行时的可用性待真机 spike N3b）：
 *     第一道防线（native）：beginFrame 创建 external 失败自动回落整屏拷贝；
 *     第二道防线（ArkTS）：attach 后调 selfTestGrid 拿到 32 字节已知模式的
 *     external 视图，DataView 读回比对——napi 返回 ok 但字节不一致的场景
 *     由 ArkTS 探测兜底，永久切 copyGridRows 路径（SshTerminal.ets）。
 *
 *   其余方法：
 *     selfTestGrid(handle)                    → 自检缓冲的 external 视图（32B 已知模式）
 *     getRevision(handle)                     → 已发布 revision（高频轮询，无锁镜像）
 *     copyGridRows(handle, startRow, count)   → 兜底路径：从最新发布快照拷贝行区间
 *     getScrollbackWindow(handle, start, n)   → 回滚窗口拷贝（普通 arraybuffer）
 *     writeTerminal(handle, data)             → 转发 shell 通道 write（背压同 N11）
 *     resizeTerminal(handle, cols, rows)      → post 循环线程：vterm resize +
 *                                               通道 request_pty_size（N10）
 *     detachTerminal(handle)                  → 幂等；摘句柄表 + 关通道，
 *                                               本体随终态回调/会话回收（internal.h 头注）
 *
 *   终端事件（经 N11 的 stateTsfn 随会话 onEvent 上抛，均带 terminal 句柄）：
 *     terminalOpen / terminalClose / terminalBell / terminalTitle / terminalMouseMode。
 *
 * 线程纪律（满足 SshChannel/VtermBridge 契约的关键）：
 *   - vterm/channel 只在会话循环线程使用与销毁（Core 销毁任务由通道终态回调
 *     触发——该回调只在循环线程触发，故销毁任务不会撞上「loop 停后滞留」；
 *     会话 teardown 时 Terminals 表统一回收是兜底路径，见 internal.h）；
 *   - ArkTS 线程的 write/回滚拷贝经 coreMutex 拿 Core 的 shared_ptr 副本，
 *     保活到调用返回；Core reset（循环线程）与副本析构（任意线程）都满足
 *     「通道已终态才析构」约定；
 *   - ArkTS 线程 post 进循环的任务一律 weak 捕获 TerminalHandle——
 *     强捕获会在「post 晚于 loop 停」时形成 th→sh→loop→任务→th 滞留环。
 */
#pragma once

#include "napi/native_api.h"

namespace sshclient {
namespace bridge {

// 向 exports 注册全部终端桥接方法。由 napi_init.cpp 的模块 Init 调用。
void RegisterTerminalBridge(napi_env env, napi_value exports);

} // namespace bridge
} // namespace sshclient
