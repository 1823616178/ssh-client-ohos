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

void ScrollbackBuffer::pushLine(const Cell *cells, size_t count, bool wrapsNext)
{
    std::lock_guard<std::mutex> lock(mutex_);
    Cell *slot = &cells_[slotOf(totalPushed_) * static_cast<size_t>(cols_)];
    const size_t n = std::min(count, static_cast<size_t>(cols_));
    std::memcpy(slot, cells, n * sizeof(Cell));
    // 防御性补空（正常路径 count == cols_）：零值 Cell，codepoint 0 = 空
    for (size_t c = n; c < static_cast<size_t>(cols_); ++c)
        slot[c] = Cell{};
    Cell &last = slot[static_cast<size_t>(cols_) - 1];
    last.reserved = static_cast<uint16_t>((last.reserved & ~kReservedWrapsNext) |
                                          (wrapsNext ? kReservedWrapsNext : 0));

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
    return copyWindowLocked(startIndex, count, out);
}

int ScrollbackBuffer::copyWindowWithCols(uint64_t startIndex, size_t count,
                                         std::vector<Cell> &out) const
{
    std::lock_guard<std::mutex> lock(mutex_);
    // 列宽与拷出在同一把锁内：out 尺寸与拷贝步长天然一致，无 TOCTOU 窗口
    out.assign(count * static_cast<size_t>(cols_), Cell{});
    copyWindowLocked(startIndex, count, out.data());
    return cols_;
}

size_t ScrollbackBuffer::copyWindowLocked(uint64_t startIndex, size_t count, Cell *out) const
{
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
    ++epoch_;
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

namespace {

// 逻辑行末尾的「空白」：码点 0（擦除态）且无反显（反显空格肉眼可见，如状态栏色块）。
// 与 libvterm reflow 的 line_popcount 口径一致（只看码点），额外保留反显格。
bool isTrailingBlank(const Cell &c)
{
    return c.codepoint == 0 && (c.attrs & kAttrReverse) == 0;
}

// 把一条逻辑行按 cols 折行追加到 out（每行恰好 cols 格，不足补 blank）。
// 宽字符首格 + 续格作为整体放置：放不下时行尾留空位并折行（同 libvterm 写入语义）。
// 除最后一段外的每段行末置 kReservedWrapsNext；最后一段继承 tailWraps。
void appendWrapped(std::vector<Cell> &out, const std::vector<Cell> &logical, size_t cols,
                   const Cell &blank, bool tailWraps)
{
    size_t rowStart = out.size();
    out.resize(out.size() + cols, blank);
    size_t col = 0;
    for (size_t i = 0; i < logical.size(); ++i) {
        const Cell &c = logical[i];
        if (c.codepoint == kWideContinuation) {
            continue; // 孤立续格（首格已随前段裁掉）：丢弃，续格总随首格一起放置
        }
        const bool wide = (c.attrs & kAttrWide) != 0 && i + 1 < logical.size() &&
                          logical[i + 1].codepoint == kWideContinuation;
        const size_t need = wide ? 2 : 1;
        if (col + need > cols) {
            out[rowStart + cols - 1].reserved |= kReservedWrapsNext;
            rowStart = out.size();
            out.resize(out.size() + cols, blank);
            col = 0;
        }
        out[rowStart + col] = c;
        out[rowStart + col].reserved = 0;
        ++col;
        if (wide) {
            out[rowStart + col] = logical[i + 1];
            out[rowStart + col].reserved = 0;
            ++col;
            ++i;
        }
    }
    Cell &last = out[rowStart + cols - 1];
    last.reserved = static_cast<uint16_t>((last.reserved & ~kReservedWrapsNext) |
                                          (tailWraps ? kReservedWrapsNext : 0));
}

} // namespace

void ScrollbackBuffer::reflow(int newCols, const Cell &blank)
{
    assert(newCols > 0);
    if (newCols < 2) {
        resizeCols(newCols, blank);
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_;
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (newCols == cols_) {
        return;
    }
    const size_t oc = static_cast<size_t>(cols_);
    const size_t nc = static_cast<size_t>(newCols);
    const uint64_t oldest = oldestIndexLocked();

    std::vector<Cell> out;
    out.reserve(size_ * nc);
    std::vector<Cell> logical;
    logical.reserve(oc * 4);

    uint64_t idx = oldest;
    while (idx < totalPushed_) {
        logical.clear();
        bool tailWraps = false;
        for (;;) {
            const Cell *row = &cells_[slotOf(idx) * oc];
            const bool wraps = (row[oc - 1].reserved & kReservedWrapsNext) != 0;
            const bool hasNext = idx + 1 < totalPushed_;
            size_t len = oc;
            if (wraps && hasNext) {
                // 宽字符放不下行尾时 libvterm 留一个擦除格再折行：拼接时去掉该空位
                const Cell *next = &cells_[slotOf(idx + 1) * oc];
                if (row[oc - 1].codepoint == 0 && (next[0].attrs & kAttrWide) != 0) {
                    len = oc - 1;
                }
            } else {
                while (len > 0 && isTrailingBlank(row[len - 1])) {
                    --len;
                }
            }
            logical.insert(logical.end(), row, row + len);
            ++idx;
            if (!(wraps && hasNext)) {
                tailWraps = wraps; // 回滚最后一行可能续接屏幕首行：保留标记
                break;
            }
        }
        appendWrapped(out, logical, nc, blank, tailWraps);
    }

    const size_t produced = out.size() / nc;
    const size_t keep = std::min(produced, capacity_);
    const size_t skip = produced - keep;
    std::vector<Cell> next(capacity_ * nc, blank);
    const uint64_t newTotal = oldest + static_cast<uint64_t>(produced);
    const uint64_t newOldest = newTotal - static_cast<uint64_t>(keep);
    for (size_t i = 0; i < keep; ++i) {
        const uint64_t abs = newOldest + static_cast<uint64_t>(i);
        const size_t slot = static_cast<size_t>(abs % static_cast<uint64_t>(capacity_));
        std::memcpy(&next[slot * nc], &out[(skip + i) * nc], nc * sizeof(Cell));
    }
    cells_ = std::move(next);
    cols_ = newCols;
    totalPushed_ = newTotal;
    size_ = keep;
    ++epoch_;
}

} // namespace term
} // namespace sshclient
