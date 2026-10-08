/**
 * 终端模式 / 应答输出 / 光标外观单测 —— ux/terminal-pass。
 *
 * 覆盖：
 *   - vterm_output_set_callback：DSR（CSI 6n）等应答经输出回调回写；
 *   - DECCKM（DECSET 1）经 vterm_keyboard_key 探测，变化回调一次；探测输出不外泄；
 *   - DECSET 2004 括号粘贴探测；
 *   - DECSCUSR 光标形状/闪烁覆盖，「闪烁块」与单独 DECSET 12 视为未覆盖；
 *   - FrameSync 发布上述字段与回滚 epoch。
 */
#include <gtest/gtest.h>

#include <string>
#include <vector>

#include "term/frame_sync.h"
#include "term/vterm_screen.h"

using sshclient::term::FrameSync;
using sshclient::term::GridFrame;
using sshclient::term::VtermBridge;

namespace {

struct Captured {
    std::string output;
    std::vector<std::pair<bool, bool>> modes;
};

void wire(VtermBridge &b, Captured &cap)
{
    b.setOutputCallback([&cap](const char *d, size_t n) { cap.output.append(d, n); });
    b.setModesCallback([&cap](bool app, bool bp) { cap.modes.emplace_back(app, bp); });
}

} // namespace

TEST(TerminalModesTest, DeviceStatusReportIsWrittenBack)
{
    VtermBridge b(80, 24);
    Captured cap;
    wire(b, cap);
    b.feed("\x1b[5;7H\x1b[6n");
    EXPECT_EQ(cap.output, "\x1b[5;7R");
}

TEST(TerminalModesTest, ApplicationCursorKeysProbedViaKeyboardKey)
{
    VtermBridge b(80, 24);
    Captured cap;
    wire(b, cap);
    EXPECT_FALSE(b.applicationCursorKeys());
    b.feed("hello");
    EXPECT_TRUE(cap.modes.empty()); // 无变化不回调
    EXPECT_TRUE(cap.output.empty()); // 探测序列绝不外泄到远端
    b.feed("\x1b[?1h");
    EXPECT_TRUE(b.applicationCursorKeys());
    ASSERT_EQ(cap.modes.size(), 1u);
    EXPECT_TRUE(cap.modes[0].first);
    EXPECT_FALSE(cap.modes[0].second);
    b.feed("\x1b[?1l");
    EXPECT_FALSE(b.applicationCursorKeys());
    ASSERT_EQ(cap.modes.size(), 2u);
    EXPECT_TRUE(cap.output.empty());
}

TEST(TerminalModesTest, BracketedPasteProbed)
{
    VtermBridge b(80, 24);
    Captured cap;
    wire(b, cap);
    b.feed("\x1b[?2004h");
    EXPECT_TRUE(b.bracketedPaste());
    ASSERT_EQ(cap.modes.size(), 1u);
    EXPECT_TRUE(cap.modes[0].second);
    b.feed("\x1b[?2004l");
    EXPECT_FALSE(b.bracketedPaste());
    EXPECT_TRUE(cap.output.empty());
}

TEST(TerminalModesTest, CursorShapeOverrides)
{
    VtermBridge b(80, 24);
    EXPECT_EQ(b.cursorShapeOverride(), 0);
    EXPECT_EQ(b.cursorBlinkOverride(), -1);

    const uint64_t rev = b.grid().revision();
    b.feed("\x1b[6 q"); // 稳定竖线
    EXPECT_EQ(b.cursorShapeOverride(), VTERM_PROP_CURSORSHAPE_BAR_LEFT);
    EXPECT_EQ(b.cursorBlinkOverride(), 0);
    EXPECT_GT(b.grid().revision(), rev); // 外观变化触发重绘

    b.feed("\x1b[3 q"); // 闪烁下划线
    EXPECT_EQ(b.cursorShapeOverride(), VTERM_PROP_CURSORSHAPE_UNDERLINE);
    EXPECT_EQ(b.cursorBlinkOverride(), 1);

    b.feed("\x1b[2 q"); // 稳定块：显式覆盖
    EXPECT_EQ(b.cursorShapeOverride(), VTERM_PROP_CURSORSHAPE_BLOCK);
    EXPECT_EQ(b.cursorBlinkOverride(), 0);

    b.feed("\x1b[0 q"); // 复位 = 闪烁块 = 回到用户偏好
    EXPECT_EQ(b.cursorShapeOverride(), 0);
    EXPECT_EQ(b.cursorBlinkOverride(), -1);

    b.feed("\x1b[?12l"); // 单独 DECSET 12（vim t_ve）不改变覆盖
    EXPECT_EQ(b.cursorShapeOverride(), 0);
    EXPECT_EQ(b.cursorBlinkOverride(), -1);
}

TEST(TerminalModesTest, FramePublishesModesAndEpoch)
{
    VtermBridge b(10, 3);
    FrameSync sync;
    b.feed("\x1b[?1h\x1b[?2004h\x1b[5 q");
    for (int i = 0; i < 5; ++i)
        b.feed("x\r\n");
    sync.publish(b);
    GridFrame f = sync.snapshot();
    EXPECT_TRUE(f.applicationCursorKeys);
    EXPECT_TRUE(f.bracketedPaste);
    EXPECT_EQ(f.cursorShape, VTERM_PROP_CURSORSHAPE_BAR_LEFT);
    EXPECT_EQ(f.cursorBlink, 1);
    const uint64_t e = f.scrollbackEpoch;
    b.resize(8, 3);
    sync.publish(b);
    EXPECT_GT(sync.snapshot().scrollbackEpoch, e);
}
