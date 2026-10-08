/**
 * FrameSync 实现 —— 见 frame_sync.h 头注释（线程模型 / 帧协议 / 内存安全）。
 */
#include "frame_sync.h"

namespace sshclient {
namespace term {

void FrameSync::publish(const VtermBridge &vterm)
{
    const CellGrid &grid = vterm.grid();
    const ScrollbackBuffer &sb = vterm.scrollback();

    GridFrame next;
    next.storage = grid.cellsStorage(); // shared_ptr 拷贝：旧存储随快照保活
    next.revision = grid.revision();
    next.cols = grid.cols();
    next.rows = grid.rows();
    next.cursorRow = vterm.cursorRow();
    next.cursorCol = vterm.cursorCol();
    next.cursorVisible = vterm.cursorVisible();
    next.altScreen = vterm.altScreenActive();
    next.mouseMode = vterm.mouseMode();
    next.bellCount = vterm.bellCount();
    next.scrollbackOldest = sb.oldestIndex();
    next.scrollbackTotal = sb.totalPushed();
    next.scrollbackEpoch = sb.epoch();
    next.applicationCursorKeys = vterm.applicationCursorKeys();
    next.bracketedPaste = vterm.bracketedPaste();
    next.cursorShape = vterm.cursorShapeOverride();
    next.cursorBlink = vterm.cursorBlinkOverride();
    next.dirty = grid.dirtyBitmap(); // 数十字节拷贝（rows/64 个 u64）

    {
        std::lock_guard<std::mutex> lock(mutex_);
        frame_ = std::move(next);
    }
    // 镜像在锁外写：publishedRevision 只作「是否该 beginFrame」的轮询提示，
    // 与 frame_ 内容的严格同序由 beginFrame 内的锁保证，这里无需同临界区
    revisionMirror_.store(next.revision, std::memory_order_release);
}

bool FrameSync::endFrame(VtermBridge &vterm, uint64_t seenRevision)
{
    // 仅循环线程调用：与 feed/resize 串行，期间 grid 不会被并发写
    if (vterm.grid().revision() != seenRevision)
        return false; // 帧内又有写入：保留脏位，下帧重绘（自愈，见头注）
    vterm.grid().clearDirty();
    publish(vterm); // 清空后的位图立刻对下帧可见
    return true;
}

GridFrame FrameSync::snapshot() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return frame_; // 结构体拷贝：shared_ptr + 标量 + dirty vector（数十字节）
}

} // namespace term
} // namespace sshclient
