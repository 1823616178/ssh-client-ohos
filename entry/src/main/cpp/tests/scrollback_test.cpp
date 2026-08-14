/**
 * ScrollbackBuffer / 回滚集成单测 —— 任务 T2 验收：
 * - 环形语义：推 N > 容量后最老行被覆盖、窗口索引正确、大容量下 O(1) 定位
 *   （O(1) 由取模寻址算法保证，测试验证 50000 容量下访问正确性而非计时）
 * - 集成（VtermBridge 真 feed）：100000 行输出后 totalPushed==100000、容量钳在
 *   5000、最老可查行正确、内存有界（storageBytes 恒 == 容量×cols×16，预分配
 *   定长语义，push 前后不变）
 * - alt-screen 滚动不入回滚（libvterm 0.3.3 仅 PRIMARY buffer 触发 sb_pushline）
 * - sb_popline：libvterm 0.3.3 只在「resize 行数增大」时回填顶部空行，钉死该行为
 * - resize：缩行顶出行进回滚；cols 变化时回滚行截断/补齐
 * - 文末含 T1 审查遗留的四项钉死测试（dim / 1049h 光标 / movecursor revision /
 *   setDefaultColors revision 单调）
 *
 * 行内容读取约定与 vterm_screen_test.cpp 一致：空格=空，ASCII 原样，其余 '?'.
 */
#include <gtest/gtest.h>

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#include "term/scrollback.h"
#include "term/vterm_screen.h"

using sshclient::term::Cell;
using sshclient::term::CellGrid;
using sshclient::term::ScrollbackBuffer;
using sshclient::term::VtermBridge;
using sshclient::term::kAttrDim;

namespace {

constexpr uint32_t kDefaultFg = VtermBridge::kDefaultFgArgb;
constexpr uint32_t kDefaultBg = VtermBridge::kDefaultBgArgb;

// 造一行：首格码点 = marker，其余格零值（codepoint 0）
std::vector<Cell> makeLine(int cols, uint32_t marker)
{
    std::vector<Cell> v(static_cast<size_t>(cols), Cell{});
    v[0].codepoint = marker;
    return v;
}

// 把一行 Cell 渲染成字符串（首格之外 codepoint 0 = 空）
std::string dumpLine(const Cell *line, int cols)
{
    if (!line)
        return "<null>";
    std::string s;
    for (int c = 0; c < cols; ++c) {
        const uint32_t cp = line[c].codepoint;
        if (cp == 0)
            break;
        s.push_back(cp < 128 ? static_cast<char>(cp) : '?');
    }
    return s;
}

std::string dumpGridRow(const CellGrid &g, int row)
{
    std::string s;
    for (int c = 0; c < g.cols(); ++c) {
        const uint32_t cp = g.cellAt(row, c)->codepoint;
        if (cp == 0)
            s.push_back(' ');
        else if (cp < 128)
            s.push_back(static_cast<char>(cp));
        else
            s.push_back('?');
    }
    while (!s.empty() && s.back() == ' ')
        s.pop_back();
    return s;
}

const Cell &cellAt(VtermBridge &b, int row, int col)
{
    return *b.grid().cellAt(row, col);
}

} // namespace

// ---------------------------------------------------------------- 环形缓冲单元

TEST(ScrollbackBufferTest, CapacityClampedAndPreallocated)
{
    ScrollbackBuffer sb(80); // 默认容量
    EXPECT_EQ(sb.capacity(), ScrollbackBuffer::kDefaultCapacity);
    EXPECT_EQ(sb.cols(), 80);
    EXPECT_EQ(sb.size(), 0u);
    EXPECT_EQ(sb.totalPushed(), 0u);
    // 预分配定长：存储字节数恒 == 容量 × cols × 16
    EXPECT_EQ(sb.storageBytes(), ScrollbackBuffer::kDefaultCapacity * 80 * sizeof(Cell));

    ScrollbackBuffer zero(80, 0); // 下钳到 1
    EXPECT_EQ(zero.capacity(), 1u);

    ScrollbackBuffer huge(80, 100000); // 上钳到 50000
    EXPECT_EQ(huge.capacity(), ScrollbackBuffer::kMaxCapacity);
}

