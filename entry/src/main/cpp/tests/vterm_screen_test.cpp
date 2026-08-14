/**
 * VtermBridge 单测 —— 任务 T1 验收：VT 序列语料逐格断言。
 *
 * 语料覆盖：纯文本/换行、SGR 颜色与属性、256 色与真彩、光标定位与边界钳制、
 * DECSTBM 滚动区、alt-screen、DECSET（光标可见/鼠标模式/焦点上报）、宽字符、
 * dirty 位图与 revision、ED/EL 三种模式、bell、标题 OSC。
 *
 * 颜色期望值基于 vterm_screen.cpp 内置的 xterm 近似 16 色调色板与
 * xterm 256 扩展公式（6×6×6 立方体色阶 {0,95,135,175,215,255}）。
 */
#include <gtest/gtest.h>

#include "term/vterm_screen.h"

using sshclient::term::Cell;
using sshclient::term::CellGrid;
using sshclient::term::kAttrBold;
using sshclient::term::kAttrItalic;
using sshclient::term::kAttrReverse;
using sshclient::term::kAttrStrike;
using sshclient::term::kAttrUnderline;
using sshclient::term::kAttrWide;
using sshclient::term::kWideContinuation;
using sshclient::term::MouseMode;
using sshclient::term::VtermBridge;

namespace {

// 内置 xterm 近似调色板取值（与 vterm_screen.cpp 的 kXtermPalette 对齐）
constexpr uint32_t kPaletteRed = 0xFFCD0000u;    // 索引 1
constexpr uint32_t kPaletteGreen = 0xFF00CD00u;  // 索引 2
constexpr uint32_t kPaletteBrightRed = 0xFFFF0000u; // 索引 9
constexpr uint32_t kDefaultFg = VtermBridge::kDefaultFgArgb;
constexpr uint32_t kDefaultBg = VtermBridge::kDefaultBgArgb;

// 把一行渲染成字符串：空格=空，ASCII 原样，宽字符续格跳过，其余非 ASCII 用 '?'
std::string dumpGridRow(const CellGrid &g, int row)
{
    std::string s;
    for (int c = 0; c < g.cols(); ++c) {
        const uint32_t cp = g.cellAt(row, c)->codepoint;
        if (cp == 0)
            s.push_back(' ');
        else if (cp == kWideContinuation)
            continue; // 宽字符续格不占显示位
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

// ---- 纯文本与换行回车 ----

TEST(VtermScreenTest, PlainTextCarriageReturnAndNewline)
{
    VtermBridge b(80, 24);
    b.feed("abc\r\ndef");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "abc");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "def");
    EXPECT_EQ(b.cursorRow(), 1);
    EXPECT_EQ(b.cursorCol(), 3);
}

TEST(VtermScreenTest, LineFeedKeepsColumnWithoutCarriageReturn)
{
    VtermBridge b(80, 24);
    b.feed("abc\nd"); // LF 只下移不回车：写完 abc 光标在第 3 列，d 落在第 3 列
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "   d");
}

// ---- SGR 颜色与属性 ----

TEST(VtermScreenTest, SgrForegroundBackgroundAndBold)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[31mR"); // 红前景
    EXPECT_EQ(cellAt(b, 0, 0).codepoint, u'R');
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, kPaletteRed);
    EXPECT_EQ(cellAt(b, 0, 0).bgArgb, kDefaultBg);

    b.feed("\x1b[0m\x1b[42mG"); // 复位后绿背景
    EXPECT_EQ(cellAt(b, 0, 1).codepoint, u'G');
    EXPECT_EQ(cellAt(b, 0, 1).fgArgb, kDefaultFg);
    EXPECT_EQ(cellAt(b, 0, 1).bgArgb, kPaletteGreen);

    b.feed("\x1b[0m\x1b[1mB"); // 粗体
    EXPECT_EQ(cellAt(b, 0, 2).attrs & kAttrBold, kAttrBold);
}

TEST(VtermScreenTest, SgrCombinedBoldRedUsesBoldAsBright)
{
    VtermBridge b(80, 24); // bold-as-bright 默认开
    b.feed("\x1b[1;31mX");
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, kPaletteBrightRed);
    EXPECT_EQ(cellAt(b, 0, 0).attrs & kAttrBold, kAttrBold);

    // 反序写法等价（颜色在读取时解析，与 SGR 书写顺序无关）
    b.feed("\x1b[0m\x1b[31;1mY");
    EXPECT_EQ(cellAt(b, 0, 1).fgArgb, kPaletteBrightRed);
}

