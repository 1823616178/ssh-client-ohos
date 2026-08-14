/**
 * VtermBridge —— libvterm 屏幕层封装（任务 T1，DESIGN §2.2）。
 *
 * 职责：包装 libvterm（vterm_new + vterm_obtain_screen + 回调 + reset），
 * 把终端状态机落到连续内存的 CellGrid：
 *   feed(bytes)   → vterm_input_write，结束后 flush damage
 *   resize        → vterm_set_size，网格按交集保留内容
 *   damage        → 逐格 vterm_screen_get_cell 重读并写入网格（含颜色解析）
 *   moverect      → 网格内拷贝（滚动场景，sb_pushline 见下方 TODO）
 *   movecursor    → 记录光标位置，新旧光标行标脏
 *   settermprop   → 标题/图标名/光标可见性/鼠标模式/alt-screen 等状态记录
 *   bell          → 计数 + 回调上抛（UI 触感）
 *
 * 本头文件包含 <vterm.h>（回调签名需要 VTermRect/VTermPos 等类型）；
 * 禁止 include <napi/native_api.h> / <hilog/log.h>。
 *
 * TODO(T2)：sb_pushline / sb_popline / sb_clear 回调槽位已注册但内部为空，
 * 回滚缓冲（环形缓冲 5000 行）由任务 T2 实现；本任务滚动顶出的行直接丢弃。
 */
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

#include <vterm.h>

#include "grid.h"

namespace sshclient {
namespace term {

// 鼠标上报模式（镜像 vterm.h 的 VTERM_PROP_MOUSE_* 取值，.cpp 里 static_assert 对齐）
enum class MouseMode {
    kNone = 0,  // 未开启
    kClick = 1, // DECSET 1000：点击/释放
    kDrag = 2,  // DECSET 1002：点击 + 拖动
    kMove = 3,  // DECSET 1003：任意移动
};

class VtermBridge {
public:
    // 默认色由上层外观系统给；未给时用 xterm 近似（亮白字/黑底）
    static constexpr uint32_t kDefaultFgArgb = 0xFFE5E5E5u;
    static constexpr uint32_t kDefaultBgArgb = 0xFF000000u;

    VtermBridge(int cols, int rows,
                uint32_t defaultFgArgb = kDefaultFgArgb,
                uint32_t defaultBgArgb = kDefaultBgArgb);
    ~VtermBridge();

    VtermBridge(const VtermBridge &) = delete;
    VtermBridge &operator=(const VtermBridge &) = delete;

    // 喂字节流（SSH 通道读到的原始数据），返回 libvterm 消费的字节数
    size_t feed(const char *data, size_t len);
    size_t feed(const std::string &s) { return feed(s.data(), s.size()); }

    void resize(int cols, int rows);

    CellGrid &grid() { return grid_; }
    const CellGrid &grid() const { return grid_; }

    // 终端状态查询（供 UI 层）
    int cursorRow() const { return cursorRow_; }
    int cursorCol() const { return cursorCol_; }
    bool cursorVisible() const { return cursorVisible_; }
    bool altScreenActive() const { return altScreen_; }
    MouseMode mouseMode() const { return mouseMode_; }
    bool focusReportEnabled() const { return focusReport_; }
    const std::string &title() const { return title_; }
    const std::string &iconName() const { return iconName_; }
    uint64_t bellCount() const { return bellCount_; }

    // 事件上抛回调（注入点；不注入则只更新内部状态）
    void setTitleCallback(std::function<void(const std::string &)> cb) { titleCallback_ = std::move(cb); }
    void setIconNameCallback(std::function<void(const std::string &)> cb) { iconNameCallback_ = std::move(cb); }
    void setBellCallback(std::function<void()> cb) { bellCallback_ = std::move(cb); }

    // 配色注入：16 色调色板（ARGB）；256 扩展色按 xterm 公式推导，不可单独注入
    void setPalette(const std::array<uint32_t, 16> &argb) { palette_ = argb; }
    // bold-as-bright：粗体且前景为索引色 0-7 时映射到 8-15（默认开）
    void setBoldAsBright(bool on) { boldAsBright_ = on; }
    void setDefaultColors(uint32_t fgArgb, uint32_t bgArgb);

private:
    // ---- libvterm 回调（静态 thunk → 成员逻辑）----
    static int onDamage(VTermRect rect, void *user);
    static int onMoveRect(VTermRect dest, VTermRect src, void *user);
    static int onMoveCursor(VTermPos pos, VTermPos oldpos, int visible, void *user);
    static int onSetTermProp(VTermProp prop, VTermValue *val, void *user);
    static int onBell(void *user);
    static int onResize(int rows, int cols, void *user);
    static int onSbPushLine(int cols, const VTermScreenCell *cells, void *user);
    static int onSbPopLine(int cols, VTermScreenCell *cells, void *user);
    static int onSbClear(void *user);

    // 把 damage 矩形内的 libvterm 单元格重读进网格
    void convertRect(int startRow, int startCol, int endRow, int endCol);
    // VTermColor → ARGB（默认色 / 16 色注入调色板 / 256 扩展公式 / 真彩 / bold-as-bright）
    uint32_t resolveColor(const VTermColor &color, bool isForeground, bool cellBold) const;
    void accumulatePropString(bool isTitle, const VTermStringFragment &frag);

    VTerm *vt_ = nullptr;
    VTermScreen *screen_ = nullptr;
    CellGrid grid_;

    // 终端状态
    int cursorRow_ = 0;
    int cursorCol_ = 0;
    bool cursorVisible_ = true;
    bool altScreen_ = false;
    MouseMode mouseMode_ = MouseMode::kNone;
    bool focusReport_ = false;
    std::string title_;
    std::string iconName_;
    uint64_t bellCount_ = 0;

    // 配色
    std::array<uint32_t, 16> palette_{};
    bool boldAsBright_ = true;

    // OSC 字符串分片累积（libvterm 超长字符串会分多片回调）
    std::string propBufTitle_;
    std::string propBufIcon_;

    std::function<void(const std::string &)> titleCallback_;
    std::function<void(const std::string &)> iconNameCallback_;
    std::function<void()> bellCallback_;
};

} // namespace term
} // namespace sshclient