TEST(ScrollbackBufferTest, PushLineAndGetLineWindow)
{
    ScrollbackBuffer sb(4, 3);
    sb.pushLine(makeLine(4, u'A').data(), 4);
    sb.pushLine(makeLine(4, u'B').data(), 4);
    EXPECT_EQ(sb.size(), 2u);
    EXPECT_EQ(sb.totalPushed(), 2u);
    EXPECT_EQ(sb.oldestIndex(), 0u);
    EXPECT_EQ(sb.getLine(0)[0].codepoint, u'A');
    EXPECT_EQ(sb.getLine(1)[0].codepoint, u'B');
    EXPECT_EQ(sb.getLine(2), nullptr); // 未推过
}

TEST(ScrollbackBufferTest, RingOverwriteDropsOldest)
{
    ScrollbackBuffer sb(4, 3);
    for (uint32_t i = 0; i < 5; ++i)
        sb.pushLine(makeLine(4, i).data(), 4);

    EXPECT_EQ(sb.size(), 3u);
    EXPECT_EQ(sb.totalPushed(), 5u);
    EXPECT_EQ(sb.oldestIndex(), 2u); // 0、1 已被覆盖
    EXPECT_EQ(sb.getLine(0), nullptr);
    EXPECT_EQ(sb.getLine(1), nullptr);
    EXPECT_EQ(sb.getLine(2)[0].codepoint, 2u);
    EXPECT_EQ(sb.getLine(3)[0].codepoint, 3u);
    EXPECT_EQ(sb.getLine(4)[0].codepoint, 4u);
    EXPECT_EQ(sb.getLine(5), nullptr);
}

TEST(ScrollbackBufferTest, PushLineTruncatesAndPadsDefensively)
{
    ScrollbackBuffer sb(4, 2);
    // count > cols：截断（调用方 bug 防御，正常路径不发生）
    std::vector<Cell> over(6, Cell{});
    for (size_t i = 0; i < 6; ++i)
        over[i].codepoint = static_cast<uint32_t>(u'a' + i); // a b c d e f
    sb.pushLine(over.data(), over.size());
    const Cell *l0 = sb.getLine(0);
    ASSERT_NE(l0, nullptr);
    EXPECT_EQ(l0[3].codepoint, u'd'); // 第 4 格仍在
    // （第 5/6 格 e/f 被截断，不可访问——行宽恒为 cols）

    // count < cols：剩余补零值 Cell
    sb.pushLine(makeLine(4, u'X').data(), 2);
    const Cell *l1 = sb.getLine(1);
    ASSERT_NE(l1, nullptr);
    EXPECT_EQ(l1[0].codepoint, u'X');
    EXPECT_EQ(l1[1].codepoint, 0u);
    EXPECT_EQ(l1[2].codepoint, 0u);
    EXPECT_EQ(l1[3].codepoint, 0u);
}