TEST(VtermScreenTest, BoldAsBrightCanBeDisabled)
{
    VtermBridge b(80, 24);
    b.setBoldAsBright(false);
    b.feed("\x1b[1;31mX");
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, kPaletteRed); // 不提亮
    EXPECT_EQ(cellAt(b, 0, 0).attrs & kAttrBold, kAttrBold);
}

TEST(VtermScreenTest, SgrResetRestoresDefaults)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[1;31;42mX\x1b[0mN");
    EXPECT_EQ(cellAt(b, 0, 1).codepoint, u'N');
    EXPECT_EQ(cellAt(b, 0, 1).fgArgb, kDefaultFg);
    EXPECT_EQ(cellAt(b, 0, 1).bgArgb, kDefaultBg);
    EXPECT_EQ(cellAt(b, 0, 1).attrs, 0u);
}

TEST(VtermScreenTest, SgrItalicUnderlineStrikeReverse)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[3mI\x1b[23m\x1b[4mU\x1b[24m\x1b[9mS\x1b[29m\x1b[7mR");
    EXPECT_EQ(cellAt(b, 0, 0).attrs & kAttrItalic, kAttrItalic);
    EXPECT_EQ(cellAt(b, 0, 1).attrs & kAttrUnderline, kAttrUnderline);
    EXPECT_EQ(cellAt(b, 0, 2).attrs & kAttrStrike, kAttrStrike);
    EXPECT_EQ(cellAt(b, 0, 3).attrs & kAttrReverse, kAttrReverse);
}

// ---- 256 色与真彩 ----

TEST(VtermScreenTest, Extended256Colors)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[38;5;196mA"); // 立方体 (255,0,0)
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, 0xFFFF0000u);
    b.feed("\x1b[38;5;21mB"); // 立方体 (0,0,255)
    EXPECT_EQ(cellAt(b, 0, 1).fgArgb, 0xFF0000FFu);
    b.feed("\x1b[48;5;46mC"); // 立方体 (0,255,0) 背景
    EXPECT_EQ(cellAt(b, 0, 2).bgArgb, 0xFF00FF00u);
    b.feed("\x1b[38;5;255mD"); // 灰阶 (238,238,238)
    EXPECT_EQ(cellAt(b, 0, 3).fgArgb, 0xFFEEEEEEu);
}

TEST(VtermScreenTest, TrueColorParsesToArgb)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[38;2;12;34;56mT");
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, 0xFF0C2238u);
    b.feed("\x1b[48;2;255;128;0mU");
    EXPECT_EQ(cellAt(b, 0, 1).bgArgb, 0xFFFF8000u);
}

// ---- 调色板注入 ----

TEST(VtermScreenTest, CustomPaletteOverridesBuiltin)
{
    VtermBridge b(80, 24);
    std::array<uint32_t, 16> theme{};
    theme.fill(0xFF000000u);
    theme[1] = 0xFF123456u; // 自定义「红」
    b.setPalette(theme);
    b.feed("\x1b[31mR");
    EXPECT_EQ(cellAt(b, 0, 0).fgArgb, 0xFF123456u);
}

// ---- 光标定位与相对移动、边界钳制 ----

TEST(VtermScreenTest, CursorAbsolutePositioning)
{
    VtermBridge b(80, 24);
    EXPECT_EQ(b.cursorRow(), 0);
    EXPECT_EQ(b.cursorCol(), 0);
    b.feed("\x1b[5;10H"); // CUP 行列从 1 起
    EXPECT_EQ(b.cursorRow(), 4);
    EXPECT_EQ(b.cursorCol(), 9);
    b.feed("X");
    EXPECT_EQ(cellAt(b, 4, 9).codepoint, u'X');
    b.feed("\x1b[H"); // 缺省 = 1;1
    EXPECT_EQ(b.cursorRow(), 0);
    EXPECT_EQ(b.cursorCol(), 0);
}

TEST(VtermScreenTest, CursorRelativeMoves)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[2B"); // 下 2
    EXPECT_EQ(b.cursorRow(), 2);
    b.feed("\x1b[3C"); // 右 3
    EXPECT_EQ(b.cursorCol(), 3);
    b.feed("\x1b[1A"); // 上 1
    EXPECT_EQ(b.cursorRow(), 1);
    b.feed("\x1b[2D"); // 左 2
    EXPECT_EQ(b.cursorCol(), 1);
}

TEST(VtermScreenTest, CursorClampsAtScreenEdges)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[5D"); // 左上角再左移：钳到 0
    EXPECT_EQ(b.cursorCol(), 0);
    b.feed("\x1b[5A");
    EXPECT_EQ(b.cursorRow(), 0);
    b.feed("\x1b[1;80H\x1b[10C"); // 右边界再右移：钳到 79
    EXPECT_EQ(b.cursorCol(), 79);
    b.feed("\x1b[24;1H\x1b[5B"); // 下边界再下移：钳到 23
    EXPECT_EQ(b.cursorRow(), 23);
}

// ---- DECSTBM 滚动区：区内滚动、区外不动 ----

TEST(VtermScreenTest, ScrollRegionScrollsInsideOnly)
{
    VtermBridge b(10, 6);
    for (int r = 0; r < 6; ++r) {
        b.feed("\x1b[" + std::to_string(r + 1) + ";1HL" + std::to_string(r));
    }
    ASSERT_EQ(dumpGridRow(b.grid(), 0), "L0");

    b.feed("\x1b[2;5r"); // 滚动区 = 第 2..5 行（1 基），光标回 home
    b.feed("\x1b[5;1H"); // 光标到区内最后一行
    b.grid().clearDirty();
    b.feed("\n");        // 在区底换行 → 区内整体上滚一行

    EXPECT_EQ(dumpGridRow(b.grid(), 0), "L0"); // 区外（上）不动
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "L2");
    EXPECT_EQ(dumpGridRow(b.grid(), 2), "L3");
    EXPECT_EQ(dumpGridRow(b.grid(), 3), "L4");
    EXPECT_EQ(dumpGridRow(b.grid(), 4), "");   // 区底新行空白
    EXPECT_EQ(dumpGridRow(b.grid(), 5), "L5"); // 区外（下）不动

    // 脏行只落在滚动区内的行
    EXPECT_FALSE(b.grid().isDirty(0));
    EXPECT_TRUE(b.grid().isDirty(1));
    EXPECT_TRUE(b.grid().isDirty(2));
    EXPECT_TRUE(b.grid().isDirty(3));
    EXPECT_TRUE(b.grid().isDirty(4));
    EXPECT_FALSE(b.grid().isDirty(5));
}

TEST(VtermScreenTest, FullScreenScrollDropsTopLine)
{
    VtermBridge b(10, 4);
    for (int r = 0; r < 4; ++r)
        b.feed("\x1b[" + std::to_string(r + 1) + ";1HR" + std::to_string(r));
    b.feed("\x1b[4;1H\n"); // 屏底换行 → 整屏上滚（无滚动区）
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "R1");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "R2");
    EXPECT_EQ(dumpGridRow(b.grid(), 2), "R3");
    EXPECT_EQ(dumpGridRow(b.grid(), 3), "");
    // R0 被顶出屏幕：T2 起进入回滚缓冲（sb_pushline → ScrollbackBuffer，
    // 集成断言见 scrollback_test.cpp 的 ScrolledOffLineEntersScrollback）
}

// ---- alt-screen ----

TEST(VtermScreenTest, AltScreenEnterExitRestoresPrimaryContent)
{
    VtermBridge b(80, 24);
    b.feed("MAIN");
    ASSERT_EQ(dumpGridRow(b.grid(), 0), "MAIN");
    EXPECT_FALSE(b.altScreenActive());

    b.feed("\x1b[?1049h"); // 切入备选屏（并保存光标）
    EXPECT_TRUE(b.altScreenActive());
    EXPECT_EQ(dumpGridRow(b.grid(), 0), ""); // 备选缓冲全新空白

    // 1049h 不把光标归位（与 xterm 一致：光标留在保存前的位置），
    // vim 这类全屏程序都会显式 CUP；测试先归位再写
    b.feed("\x1b[HALT");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "ALT");

    b.feed("\x1b[?1049l"); // 切回主屏
    EXPECT_FALSE(b.altScreenActive());
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "MAIN"); // 主屏内容恢复
}

