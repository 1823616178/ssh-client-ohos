/**
 * CellGrid 单测 —— 任务 T1 验收：16 字节布局、脏行位图、revision、resize 保留内容。
 *
 * 本文件不测 libvterm 行为（那是 vterm_screen_test.cpp），只测网格本体。
 */
#include <cstring>

#include <gtest/gtest.h>

#include "term/grid.h"

using sshclient::term::Cell;
using sshclient::term::CellGrid;
using sshclient::term::kAttrBold;
using sshclient::term::kAttrWide;
using sshclient::term::kWideContinuation;

namespace {

constexpr uint32_t kFg = 0xFFE5E5E5u;
constexpr uint32_t kBg = 0xFF000000u;

Cell makeCell(uint32_t codepoint, uint16_t attrs = 0, uint32_t fg = 0xFF112233u, uint32_t bg = 0xFF445566u)
{
    Cell c;
    c.codepoint = codepoint;
    c.fgArgb = fg;
    c.bgArgb = bg;
    c.attrs = attrs;
    c.reserved = 0;
    return c;
}

} // namespace

// ---- 布局：DESIGN §2.2 的 16 字节结构是硬约定，靠编译期 static_assert + 运行期抽查 ----

TEST(TermGridTest, CellLayoutIs16BytesWithDesignOffsets)
{
    EXPECT_EQ(sizeof(Cell), 16u);
    EXPECT_EQ(offsetof(Cell, codepoint), 0u);
    EXPECT_EQ(offsetof(Cell, fgArgb), 4u);
    EXPECT_EQ(offsetof(Cell, bgArgb), 8u);
    EXPECT_EQ(offsetof(Cell, attrs), 12u);
    EXPECT_EQ(offsetof(Cell, reserved), 14u);
}

TEST(TermGridTest, GridMemoryIsContiguousRowMajor)
{
    CellGrid g(4, 3, kFg, kBg);
    // cellAt(r,c) 指针 = data() + (r*cols+c)*16，行优先连续
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 4; ++c) {
            const uint8_t *expect = g.data() + static_cast<size_t>(r * 4 + c) * 16;
            EXPECT_EQ(reinterpret_cast<const uint8_t *>(g.cellAt(r, c)), expect) << r << "," << c;
        }
    }
    EXPECT_EQ(g.byteSize(), 4u * 3u * 16u);
}

// ---- 构造与空白格 ----

TEST(TermGridTest, FreshGridIsAllBlankWithDefaultColors)
{
    CellGrid g(80, 24, kFg, kBg);
    EXPECT_EQ(g.cols(), 80);
    EXPECT_EQ(g.rows(), 24);
    for (int r = 0; r < 24; ++r) {
        for (int c = 0; c < 80; ++c) {
            const Cell *cell = g.cellAt(r, c);
            ASSERT_EQ(cell->codepoint, 0u);
            EXPECT_EQ(cell->fgArgb, kFg);
            EXPECT_EQ(cell->bgArgb, kBg);
            EXPECT_EQ(cell->attrs, 0u);
        }
    }
    EXPECT_EQ(g.revision(), 0u);
}

// ---- 写入、脏行、revision ----

TEST(TermGridTest, PutCellWritesFieldsMarksDirtyBumpsRevision)
{
    CellGrid g(10, 5, kFg, kBg);
    g.putCell(2, 3, makeCell(u'X', kAttrBold));

    const Cell *cell = g.cellAt(2, 3);
    EXPECT_EQ(cell->codepoint, u'X');
    EXPECT_EQ(cell->fgArgb, 0xFF112233u);
    EXPECT_EQ(cell->bgArgb, 0xFF445566u);
    EXPECT_EQ(cell->attrs, kAttrBold);

    EXPECT_TRUE(g.isDirty(2));
    EXPECT_FALSE(g.isDirty(0));
    EXPECT_FALSE(g.isDirty(1));
    EXPECT_FALSE(g.isDirty(3));
    EXPECT_EQ(g.revision(), 1u);
}