TEST(ScrollbackBufferTest, CopyWindowBulkExactAndClamped)
{
    ScrollbackBuffer sb(4, 5);
    for (uint32_t i = 0; i < 6; ++i) // 推 6 行进容量 5：窗口 [1,6)
        sb.pushLine(makeLine(4, 10 + i).data(), 4);

    std::vector<Cell> out(4 * 5, Cell{});
    // 精确窗口 [2,4)
    EXPECT_EQ(sb.copyWindow(2, 2, out.data()), 2u);
    EXPECT_EQ(out[0].codepoint, 12u);
    EXPECT_EQ(out[4].codepoint, 13u);

    // 右端越界：[4,9) → 有效 4、5 两行，其余填零
    std::fill(out.begin(), out.end(), Cell{});
    EXPECT_EQ(sb.copyWindow(4, 5, out.data()), 2u);
    EXPECT_EQ(out[0].codepoint, 14u);
    EXPECT_EQ(out[4].codepoint, 15u);
    EXPECT_EQ(out[8].codepoint, 0u); // absoluteIndex 6 已无效 → 零值
    EXPECT_EQ(out[16].codepoint, 0u);

    // 左端越界：[0,3) → absoluteIndex 0 已被覆盖填零，1、2 有效
    std::fill(out.begin(), out.end(), Cell{});
    EXPECT_EQ(sb.copyWindow(0, 3, out.data()), 2u);
    EXPECT_EQ(out[0].codepoint, 0u);
    EXPECT_EQ(out[4].codepoint, 11u);
    EXPECT_EQ(out[8].codepoint, 12u);
}

TEST(ScrollbackBufferTest, CopyWindowWithColsMatchesCopyWindowSemantics)
{
    ScrollbackBuffer sb(4, 5);
    for (uint32_t i = 0; i < 6; ++i) // 推 6 行进容量 5：窗口 [1,6)
        sb.pushLine(makeLine(4, 10 + i).data(), 4);

    // 与 copyWindow 同语义：返回实际列宽，out 精确调整为 count × 列宽，
    // 有效行原样、窗口外填零值 Cell
    std::vector<Cell> out;
    EXPECT_EQ(sb.copyWindowWithCols(4, 5, out), 4);
    ASSERT_EQ(out.size(), 5u * 4u);
    EXPECT_EQ(out[0].codepoint, 14u);
    EXPECT_EQ(out[4].codepoint, 15u);
    EXPECT_EQ(out[8].codepoint, 0u); // absoluteIndex 6 已无效 → 零值
    EXPECT_EQ(out[16].codepoint, 0u);

    // out 复用时尺寸被重新调整（不残留旧尺寸）
    EXPECT_EQ(sb.copyWindowWithCols(1, 2, out), 4);
    ASSERT_EQ(out.size(), 2u * 4u);
    EXPECT_EQ(out[0].codepoint, 11u);
    EXPECT_EQ(out[4].codepoint, 12u);
}

TEST(ScrollbackBufferTest, CopyWindowWithColsFollowsResizeCols)
{
    ScrollbackBuffer sb(4, 3);
    std::vector<Cell> line(4, Cell{});
    for (size_t i = 0; i < 4; ++i)
        line[i].codepoint = static_cast<uint32_t>(u'A' + i); // A B C D
    sb.pushLine(line.data(), line.size());

    Cell blank{};
    sb.resizeCols(6, blank); // 扩宽后：返回新列宽，内容补零值格
    std::vector<Cell> out;
    EXPECT_EQ(sb.copyWindowWithCols(0, 1, out), 6);
    ASSERT_EQ(out.size(), 6u);
    EXPECT_EQ(out[0].codepoint, u'A');
    EXPECT_EQ(out[3].codepoint, u'D');
    EXPECT_EQ(out[4].codepoint, 0u);
    EXPECT_EQ(out[5].codepoint, 0u);

    sb.resizeCols(2, blank); // 收窄后：返回新列宽，内容截断
    EXPECT_EQ(sb.copyWindowWithCols(0, 1, out), 2);
    ASSERT_EQ(out.size(), 2u);
    EXPECT_EQ(out[0].codepoint, u'A');
    EXPECT_EQ(out[1].codepoint, u'B');
}