// ---- DECSET：光标可见性 / 鼠标模式 / 焦点上报 ----

TEST(VtermScreenTest, DecsetCursorVisibility)
{
    VtermBridge b(80, 24);
    EXPECT_TRUE(b.cursorVisible());
    b.feed("\x1b[?25l");
    EXPECT_FALSE(b.cursorVisible());
    b.feed("\x1b[?25h");
    EXPECT_TRUE(b.cursorVisible());
}

TEST(VtermScreenTest, DecsetMouseModes)
{
    VtermBridge b(80, 24);
    EXPECT_EQ(b.mouseMode(), MouseMode::kNone);
    b.feed("\x1b[?1000h");
    EXPECT_EQ(b.mouseMode(), MouseMode::kClick);
    b.feed("\x1b[?1002h");
    EXPECT_EQ(b.mouseMode(), MouseMode::kDrag);
    b.feed("\x1b[?1003h");
    EXPECT_EQ(b.mouseMode(), MouseMode::kMove);
    b.feed("\x1b[?1003l");
    EXPECT_EQ(b.mouseMode(), MouseMode::kNone);
}

TEST(VtermScreenTest, DecsetFocusReport)
{
    VtermBridge b(80, 24);
    EXPECT_FALSE(b.focusReportEnabled());
    b.feed("\x1b[?1004h");
    EXPECT_TRUE(b.focusReportEnabled());
    b.feed("\x1b[?1004l");
    EXPECT_FALSE(b.focusReportEnabled());
}

