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
 * - 行宽跟随屏幕 cols：resize 时由 VtermBridge 调 reflow 按软换行标记重排（rewrap）
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
 *
 * 线程安全（T3 起）：全部公共方法内部持锁，任意线程可调——
 * 写路径（pushLine/popLine/clear/resizeCols）在会话循环线程，T3 的
 * getScrollbackWindow 经 copyWindow 在 ArkTS 线程读。临界区为整段 memcpy
 * （百行级 ≈ 数十微秒），循环线程被阻塞的时长可忽略。
 * 例外：getLine 返回内部槽位指针，锁管不住返回值的使用期——保持原契约
 * 「下一次写后即失效」，只允许循环线程/测试这类知根底的调用方使用。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <mutex>
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

    // 访问器同样持锁（T3：ArkTS 线程经 getScrollbackWindow/发布快照读取，
    // 与循环线程的 pushLine/resizeCols 并发）
    int cols() const { std::lock_guard<std::mutex> lock(mutex_); return cols_; }
    size_t capacity() const { std::lock_guard<std::mutex> lock(mutex_); return capacity_; }
    size_t size() const { std::lock_guard<std::mutex> lock(mutex_); return size_; } // 当前有效行数 = min(totalPushed, capacity)

    // 推入计数（有效窗口右端）；popLine 弹回主屏时同步 -1，见头注释
    uint64_t totalPushed() const { std::lock_guard<std::mutex> lock(mutex_); return totalPushed_; }
    // 有效窗口左端（最老可查行的 absoluteIndex）
    uint64_t oldestIndex() const { std::lock_guard<std::mutex> lock(mutex_); return oldestIndexLocked(); }

    // 推入一行到环形尾：拷贝 min(count, cols) 格，不足补零值 Cell（codepoint 0）；
    // count 超过 cols 截断（调用方 bug 的防御，正常路径 count == cols）。O(1)。
    // wrapsNext：该行是软换行、续接下一行（写入行末格 reserved 的 kReservedWrapsNext 位）。
    void pushLine(const Cell *cells, size_t count, bool wrapsNext = false);

    // 窗口查询：absoluteIndex ∈ [oldestIndex(), totalPushed())，O(1)。
    // 越界返回 nullptr（定义行为：调用方跨 NAPI，窗口边界探测是正常用法）。
    // 返回指针指向环形槽位内部内存：下一次 pushLine/popLine/clear/resizeCols 后即失效，
    // 调用方不得跨 feed 持有（要留存走 copyWindow 拷出）。
    // 线程契约：锁只保护本调用本身，返回值使用期不受保护——仅循环线程/测试可用
    const Cell *getLine(uint64_t absoluteIndex) const;

    // 批量窗口拷贝：out[i] 对应 absoluteIndex = startIndex + i，恒写满 count 行；
    // 落在有效窗口外的项填零值 Cell（codepoint 0）。返回实际拷贝的有效行数。
    // out 至少 count × cols() 个 Cell。
    size_t copyWindow(uint64_t startIndex, size_t count, Cell *out) const;

    // 组合接口（T3 审查修复）：列宽读取与整段拷贝在同一把锁内完成，返回实际列宽，
    // out 被精确调整为 count × 返回列宽（语义同 copyWindow：恒写满、窗口外填零）。
    // 跨线程调用方必须用它而非「cols() + copyWindow」两步——两步之间 resizeCols
    // 改列宽会让 copyWindow 按新列宽写旧尺寸的缓冲，构成堆越界写（TOCTOU）。
    int copyWindowWithCols(uint64_t startIndex, size_t count, std::vector<Cell> &out) const;

    // 弹出最新行（libvterm sb_popline：resize 行数增大时回填屏幕顶部）：
    // 拷贝到 out（至少 cols() 格）后从缓冲移除；空缓冲返回 false 且不写 out。
    bool popLine(Cell *out);

    // 清空有效行（DEC ED 3 / 显式清回滚）；totalPushed 不动，见头注释
    void clear();

    // 列宽变化重排：逐槽截断（newCols < cols）或补 blank（newCols > cols）；
    // 物理槽位布局不变，absoluteIndex 语义不受影响。blank 由调用方按当前默认色给。
    void resizeCols(int newCols, const Cell &blank);

    // 列宽变化重排（reflow）：按行末 kReservedWrapsNext 把软换行的物理行拼回逻辑行，
    // 再按 newCols 重新折行（宽字符不跨行：放不下时行尾留空位换行，与 libvterm 一致）。
    // 逻辑行尾部空白（码点 0 且无反显）裁掉后补 blank。行数变化后有效窗口左端
    // （oldestIndex）不变、totalPushed 随行数增减；超出容量时丢最老行。
    // 绝对行号在 reflow 前后不再对应同一内容：epoch() +1 通知上层失效缓存/选区。
    // newCols < 2 时退化为 resizeCols（无法容纳宽字符）。
    void reflow(int newCols, const Cell &blank);

    // 内容重排代际：reflow / clear 时 +1（上层据此判断绝对行号是否仍可比）
    uint64_t epoch() const { std::lock_guard<std::mutex> lock(mutex_); return epoch_; }

    // 内部存储字节数：恒等于 capacity × cols × sizeof(Cell)（预分配定长，内存上界）
    size_t storageBytes() const { std::lock_guard<std::mutex> lock(mutex_); return cells_.size() * sizeof(Cell); }

private:
    size_t slotOf(uint64_t absoluteIndex) const
    {
        return static_cast<size_t>(absoluteIndex % static_cast<uint64_t>(capacity_));
    }
    // 调用方已持锁前提下的有效窗口左端（方法内部复用，避免递归加锁）
    uint64_t oldestIndexLocked() const { return totalPushed_ - size_; }
    // 调用方已持锁前提下的窗口拷贝主体（copyWindow / copyWindowWithCols 复用）
    size_t copyWindowLocked(uint64_t startIndex, size_t count, Cell *out) const;

    mutable std::mutex mutex_; // 全方法级保护（T3 跨线程拷贝，见头注「线程安全」）
    int cols_;
    size_t capacity_;
    size_t size_ = 0;
    uint64_t totalPushed_ = 0;
    uint64_t epoch_ = 0;
    std::vector<Cell> cells_; // capacity × cols，槽位 = absoluteIndex % capacity
};

} // namespace term
} // namespace sshclient