// T3 审查修复钉死：copyWindowWithCols 在循环线程 resizeCols 并发下，
// 每次返回的 out 尺寸必须恒等于 count × 返回列宽（旧两步式在此场景下
// 会按新列宽写旧尺寸缓冲，ASan 直接报堆越界写）
TEST(ScrollbackBufferTest, CopyWindowWithColsConsistentUnderConcurrentResize)
{
    ScrollbackBuffer sb(4, 32);
    for (uint32_t i = 0; i < 16; ++i)
        sb.pushLine(makeLine(4, i).data(), 4);

    std::atomic<bool> stop{false};
    std::atomic<bool> ok{true};
    const Cell blank{};
    std::thread resizer([&] {
        int cols = 8;
        while (!stop.load(std::memory_order_relaxed)) {
            sb.resizeCols(cols, blank);
            cols = (cols == 8) ? 4 : 8;
        }
    });

    constexpr size_t kCount = 8;
    for (int iter = 0; iter < 20000 && ok.load(std::memory_order_relaxed); ++iter) {
        std::vector<Cell> out;
        const int cols = sb.copyWindowWithCols(0, kCount, out);
        // 不变量：列宽合法且缓冲尺寸与返回列宽严格一致（同一把锁内产出）
        if ((cols != 4 && cols != 8) || out.size() != kCount * static_cast<size_t>(cols))
            ok.store(false, std::memory_order_relaxed);
    }
    stop.store(true, std::memory_order_relaxed);
    resizer.join();
    EXPECT_TRUE(ok.load());
}

TEST(ScrollbackBufferTest, PopLineLIFOAndCounterSync)
{
    ScrollbackBuffer sb(4, 3);
    for (uint32_t i = 0; i < 3; ++i)
        sb.pushLine(makeLine(4, 20 + i).data(), 4);

    std::vector<Cell> out(4, Cell{});
    ASSERT_TRUE(sb.popLine(out.data())); // 弹最新
    EXPECT_EQ(out[0].codepoint, 22u);
    EXPECT_EQ(sb.totalPushed(), 2u); // 计数同步 -1：窗口保持 [oldest,total) 连续
    EXPECT_EQ(sb.size(), 2u);

    ASSERT_TRUE(sb.popLine(out.data()));
    EXPECT_EQ(out[0].codepoint, 21u);
    ASSERT_TRUE(sb.popLine(out.data()));
    EXPECT_EQ(out[0].codepoint, 20u);
    EXPECT_FALSE(sb.popLine(out.data())); // 空缓冲
    EXPECT_EQ(sb.totalPushed(), 0u);
    EXPECT_EQ(sb.getLine(0), nullptr);
}

TEST(ScrollbackBufferTest, ClearEmptiesWindowKeepsCounter)
{
    ScrollbackBuffer sb(4, 3);
    for (uint32_t i = 0; i < 3; ++i)
        sb.pushLine(makeLine(4, i).data(), 4);
    sb.clear();
    EXPECT_EQ(sb.size(), 0u);
    EXPECT_EQ(sb.totalPushed(), 3u); // clear 不动计数：窗口 [3,3) 为空
    EXPECT_EQ(sb.getLine(2), nullptr);

    sb.pushLine(makeLine(4, 99).data(), 4); // 之后沿用原序号递增
    EXPECT_EQ(sb.totalPushed(), 4u);
    EXPECT_EQ(sb.oldestIndex(), 3u);
    EXPECT_EQ(sb.getLine(3)[0].codepoint, 99u);
    EXPECT_EQ(sb.getLine(0), nullptr);
}

