/**
 * ScrollbackBuffer —— 行级回滚环形缓冲（任务 T2，DESIGN §4.4 / §2.2）。
 *
 * 语义与约定：
 * - 每行 = 该行全部 Cell 的连续拷贝（定长 cols() 个，16B/格），槽位物理布局为
 *   capacity() × cols() 的连续内存，构造时一次分配、之后不再增长——内存有界性
 *   由「预分配 + 定长」保证：推多少行都只占 capacity × cols × 16 字节。
 * - 环形覆盖：absoluteIndex（推入序号，从 0 起）取模 capacity 得物理槽位；
 *   推满后新行覆盖最老行。有效窗口恒为 [oldestIndex(), totalPushed())，
 *   getLine / copyWindow 均 O(1) 定位（取模 + 指针偏移，无查找）。
 * - totalPushed() 对 pushLine 单调递增；唯一回退路径是 popLine（行被拉回主屏、
 *   不再属于回滚，计数同步 -1，保持有效窗口 = [oldestIndex(), totalPushed())
 *   连续无洞）。clear() 只清有效行数、不动 totalPushed——清空后有效窗口为空，
 *   之后新推入行沿用原序号继续递增。
 * - 行宽跟随屏幕 cols：resize 时由 VtermBridge 调 resizeCols 全量重排
 *   （宽改窄截断、窄改宽补空白格）。采用「resize 时一次性重排」而非「查询时按
 *   当前 cols 截断/补空」：定长槽位才能 O(1)，且 resize 是低频操作，
 *   容量 × cols × 16B 级的一次性拷贝可忽略。重排后存量行与新行统一为新宽度，
 *   查询永远按定长行返回。
 * - alt-screen：libvterm 0.3.3 屏幕层只在主屏（PRIMARY buffer）全宽上滚时才回调
 *   sb_pushline（screen.c moverect_internal 的 BUFIDX_PRIMARY 检查），alt 屏滚动
 *   天然不进本缓冲；依据 DESIGN §4.4：alt-screen 下滚动改发方向键/滚轮序列，
 *   回滚缓冲属于主屏。
 *
 * 本文件是纯逻辑实现：只依赖 C++ 标准库与 grid.h（Cell 布局），
 * 禁止 include <napi/native_api.h> / <hilog/log.h> / <vterm.h>。
 * 同时被 OHOS 产物（../CMakeLists.txt）与宿主机单测（../tests/CMakeLists.txt）编译。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "grid.h"

namespace sshclient {
namespace term {

class ScrollbackBuffer {
public:
    // TASKS T2：默认 5000 行、上限 50000（构造钳制到 [1, kMaxCapacity]）
    static constexpr size_t kDefaultCapacity = 5000;
    static constexpr size_t kMaxCapacity = 50000;

    ScrollbackBuffer(int cols, size_t capacity = kDefaultCapacity);

    int cols() const { return cols_; }
    size_t capacity() const { return capacity_; }
    size_t size() const { return size_; } // 当前有效行数 = min(totalPushed, capacity)

    // 推入计数（有效窗口右端）；popLine 弹回主屏时同步 -1，见头注释
    uint64_t totalPushed() const { return totalPushed_; }
    // 有效窗口左端（最老可查行的 absoluteIndex）
    uint64_t oldestIndex() const { return totalPushed_ - size_; }

    // 推入一行到环形尾：拷贝 min(count, cols) 格，不足补零值 Cell（codepoint 0）；
    // count 超过 cols 截断（调用方 bug 的防御，正常路径 count == cols）。O(1)。
    void pushLine(const Cell *cells, size_t count);

    // 窗口查询：absoluteIndex ∈ [oldestIndex(), totalPushed())，O(1)。
    // 越界返回 nullptr（定义行为：调用方跨 NAPI，窗口边界探测是正常用法）。
    // 返回指针指向环形槽位内部内存：下一次 pushLine/popLine/clear/resizeCols 后即失效，
    // 调用方不得跨 feed 持有（要留存走 copyWindow 拷出）
    const Cell *getLine(uint64_t absoluteIndex) const;

    // 批量窗口拷贝：out[i] 对应 absoluteIndex = startIndex + i，恒写满 count 行；
    // 落在有效窗口外的项填零值 Cell（codepoint 0）。返回实际拷贝的有效行数。
    // out 至少 count × cols() 个 Cell。
    size_t copyWindow(uint64_t startIndex, size_t count, Cell *out) const;

    // 弹出最新行（libvterm sb_popline：resize 行数增大时回填屏幕顶部）：
    // 拷贝到 out（至少 cols() 格）后从缓冲移除；空缓冲返回 false 且不写 out。
    bool popLine(Cell *out);

    // 清空有效行（DEC ED 3 / 显式清回滚）；totalPushed 不动，见头注释
    void clear();

    // 列宽变化重排：逐槽截断（newCols < cols）或补 blank（newCols > cols）；
    // 物理槽位布局不变，absoluteIndex 语义不受影响。blank 由调用方按当前默认色给。
    void resizeCols(int newCols, const Cell &blank);

    // 内部存储字节数：恒等于 capacity × cols × sizeof(Cell)（预分配定长，内存上界）
    size_t storageBytes() const { return cells_.size() * sizeof(Cell); }

private:
    size_t slotOf(uint64_t absoluteIndex) const
    {
        return static_cast<size_t>(absoluteIndex % static_cast<uint64_t>(capacity_));
    }

    int cols_;
    size_t capacity_;
    size_t size_ = 0;
    uint64_t totalPushed_ = 0;
    std::vector<Cell> cells_; // capacity × cols，槽位 = absoluteIndex % capacity
};

} // namespace term
} // namespace sshclient