TEST(TermGridTest, RevisionIncrementsOncePerCellWrite)
{
    CellGrid g(10, 5, kFg, kBg);
    g.putCell(0, 0, makeCell(u'A'));
    g.putCell(0, 1, makeCell(u'B'));
    g.putCell(1, 0, makeCell(u'C'));
    EXPECT_EQ(g.revision(), 3u);
    // 同格重复写也计数（单调递增，不做去重）
    g.putCell(0, 0, makeCell(u'Z'));
    EXPECT_EQ(g.revision(), 4u);
}

TEST(TermGridTest, ClearDirtyResetsAllRows)
{
    CellGrid g(10, 5, kFg, kBg);
    g.putCell(0, 0, makeCell(u'A'));
    g.putCell(4, 9, makeCell(u'B'));
    ASSERT_TRUE(g.isDirty(0));
    ASSERT_TRUE(g.isDirty(4));
    g.clearDirty();
    for (int r = 0; r < 5; ++r)
        EXPECT_FALSE(g.isDirty(r));
    // clearDirty 不影响 revision（revision 只增不减）
    EXPECT_EQ(g.revision(), 2u);
}

// 跨 64 行边界的位图 word 索引
TEST(TermGridTest, DirtyBitmapSpansMultipleWords)
{
    CellGrid g(4, 130, kFg, kBg);
    g.putCell(0, 0, makeCell(u'A'));
    g.putCell(63, 0, makeCell(u'B'));
    g.putCell(64, 0, makeCell(u'C'));
    g.putCell(129, 0, makeCell(u'D'));
    EXPECT_TRUE(g.isDirty(0));
    EXPECT_TRUE(g.isDirty(63));
    EXPECT_TRUE(g.isDirty(64));
    EXPECT_TRUE(g.isDirty(129));
    EXPECT_FALSE(g.isDirty(1));
    EXPECT_FALSE(g.isDirty(62));
    EXPECT_FALSE(g.isDirty(65));
    EXPECT_FALSE(g.isDirty(128));
    // 位图本体可直接给 NAPI 零拷贝暴露（T3）
    ASSERT_EQ(g.dirtyBitmap().size(), 3u); // 130 行 → 3 个 u64 word
    EXPECT_EQ(g.dirtyBitmap()[0], (1ull << 0) | (1ull << 63));
    EXPECT_EQ(g.dirtyBitmap()[1], 1ull << 0);
    EXPECT_EQ(g.dirtyBitmap()[2], 1ull << 1);
}

// ---- cellAt 可写指针 + touchCell ----

TEST(TermGridTest, WritableCellPointerWithManualTouch)
{
    CellGrid g(10, 5, kFg, kBg);
    Cell *cell = g.cellAt(1, 1);
    cell->codepoint = u'Q';
    cell->attrs = kAttrWide;
    g.touchCell(1, 1);

    EXPECT_EQ(g.cellAt(1, 1)->codepoint, u'Q');
    EXPECT_TRUE(g.isDirty(1));
    EXPECT_EQ(g.revision(), 1u);
}

// ---- fillCells（ED/EL 的网格侧原语）----

TEST(TermGridTest, FillCellsFillsHalfOpenRectAndClipsOverflow)
{
    CellGrid g(10, 5, kFg, kBg);
    const Cell blank = g.blankCell();
    g.fillCells(1, 2, 3, 8, blank); // 行 [1,3) 列 [2,8) → 12 格
    EXPECT_EQ(g.revision(), 12u);
    EXPECT_TRUE(g.isDirty(1));
    EXPECT_TRUE(g.isDirty(2));
    EXPECT_FALSE(g.isDirty(3));
    // 越界矩形裁剪到网格内，不得越界写
    g.clearDirty();
    g.fillCells(4, 8, 99, 99, blank); // 只剩 (4,8)(4,9) 两格
    EXPECT_EQ(g.revision(), 14u);
    EXPECT_TRUE(g.isDirty(4));
}

// ---- copyCells（moverect 的网格侧原语），源/目标重叠必须安全 ----