TEST(ScrollbackBufferTest, ResizeColsTruncatesAndPads)
{
    ScrollbackBuffer sb(4, 3);
    std::vector<Cell> line(4, Cell{});
    for (size_t i = 0; i < 4; ++i)
        line[i].codepoint = static_cast<uint32_t>(u'A' + i); // A B C D
    sb.pushLine(line.data(), line.size());

    Cell blank{}; // 调用方（VtermBridge）会按当前默认色给 blank
    blank.fgArgb = 0xFF112233u;
    blank.bgArgb = 0xFF000000u;

    sb.resizeCols(2, blank); // 截断
    EXPECT_EQ(sb.cols(), 2);
    const Cell *l = sb.getLine(0);
    ASSERT_NE(l, nullptr);
    EXPECT_EQ(l[0].codepoint, u'A');
    EXPECT_EQ(l[1].codepoint, u'B');
    EXPECT_EQ(sb.storageBytes(), 3u * 2u * sizeof(Cell)); // 存储随新列宽重定

    sb.resizeCols(6, blank); // 补齐
    EXPECT_EQ(sb.cols(), 6);
    l = sb.getLine(0);
    ASSERT_NE(l, nullptr);
    EXPECT_EQ(l[0].codepoint, u'A');
    EXPECT_EQ(l[1].codepoint, u'B');
    for (int c = 2; c < 6; ++c) {
        EXPECT_EQ(l[c].codepoint, 0u) << "col " << c;
        EXPECT_EQ(l[c].fgArgb, blank.fgArgb) << "col " << c;
    }
    EXPECT_EQ(sb.size(), 1u); // 逻辑行数与序号语义不受重排影响
    EXPECT_EQ(sb.totalPushed(), 1u);
}

TEST(ScrollbackBufferTest, LargeCapacityAccessCorrectAtScale)
{
    // O(1) 定位由取模寻址保证；这里验证 50000 满容量 + 再绕一圈后的访问正确性
    ScrollbackBuffer sb(8, ScrollbackBuffer::kMaxCapacity);
    const size_t before = sb.storageBytes();
    for (uint32_t i = 0; i < 50000; ++i)
        sb.pushLine(makeLine(8, i).data(), 8);
    ASSERT_EQ(sb.size(), 50000u);
    EXPECT_EQ(sb.getLine(0)[0].codepoint, 0u);
    EXPECT_EQ(sb.getLine(12345)[0].codepoint, 12345u);
    EXPECT_EQ(sb.getLine(49999)[0].codepoint, 49999u);

    for (uint32_t i = 50000; i < 60000; ++i) // 再推 10000，覆盖最老 10000 行
        sb.pushLine(makeLine(8, i).data(), 8);
    EXPECT_EQ(sb.oldestIndex(), 10000u);
    EXPECT_EQ(sb.getLine(9999), nullptr);
    EXPECT_EQ(sb.getLine(10000)[0].codepoint, 10000u);
    EXPECT_EQ(sb.getLine(59999)[0].codepoint, 59999u);
    EXPECT_EQ(sb.storageBytes(), before); // 全程存储字节数不变（内存有界）
}

// ---------------------------------------------------------------- VtermBridge 集成

TEST(ScrollbackIntegrationTest, ScrolledOffLineEntersScrollback)
{
    VtermBridge b(10, 4);
    for (int r = 0; r < 4; ++r)
        b.feed("\x1b[" + std::to_string(r + 1) + ";1HR" + std::to_string(r));
    b.feed("\x1b[4;1H\n"); // 屏底换行 → 整屏上滚，R0 顶出
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "R1");
    ASSERT_EQ(b.scrollback().totalPushed(), 1u);
    EXPECT_EQ(dumpLine(b.scrollback().getLine(0), 10), "R0");
    // 顶出行的颜色是 push 时解析的默认色
    EXPECT_EQ(b.scrollback().getLine(0)[0].fgArgb, kDefaultFg);
    EXPECT_EQ(b.scrollback().getLine(0)[0].bgArgb, kDefaultBg);
}

