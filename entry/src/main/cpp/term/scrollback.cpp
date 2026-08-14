/**
 * ScrollbackBuffer 实现 —— 见 scrollback.h 头注释。
 */
#include "scrollback.h"

#include <algorithm>
#include <cassert>
#include <cstring>

namespace sshclient {
namespace term {

ScrollbackBuffer::ScrollbackBuffer(int cols, size_t capacity)
    : cols_(cols),
      capacity_(std::max<size_t>(1, std::min(capacity, kMaxCapacity)))
{
    assert(cols > 0);
    // 预分配全部槽位：之后 pushLine 只覆写不增长，storageBytes() 恒定
    cells_.assign(capacity_ * static_cast<size_t>(cols_), Cell{});
}

void ScrollbackBuffer::pushLine(const Cell *cells, size_t count)
{
    std::lock_guard<std::mutex> lock(mutex_);
    Cell *slot = &cells_[slotOf(totalPushed_) * static_cast<size_t>(cols_)];
    const size_t n = std::min(count, static_cast<size_t>(cols_));
    std::memcpy(slot, cells, n * sizeof(Cell));
    // 防御性补空（正常路径 count == cols_）：零值 Cell，codepoint 0 = 空
    for (size_t c = n; c < static_cast<size_t>(cols_); ++c)
        slot[c] = Cell{};

    ++totalPushed_;
    if (size_ < capacity_)
        ++size_;
    // size_ == capacity_ 时最老行被本次覆写，有效窗口右移一格，无需额外处理
}

const Cell *ScrollbackBuffer::getLine(uint64_t absoluteIndex) const
{
    // 越界返回 nullptr 是定义行为而非调用方 bug：调用方跨 NAPI，窗口边界探测
    // （如「最老行再往上还有没有」）是正常用法，不能 assert 中止
    std::lock_guard<std::mutex> lock(mutex_); // 只保护本次查询，返回值使用期见头注
    if (absoluteIndex < oldestIndexLocked() || absoluteIndex >= totalPushed_)
        return nullptr;
    return &cells_[slotOf(absoluteIndex) * static_cast<size_t>(cols_)];
}

size_t ScrollbackBuffer::copyWindow(uint64_t startIndex, size_t count, Cell *out) const
{
    std::lock_guard<std::mutex> lock(mutex_);
    const uint64_t oldest = oldestIndexLocked();
    size_t copied = 0;
    for (size_t i = 0; i < count; ++i) {
        const uint64_t idx = startIndex + static_cast<uint64_t>(i);
        const Cell *line = (idx >= oldest && idx < totalPushed_)
            ? &cells_[slotOf(idx) * static_cast<size_t>(cols_)]
            : nullptr;
        if (line) {
            std::memcpy(out + i * static_cast<size_t>(cols_), line,
                        static_cast<size_t>(cols_) * sizeof(Cell));
            ++copied;
        } else {
            std::fill_n(out + i * static_cast<size_t>(cols_),
                        static_cast<size_t>(cols_), Cell{});
        }
    }
    return copied;
}

bool ScrollbackBuffer::popLine(Cell *out)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (size_ == 0)
        return false;
    --totalPushed_;
    --size_;
    std::memcpy(out, &cells_[slotOf(totalPushed_) * static_cast<size_t>(cols_)],
                static_cast<size_t>(cols_) * sizeof(Cell));
    return true;
}

void ScrollbackBuffer::clear()
{
    std::lock_guard<std::mutex> lock(mutex_);
    size_ = 0; // totalPushed_ 不动：窗口 [totalPushed_, totalPushed_) 为空，序号保持单调
}

void ScrollbackBuffer::resizeCols(int newCols, const Cell &blank)
{
    assert(newCols > 0);
    std::lock_guard<std::mutex> lock(mutex_);
    if (newCols == cols_)
        return;

    // 逐槽重排：物理槽位序号不变（槽 s 仍是槽 s），absoluteIndex 取模语义不受影响。
    // 无效槽位一并处理（内容是旧残留，无逻辑意义），省掉有效性判断分支。
    std::vector<Cell> next(capacity_ * static_cast<size_t>(newCols), blank);
    const size_t keep = std::min(static_cast<size_t>(cols_), static_cast<size_t>(newCols));
    for (size_t s = 0; s < capacity_; ++s) {
        std::memcpy(&next[s * static_cast<size_t>(newCols)],
                    &cells_[s * static_cast<size_t>(cols_)],
                    keep * sizeof(Cell));
    }
    cells_ = std::move(next);
    cols_ = newCols;
}

} // namespace term
} // namespace sshclient
