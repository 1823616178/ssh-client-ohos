/**
 * CellGrid 实现 —— 见 grid.h 头注释。
 */
#include "grid.h"

#include <algorithm>
#include <cassert>
#include <cstring>

namespace sshclient {
namespace term {

CellGrid::CellGrid(int cols, int rows, uint32_t defaultFgArgb, uint32_t defaultBgArgb)
    : cols_(cols), rows_(rows), defaultFgArgb_(defaultFgArgb), defaultBgArgb_(defaultBgArgb)
{
    assert(cols > 0 && rows > 0);
    const Cell blank = blankCell();
    cells_ = std::make_shared<std::vector<Cell>>(
        static_cast<size_t>(cols_) * static_cast<size_t>(rows_), blank);
    dirty_.assign(static_cast<size_t>(rows_ + 63) / 64, 0);
}

CellGrid::CellGrid(const CellGrid &other)
    : cols_(other.cols_),
      rows_(other.rows_),
      defaultFgArgb_(other.defaultFgArgb_),
      defaultBgArgb_(other.defaultBgArgb_),
      cells_(std::make_shared<std::vector<Cell>>(*other.cells_)), // 深拷贝，不共享存储
      dirty_(other.dirty_),
      revision_(other.revision_)
{
}

CellGrid &CellGrid::operator=(const CellGrid &other)
{
    if (this == &other)
        return *this;
    cols_ = other.cols_;
    rows_ = other.rows_;
    defaultFgArgb_ = other.defaultFgArgb_;
    defaultBgArgb_ = other.defaultBgArgb_;
    cells_ = std::make_shared<std::vector<Cell>>(*other.cells_);
    dirty_ = other.dirty_;
    revision_ = other.revision_;
    return *this;
}

Cell CellGrid::blankCell() const
{
    Cell c;
    c.codepoint = 0;
    c.fgArgb = defaultFgArgb_;
    c.bgArgb = defaultBgArgb_;
    c.attrs = 0;
    c.reserved = 0;
    return c;
}

size_t CellGrid::index(int row, int col) const
{
    assert(row >= 0 && row < rows_ && col >= 0 && col < cols_);
    return static_cast<size_t>(row) * static_cast<size_t>(cols_) + static_cast<size_t>(col);
}

void CellGrid::putCell(int row, int col, const Cell &cell)
{
    (*cells_)[index(row, col)] = cell;
    setDirty(row);
    ++revision_;
}

void CellGrid::touchCell(int row, int col)
{
    (void)index(row, col); // 仅做边界断言
    setDirty(row);
    ++revision_;
}

void CellGrid::fillCells(int row0, int col0, int row1, int col1, const Cell &cell)
{
    row0 = std::max(row0, 0);
    col0 = std::max(col0, 0);
    row1 = std::min(row1, rows_);
    col1 = std::min(col1, cols_);
    for (int r = row0; r < row1; ++r) {
        for (int c = col0; c < col1; ++c)
            (*cells_)[static_cast<size_t>(r) * static_cast<size_t>(cols_) + static_cast<size_t>(c)] = cell;
        if (col0 < col1)
            setDirty(r);
        revision_ += static_cast<uint64_t>(std::max(col1 - col0, 0));
    }
}

void CellGrid::copyCells(int destRow, int destCol, int srcRow, int srcCol, int rowCount, int colCount)
{
    if (rowCount <= 0 || colCount <= 0)
        return;

    // 源矩形越界裁剪（调用方应保证矩形在界内，这里兜底防内存破坏）
    if (srcRow < 0 || srcCol < 0 || srcRow + rowCount > rows_ || srcCol + colCount > cols_)
        return;
    if (destRow < 0 || destCol < 0 || destRow + rowCount > rows_ || destCol + colCount > cols_)
        return;

    // 源/目标允许重叠（滚动 moverect 就是重叠场景）：先快照源区域再整体写回
    std::vector<Cell> snapshot(static_cast<size_t>(rowCount) * static_cast<size_t>(colCount));
    for (int r = 0; r < rowCount; ++r) {
        const Cell *src = &(*cells_)[index(srcRow + r, srcCol)];
        std::memcpy(&snapshot[static_cast<size_t>(r) * static_cast<size_t>(colCount)],
                    src, static_cast<size_t>(colCount) * sizeof(Cell));
    }
    for (int r = 0; r < rowCount; ++r) {
        Cell *dest = &(*cells_)[index(destRow + r, destCol)];
        std::memcpy(dest, &snapshot[static_cast<size_t>(r) * static_cast<size_t>(colCount)],
                    static_cast<size_t>(colCount) * sizeof(Cell));
        setDirty(destRow + r);
    }
    revision_ += static_cast<uint64_t>(rowCount) * static_cast<uint64_t>(colCount);
}

void CellGrid::resize(int newCols, int newRows)
{
    assert(newCols > 0 && newRows > 0);
    if (newCols == cols_ && newRows == rows_)
        return;

    const Cell blank = blankCell();
    std::vector<Cell> next(static_cast<size_t>(newCols) * static_cast<size_t>(newRows), blank);

    // 按行拷贝行列交集，保留原内容
    const int keepRows = std::min(rows_, newRows);
    const int keepCols = std::min(cols_, newCols);
    for (int r = 0; r < keepRows; ++r) {
        std::memcpy(&next[static_cast<size_t>(r) * static_cast<size_t>(newCols)],
                    &(*cells_)[index(r, 0)],
                    static_cast<size_t>(keepCols) * sizeof(Cell));
    }

    // 换入新存储：旧 vector 不被释放——cellsStorage() 流出的 shared_ptr 副本
    //（T3 external arraybuffer 的保活句柄）继续持有它，直到 ArkTS 侧 GC 触发
    // finalize 才回收；此后本网格的写入只落到新存储，旧存储内容冻结（稳定旧快照）
    cells_ = std::make_shared<std::vector<Cell>>(std::move(next));
    cols_ = newCols;
    rows_ = newRows;
    dirty_.assign(static_cast<size_t>(rows_ + 63) / 64, 0);

    // 尺寸变化后整个可视区都需重绘
    for (int r = 0; r < rows_; ++r)
        setDirty(r);
    ++revision_;
}

void CellGrid::setDirty(int row)
{
    assert(row >= 0 && row < rows_);
    dirty_[static_cast<size_t>(row) / 64] |= 1ull << (static_cast<unsigned>(row) % 64);
}

void CellGrid::clearDirty()
{
    std::fill(dirty_.begin(), dirty_.end(), 0);
}

bool CellGrid::isDirty(int row) const
{
    assert(row >= 0 && row < rows_);
    return (dirty_[static_cast<size_t>(row) / 64] >> (static_cast<unsigned>(row) % 64)) & 1ull;
}

} // namespace term
} // namespace sshclient