TEST(ScrollbackIntegrationTest, HundredThousandLinesBoundedMemory)
{
    VtermBridge b(80, 24); // 默认容量 5000
    const ScrollbackBuffer &sb = b.scrollback();
    const size_t bytesBefore = sb.storageBytes();
    ASSERT_EQ(bytesBefore, 5000u * 80u * sizeof(Cell)); // 预分配上界

    // 连续输出 100023 行：前 23 行填满屏幕，之后每行顶出一行进回滚 → 恰好 100000
    std::string bulk;
    bulk.reserve(100023 * 9);
    for (int i = 0; i < 100023; ++i)
        bulk += "L" + std::to_string(i) + "\r\n";
    b.feed(bulk);

    EXPECT_EQ(sb.totalPushed(), 100000u);
    EXPECT_EQ(sb.size(), 5000u); // 容量钳在 5000
    EXPECT_EQ(sb.oldestIndex(), 95000u);
    EXPECT_EQ(sb.getLine(94999), nullptr); // 已被覆盖
    EXPECT_EQ(sb.getLine(100000), nullptr); // 尚未推入
    EXPECT_EQ(dumpLine(sb.getLine(95000), 80), "L95000"); // 最老可查行正确
    EXPECT_EQ(dumpLine(sb.getLine(99999), 80), "L99999"); // 最新行正确
    // 屏幕内容与回滚衔接：回滚最新行之后就是屏幕第 0 行
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "L100000");

    // 内存稳定：预分配/定长语义下，推 100000 行后存储字节数与推前完全一致
    EXPECT_EQ(sb.storageBytes(), bytesBefore);
}

TEST(ScrollbackIntegrationTest, AltScreenScrollNeverEntersScrollback)
{
    VtermBridge b(10, 4);
    for (int i = 0; i < 6; ++i)
        b.feed("R" + std::to_string(i) + "\r\n"); // 顶出 R0/R1/R2 进回滚
    ASSERT_EQ(b.scrollback().totalPushed(), 3u);

    b.feed("\x1b[?1049h"); // 切 alt-screen
    ASSERT_TRUE(b.altScreenActive());
    for (int i = 0; i < 10; ++i) // alt 屏内大量滚动
        b.feed("A" + std::to_string(i) + "\r\n");
    // libvterm 0.3.3 仅 PRIMARY buffer 触发 sb_pushline：回滚一行未多
    EXPECT_EQ(b.scrollback().totalPushed(), 3u);
    EXPECT_EQ(b.scrollback().size(), 3u);

    b.feed("\x1b[?1049l"); // 切回主屏
    ASSERT_FALSE(b.altScreenActive());
    EXPECT_EQ(b.scrollback().totalPushed(), 3u); // 回滚区完好
    EXPECT_EQ(dumpLine(b.scrollback().getLine(0), 10), "R0");
    EXPECT_EQ(dumpLine(b.scrollback().getLine(2), 10), "R2");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "R3"); // 主屏内容恢复
}

TEST(ScrollbackIntegrationTest, PopLineBackfillsTopRowsOnRowGrow)
{
    // libvterm 0.3.3 的 sb_popline 只在「resize 行数增大」时触发：把回滚区最新行
    // 依次拉回屏幕顶部新增空行（本测试钉死该时机与顺序）
    VtermBridge b(10, 5);
    for (int i = 0; i < 8; ++i)
        b.feed("L" + std::to_string(i) + "\r\n"); // 回滚 {L0,L1,L2,L3}，屏 [L4..L7,空]
    ASSERT_EQ(b.scrollback().totalPushed(), 4u);
    ASSERT_EQ(dumpGridRow(b.grid(), 0), "L4");

    b.resize(10, 8); // 行数 +3 → 库弹 3 行回填顶部
    EXPECT_EQ(b.scrollback().totalPushed(), 1u); // L3/L2/L1 被拉回主屏
    EXPECT_EQ(b.scrollback().size(), 1u);
    EXPECT_EQ(dumpLine(b.scrollback().getLine(0), 10), "L0");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "L1"); // 弹回的行按原序落在顶部
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "L2");
    EXPECT_EQ(dumpGridRow(b.grid(), 2), "L3");
    EXPECT_EQ(dumpGridRow(b.grid(), 3), "L4");
    EXPECT_EQ(dumpGridRow(b.grid(), 6), "L7");
    // 弹回行经 Cell→VTermScreenCell 真彩回填再重读：默认色值不变
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, kDefaultFg);

    b.resize(10, 24); // 回滚只剩 1 行：弹 1 行后库收到 0，其余新行填空白
    EXPECT_EQ(b.scrollback().totalPushed(), 0u);
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "L0");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "L1");
}

