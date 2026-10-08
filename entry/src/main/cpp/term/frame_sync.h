/**
 * FrameSync —— T3「零拷贝快照 NAPI」的帧同步发布槽（纯逻辑，宿主可测）。
 *
 * 线程模型：单生产者（会话循环线程 publish/endFrame）单消费者
 * （ArkTS 线程 snapshot/publishedRevision）。两侧经一把短锁同步；
 * 临界区 = 一次结构体拷贝（含 dirty 位图 vector 拷贝，rows/64 个 u64，
 * 数十字节），不阻塞任一侧的实时路径。
 *
 * 帧协议（与 ArkTS 侧 SshTerminal.ets 对应，改一侧必须同步另一侧）：
 *   1. ArkTS 调 beginFrame → native snapshot() 拷出当前 GridFrame：
 *      grid 内存以 external arraybuffer 零拷贝暴露（storage 保活，见下），
 *      dirty 位图为 publish 时刻的拷贝（普通 arraybuffer，极小）；
 *   2. ArkTS 按 dirty 渲染脏行（或读 cursor/几何信息）；
 *   3. ArkTS 调 endFrame(seenRevision) → post 进循环线程执行：
 *      网格 revision 仍等于 seenRevision ⇒ 帧内无并发写入，清脏位图并重新
 *      发布（清空后的位图对下帧可见）；不一致 ⇒ 期间又脏了，保留脏位，
 *      下帧 beginFrame 仍会拿到这些行（自愈）。
 *   一致性兜底：快照读取与 feed 写入天然并发（ArkTS 读、循环线程写），
 *   单格 16 字节读取可能撕裂——revision 不一致时 endFrame 丢弃清脏，
 *   脏行下帧重绘修正，撕裂内容最多在屏一帧（终端渲染通用取舍）。
 *
 * 内存安全（验收标准「native 释放后 ArkTS 再读不崩」的根据）：
 *   GridFrame::storage 与 CellGrid 共享网格存储所有权（grid.h「存储所有权」）。
 *   resize/setDefaultColors 后 CellGrid 换入新存储，旧存储由本槽与 ArkTS 侧
 *   external buffer 的 finalize 副本继续保活；旧 buffer 读到冻结的旧内容
 *   （尺寸以该帧快照的 cols/rows 为准），永不读到已释放内存。
 *
 * 本文件是纯逻辑：只依赖 grid.h / vterm_screen.h，禁止 include
 * <napi/native_api.h> / <hilog/log.h>。
 */
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "grid.h"
#include "vterm_screen.h"

namespace sshclient {
namespace term {

// 一帧快照描述：ArkTS beginFrame 拿到的全部数据（字段含义见各注释）。
// 拷贝开销：shared_ptr + 标量 + dirty vector（数十字节），可忽略。
struct GridFrame {
    // 网格存储保活句柄：publish 时刻 CellGrid 的存储 vector。
    // 字节布局即 Cell 数组（16B/格，行优先，grid.h 头注）；
    // byteSize = cols * rows * sizeof(Cell)
    std::shared_ptr<const std::vector<Cell>> storage;
    uint64_t revision = 0; // publish 时刻的网格修订号（帧有效性判据）
    int cols = 0;
    int rows = 0;
    int cursorRow = 0;
    int cursorCol = 0;
    bool cursorVisible = true;
    bool altScreen = false;                    // 备选缓冲激活中（回滚/滚轮行为切换依据）
    MouseMode mouseMode = MouseMode::kNone;    // 鼠标上报模式（1000/1002/1003）
    uint64_t bellCount = 0;                    // 累计 bell 次数（UI 也可走 terminalBell 事件）
    uint64_t scrollbackOldest = 0;             // 回滚有效窗口 [oldest, total)
    uint64_t scrollbackTotal = 0;
    uint64_t scrollbackEpoch = 0;              // 回滚重排代际（reflow/clear +1，绝对行号失效判据）
    bool applicationCursorKeys = false;        // DECCKM（vterm_keyboard_key 探测）
    bool bracketedPaste = false;               // DECSET 2004
    int cursorShape = 0;                       // DECSCUSR 覆盖：0 未覆盖 / 1 块 / 2 下划线 / 3 竖线
    int cursorBlink = -1;                      // DECSCUSR 覆盖：-1 未覆盖 / 0 不闪 / 1 闪
    std::vector<uint64_t> dirty;               // 脏行位图快照（每行 1 bit，同 CellGrid 布局）

    // 网格字节数（storage 为空时为 0）
    size_t byteSize() const { return storage ? storage->size() * sizeof(Cell) : 0; }
};

class FrameSync {
public:
    FrameSync() = default;

    FrameSync(const FrameSync &) = delete;
    FrameSync &operator=(const FrameSync &) = delete;

    // ---- 生产者侧（仅会话循环线程调用）----

    // 从 VtermBridge 当前状态发布快照。调用时机：feed 结束后、resize 后、
    // endFrame 清脏后——即「网格可能被改动」的每个循环线程事件点
    void publish(const VtermBridge &vterm);

    // endFrame 协议（循环线程执行）：见文件头「帧协议」第 3 步。
    // 返回 true = 帧有效且脏位图已清；false = 期间又脏了（未清，下帧重绘）
    bool endFrame(VtermBridge &vterm, uint64_t seenRevision);

    // ---- 消费者侧（ArkTS 线程；与生产者并发安全）----

    // 原子拷出当前快照
    GridFrame snapshot() const;

    // 高频轮询路径：当前已发布 revision（帧循环先比对本地值再决定 beginFrame）
    uint64_t publishedRevision() const { return revisionMirror_.load(std::memory_order_acquire); }

private:
    mutable std::mutex mutex_;
    GridFrame frame_;
    // revision 的无锁镜像（publish 时同步）：snapshot 外的轻量轮询通道
    std::atomic<uint64_t> revisionMirror_{0};
};

} // namespace term
} // namespace sshclient