TEST(TermGridTest, CopyCellsHandlesOverlappingDownwardMove)
{
    CellGrid g(4, 5, kFg, kBg);
    for (int r = 0; r < 4; ++r)
        g.putCell(r, 0, makeCell(static_cast<uint32_t>(u'A' + r))); // A B C D
    g.clearDirty();

    // 行 [0,4) 下移一行 → 行 [1,5)：与源重叠，必须按快照拷贝而非逐行 memmove
    g.copyCells(1, 0, 0, 0, 4, 1);
    EXPECT_EQ(g.cellAt(0, 0)->codepoint, u'A'); // 行 0 不在目标区，保持
    EXPECT_EQ(g.cellAt(1, 0)->codepoint, u'A');
    EXPECT_EQ(g.cellAt(2, 0)->codepoint, u'B');
    EXPECT_EQ(g.cellAt(3, 0)->codepoint, u'C');
    EXPECT_EQ(g.cellAt(4, 0)->codepoint, u'D');
    for (int r = 1; r < 5; ++r)
        EXPECT_TRUE(g.isDirty(r));
    EXPECT_FALSE(g.isDirty(0));
}

TEST(TermGridTest, CopyCellsHandlesOverlappingUpwardMove)
{
    CellGrid g(4, 5, kFg, kBg);
    for (int r = 1; r < 5; ++r)
        g.putCell(r, 0, makeCell(static_cast<uint32_t>(u'A' + r))); // 行1..4 = B C D E

    // 行 [1,5) 上移一行 → 行 [0,4)（滚动区上滚的方向）
    g.copyCells(0, 0, 1, 0, 4, 1);
    EXPECT_EQ(g.cellAt(0, 0)->codepoint, u'B');
    EXPECT_EQ(g.cellAt(1, 0)->codepoint, u'C');
    EXPECT_EQ(g.cellAt(2, 0)->codepoint, u'D');
    EXPECT_EQ(g.cellAt(3, 0)->codepoint, u'E');
    EXPECT_EQ(g.cellAt(4, 0)->codepoint, u'E'); // 行 4 不在目标区，保持
}

// ---- resize：行列交集保留内容 ----

TEST(TermGridTest, ResizeGrowPreservesIntersectionAndBlanksNewArea)
{
    CellGrid g(4, 3, kFg, kBg);
    g.putCell(0, 0, makeCell(u'A'));
    g.putCell(2, 3, makeCell(u'B'));

    g.resize(6, 5);
    EXPECT_EQ(g.cols(), 6);
    EXPECT_EQ(g.rows(), 5);
    EXPECT_EQ(g.cellAt(0, 0)->codepoint, u'A');
    EXPECT_EQ(g.cellAt(2, 3)->codepoint, u'B');
    // 新增区域是空白格（默认色）
    EXPECT_EQ(g.cellAt(0, 5)->codepoint, 0u);
    EXPECT_EQ(g.cellAt(0, 5)->fgArgb, kFg);
    EXPECT_EQ(g.cellAt(4, 0)->codepoint, 0u);
    EXPECT_EQ(g.cellAt(4, 0)->bgArgb, kBg);
    // resize 后全部行标脏（可视区整体重绘）
    for (int r = 0; r < 5; ++r)
        EXPECT_TRUE(g.isDirty(r));
}

TEST(TermGridTest, ResizeShrinkClipsContent)
{
    CellGrid g(6, 5, kFg, kBg);
    g.putCell(0, 0, makeCell(u'A'));
    g.putCell(4, 5, makeCell(u'B')); // 会被裁掉

    g.resize(3, 2);
    EXPECT_EQ(g.cols(), 3);
    EXPECT_EQ(g.rows(), 2);
    EXPECT_EQ(g.cellAt(0, 0)->codepoint, u'A');
    EXPECT_EQ(g.revision(), 3u); // 两次 putCell + 一次 resize
}

TEST(TermGridTest, ResizeToSameSizeIsNoop)
{
    CellGrid g(4, 3, kFg, kBg);
    g.putCell(1, 1, makeCell(u'A'));
    g.clearDirty();
    const uint64_t rev = g.revision();
    g.resize(4, 3);
    EXPECT_EQ(g.revision(), rev);
    EXPECT_FALSE(g.isDirty(1));
}