TEST(ScrollbackIntegrationTest, ResizeShrinkPushesSpareLinesIntoScrollback)
{
    VtermBridge b(10, 5);
    for (int i = 0; i < 8; ++i)
        b.feed("L" + std::to_string(i) + "\r\n"); // 回滚 {L0..L3}，屏 [L4..L7,空]
    ASSERT_EQ(b.scrollback().totalPushed(), 4u);

    b.resize(10, 3); // 行数 -2：放不下的顶部主屏行被顶进回滚
    // libvterm resize_buffer 钉死行为：光标在屏底空行时「滚动内容填底部空行」分支
    // 因光标落不进新屏幕被跳过，库选择多顶一行进回滚保住光标行——L4、L5 均进回滚
    EXPECT_EQ(b.scrollback().totalPushed(), 6u);
    EXPECT_EQ(dumpLine(b.scrollback().getLine(4), 10), "L4");
    EXPECT_EQ(dumpLine(b.scrollback().getLine(5), 10), "L5");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "L6");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "L7");
    EXPECT_EQ(dumpGridRow(b.grid(), 2), "");
}

TEST(ScrollbackIntegrationTest, EraseInDisplay3ClearsScrollback)
{
    VtermBridge b(10, 4);
    for (int i = 0; i < 6; ++i)
        b.feed("R" + std::to_string(i) + "\r\n");
    ASSERT_EQ(b.scrollback().totalPushed(), 3u);

    b.feed("\x1b[3J"); // ED 3：清回滚（不清屏幕）
    EXPECT_EQ(b.scrollback().size(), 0u);
    EXPECT_EQ(b.scrollback().totalPushed(), 3u); // 计数保持，窗口为空
    EXPECT_EQ(b.scrollback().getLine(0), nullptr);
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "R3"); // 屏幕内容不受 ED 3 影响

    b.feed("N0\r\n"); // 清后继续滚动：新行沿用原序号
    EXPECT_EQ(b.scrollback().totalPushed(), 4u);
    EXPECT_EQ(dumpLine(b.scrollback().getLine(3), 10), "R3");
}

TEST(ScrollbackIntegrationTest, ResizeColsTruncatesAndPadsScrollback)
{
    VtermBridge b(10, 4);
    for (int i = 0; i < 6; ++i)
        b.feed("ABCDEFGHI" + std::to_string(i) + "\r\n"); // 行宽 10，J 位列索引 9 是行号
    ASSERT_EQ(b.scrollback().totalPushed(), 3u);
    const ScrollbackBuffer &sb = b.scrollback();
    ASSERT_EQ(sb.cols(), 10);
    EXPECT_EQ(sb.getLine(0)[9].codepoint, u'0');

    b.resize(6, 4); // 列改窄：回滚行截断
    EXPECT_EQ(sb.cols(), 6);
    const Cell *l0 = sb.getLine(0);
    ASSERT_NE(l0, nullptr);
    EXPECT_EQ(l0[0].codepoint, u'A');
    EXPECT_EQ(l0[5].codepoint, u'F'); // 列 6 起的内容被截掉

    b.resize(10, 4); // 列改宽：补当前默认色空白格
    EXPECT_EQ(sb.cols(), 10);
    l0 = sb.getLine(0);
    ASSERT_NE(l0, nullptr);
    EXPECT_EQ(l0[0].codepoint, u'A');
    EXPECT_EQ(l0[5].codepoint, u'F');
    for (int c = 6; c < 10; ++c) {
        EXPECT_EQ(l0[c].codepoint, 0u) << "col " << c;
        EXPECT_EQ(l0[c].fgArgb, kDefaultFg) << "col " << c;
        EXPECT_EQ(l0[c].bgArgb, kDefaultBg) << "col " << c;
    }
}