// DECSET 1006（SGR 鼠标扩展编码）在 libvterm 0.3.3 只进内部 mouse_protocol，
// 不产生 settermprop 事件——mouseMode() 不受影响是库的既有行为，断言钉死它。
// 编码细节由 libvterm 在 vterm_mouse_button 生成上报序列时内部生效。
TEST(VtermScreenTest, Decset1006IsLibraryInternalOnly)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[?1006h");
    EXPECT_EQ(b.mouseMode(), MouseMode::kNone); // 1006 不改变上报模式
}

// ---- 宽字符 ----

TEST(VtermScreenTest, WideCharOccupiesTwoCells)
{
    VtermBridge b(80, 24);
    b.feed("A你B"); // 「你」U+4F60 占两格
    EXPECT_EQ(cellAt(b, 0, 0).codepoint, u'A');

    EXPECT_EQ(cellAt(b, 0, 1).codepoint, 0x4F60u);
    EXPECT_EQ(cellAt(b, 0, 1).attrs & kAttrWide, kAttrWide);

    EXPECT_EQ(cellAt(b, 0, 2).codepoint, kWideContinuation); // 续格 0xFFFFFFFF

    EXPECT_EQ(cellAt(b, 0, 3).codepoint, u'B');
    EXPECT_EQ(b.cursorCol(), 4); // 光标越过宽字符两格
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "A?B");
}

// ---- dirty 位图与 revision ----

TEST(VtermScreenTest, DirtyBitmapTracksWrittenRowsOnly)
{
    VtermBridge b(80, 24);
    b.grid().clearDirty(); // 构造期 reset 的标脏清掉，从干净状态开始
    b.feed("hello");
    EXPECT_TRUE(b.grid().isDirty(0));
    EXPECT_FALSE(b.grid().isDirty(1));
    EXPECT_FALSE(b.grid().isDirty(23));

    b.grid().clearDirty();
    for (int r = 0; r < 24; ++r)
        EXPECT_FALSE(b.grid().isDirty(r));

    b.feed("\x1b[10;1Hworld"); // 光标跳第 10 行写
    // 行 0 也脏：movecursor 把「光标离开的旧行」标脏（渲染层要在那里擦掉光标）
    EXPECT_TRUE(b.grid().isDirty(0));
    EXPECT_TRUE(b.grid().isDirty(9));
    EXPECT_FALSE(b.grid().isDirty(5)); // 与本次输入无关的行保持干净
}

TEST(VtermScreenTest, RevisionIncrementsOnFeed)
{
    VtermBridge b(80, 24);
    const uint64_t rev0 = b.grid().revision();
    b.feed("abc");
    const uint64_t rev1 = b.grid().revision();
    EXPECT_GT(rev1, rev0);
    b.feed("def");
    EXPECT_GT(b.grid().revision(), rev1);
    // 不喂数据 revision 不变（ArkTS 帧循环靠它跳过重绘）
    EXPECT_EQ(b.grid().revision(), b.grid().revision());
}

// ---- ED / EL ----

TEST(VtermScreenTest, EraseInDisplayClearsWholeScreen)
{
    VtermBridge b(80, 24);
    b.feed("aaa\r\nbbb\r\nccc");
    b.feed("\x1b[2J");
    for (int r = 0; r < 24; ++r)
        EXPECT_EQ(dumpGridRow(b.grid(), r), "") << "row " << r;
}

TEST(VtermScreenTest, EraseInDisplayUsesCurrentBackgroundColor)
{
    VtermBridge b(80, 24);
    b.feed("\x1b[42m\x1b[2J"); // BCE：清屏用当前背景色填空白格
    EXPECT_EQ(cellAt(b, 0, 0).codepoint, 0u);
    EXPECT_EQ(cellAt(b, 0, 0).bgArgb, kPaletteGreen);
    EXPECT_EQ(cellAt(b, 23, 79).bgArgb, kPaletteGreen);
}

TEST(VtermScreenTest, EraseInLineMode0ClearsFromCursorToEnd)
{
    VtermBridge b(80, 24);
    b.feed("abcdef");
    b.feed("\x1b[1;4H"); // 光标到第 4 列（0 基 3）
    b.feed("\x1b[K");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "abc");
}

TEST(VtermScreenTest, EraseInLineMode1ClearsFromStartToCursor)
{
    VtermBridge b(80, 24);
    b.feed("abcdef");
    b.feed("\x1b[1;4H");
    b.feed("\x1b[1K"); // 含光标格在内清 0..3 列
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "    ef");
}

TEST(VtermScreenTest, EraseInLineMode2ClearsWholeLine)
{
    VtermBridge b(80, 24);
    b.feed("abcdef\r\nghijkl");
    b.feed("\x1b[1;2H"); // 光标在第 1 行
    b.feed("\x1b[2K");
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "ghijkl"); // 下一行不受影响
}

// ---- bell / 标题 ----

TEST(VtermScreenTest, BellCountsAndFiresCallback)
{
    VtermBridge b(80, 24);
    int fired = 0;
    b.setBellCallback([&fired] { ++fired; });
    b.feed("\a\a");
    EXPECT_EQ(b.bellCount(), 2u);
    EXPECT_EQ(fired, 2);
}

TEST(VtermScreenTest, OscTitleAndIconNameCallbacks)
{
    VtermBridge b(80, 24);
    std::string gotTitle;
    std::string gotIcon;
    b.setTitleCallback([&gotTitle](const std::string &t) { gotTitle = t; });
    b.setIconNameCallback([&gotIcon](const std::string &t) { gotIcon = t; });

    b.feed("\x1b]0;My Title\a");
    EXPECT_EQ(b.title(), "My Title");
    EXPECT_EQ(gotTitle, "My Title");

    b.feed("\x1b]1;MyIcon\a");
    EXPECT_EQ(b.iconName(), "MyIcon");
    EXPECT_EQ(gotIcon, "MyIcon");
}

// ---- resize：内容按交集保留 ----

TEST(VtermScreenTest, ResizePreservesContentIntersection)
{
    VtermBridge b(10, 6);
    b.feed("AB\r\nCD");
    b.resize(20, 12);
    EXPECT_EQ(b.grid().cols(), 20);
    EXPECT_EQ(b.grid().rows(), 12);
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "AB");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "CD");
    // resize 后全部行标脏
    for (int r = 0; r < 12; ++r)
        EXPECT_TRUE(b.grid().isDirty(r));

    b.grid().clearDirty();
    b.resize(8, 2); // 缩小：裁掉多余行列
    EXPECT_EQ(dumpGridRow(b.grid(), 0), "AB");
    EXPECT_EQ(dumpGridRow(b.grid(), 1), "CD");
}