// ---------------------------------------------------------------- T1 审查遗留四项

// 遗留项 1：libvterm 0.3.3 屏幕层没有 dim 属性源——SGR 2 不产生任何属性位。
// kAttrDim 位号预留（grid.h 布局稳定），待后续补丁/自绘层再接；钉死现状防回归。
TEST(T1FollowUpTest, SgrDimSetsNoAttrBit)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[2mD");
    EXPECT_EQ(cellAt(b, 0, 0).codepoint, u'D');
    EXPECT_EQ(cellAt(b, 0, 0).attrs & kAttrDim, 0u); // dim 位不置位
    EXPECT_EQ(cellAt(b, 0, 0).attrs, 0u);            // SGR 2 不产生任何属性位
    b.feed("\x1b[22mN");                             // 22 = 取消粗体/dim，同样无位
    EXPECT_EQ(cellAt(b, 0, 1).attrs, 0u);
}

// 遗留项 2：DECSET 1049h 切备选屏不归位光标（与 xterm 一致：光标留在保存前位置，
// vim 等全屏程序都会显式 CUP）；1049l 切回时恢复保存的光标。
TEST(T1FollowUpTest, AltScreenEnterDoesNotHomeCursor)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[5;10H"); // 光标到 (4,9)（0 基）
    ASSERT_EQ(b.cursorRow(), 4);
    ASSERT_EQ(b.cursorCol(), 9);

    b.feed("\x1b[?1049h");
    EXPECT_TRUE(b.altScreenActive());
    EXPECT_EQ(b.cursorRow(), 4); // 不归位
    EXPECT_EQ(b.cursorCol(), 9);

    b.feed("\x1b[2;3H"); // alt 屏里挪走
    ASSERT_EQ(b.cursorRow(), 1);
    b.feed("\x1b[?1049l");
    EXPECT_FALSE(b.altScreenActive());
    EXPECT_EQ(b.cursorRow(), 4); // 恢复保存的光标
    EXPECT_EQ(b.cursorCol(), 9);
}

// 遗留项 3：纯光标移动（不写任何单元格）也要触发帧重绘——movecursor 抬 revision。
TEST(T1FollowUpTest, MoveCursorBumpsRevision)
{
    VtermBridge b(80, 24);
    b.grid().clearDirty();
    const uint64_t rev0 = b.grid().revision();
    b.feed("\x1b[5;5H"); // 纯光标移动
    EXPECT_GT(b.grid().revision(), rev0); // 修复前：revision 不变，丢光标帧
    // 既有标脏行为保持：新旧光标行均脏
    EXPECT_TRUE(b.grid().isDirty(0));
    EXPECT_TRUE(b.grid().isDirty(4));
    EXPECT_FALSE(b.grid().isDirty(1));
}

// 遗留项 4：setDefaultColors 整体重建网格后 revision 对外单调不减（不回落到小区），
// 且整屏按新默认色重解析。
TEST(T1FollowUpTest, SetDefaultColorsKeepsRevisionMonotonic)
{
    VtermBridge b(80, 24);
    b.feed("hello"); // 默认色文本
    const uint64_t rev0 = b.grid().revision();

    constexpr uint32_t kNewFg = 0xFF112233u;
    constexpr uint32_t kNewBg = 0xFF010203u;
    b.setDefaultColors(kNewFg, kNewBg);
    EXPECT_GT(b.grid().revision(), rev0); // 修复前：重建归零，revision 回退
    // 默认色单元格按新色重解析
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, kNewFg);
    EXPECT_EQ(cellAt(b, 0, 0).bgArgb, kNewBg);
    EXPECT_EQ(b.grid().defaultFgArgb(), kNewFg);

    // 再换色仍然单调
    const uint64_t rev1 = b.grid().revision();
    b.setDefaultColors(kDefaultFg, kDefaultBg);
    EXPECT_GT(b.grid().revision(), rev1);
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, kDefaultFg);
}
