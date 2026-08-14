/**
 * VtermBridge 实现 —— 见 vterm_screen.h 头注释。
 *
 * 实现要点（均与 libvterm 0.3.3 源码核对过）：
 * - 宽字符：libvterm 屏幕层在宽字符首格存 chars[0]=码点、width=2，
 *   续格存 chars[0]=(uint32_t)-1；转换时首格置 kAttrWide，续格码点原样落
 *   kWideContinuation（= 0xFFFFFFFF，与 DESIGN §2.2 一致）。
 * - alt-screen：vterm_screen_enable_altscreen(1) 后缓冲切换由库管理；
 *   切入时库会 erase 新缓冲（damage 覆盖全屏），切出时 damagescreen，
 *   两侧都经 damage 回调重读，网格自然恢复主屏内容。
 * - 滚动：moverect 返回 1 表示「我们自己拷贝了」，库不再重复 damage；
 *   全宽顶部滚动前库会先调 sb_pushline（槽位已注册、内容暂丢弃，T2 接存储）。
 * - dim：libvterm 0.3.3 屏幕层没有 dim 属性，kAttrDim 位预留不设置。
 * - DECSET 1006（SGR 鼠标编码）只进 libvterm 内部 mouse_protocol，不产生
 *   settermprop 事件；mouseMode() 反映的是 1000/1002/1003（VTERM_PROP_MOUSE），
 *   1004 经 VTERM_PROP_FOCUSREPORT 暴露。1006 的编码细节由库内部处理
 *   （vterm_mouse_button 生成上报序列时生效），本层无需跟踪。
 */
#include "vterm_screen.h"

#include <algorithm>
#include <cstring>

namespace sshclient {
namespace term {

// MouseMode 取值镜像 VTERM_PROP_MOUSE_*（头文件不暴露枚举原值，这里钉死对齐）
static_assert(static_cast<int>(MouseMode::kNone) == VTERM_PROP_MOUSE_NONE, "MouseMode 与 libvterm 取值不一致");
static_assert(static_cast<int>(MouseMode::kClick) == VTERM_PROP_MOUSE_CLICK, "MouseMode 与 libvterm 取值不一致");
static_assert(static_cast<int>(MouseMode::kDrag) == VTERM_PROP_MOUSE_DRAG, "MouseMode 与 libvterm 取值不一致");
static_assert(static_cast<int>(MouseMode::kMove) == VTERM_PROP_MOUSE_MOVE, "MouseMode 与 libvterm 取值不一致");

namespace {

// 内置默认调色板：xterm 近似 16 色（ARGB）。上层主题经 setPalette 注入覆盖。
constexpr std::array<uint32_t, 16> kXtermPalette = {
    0xFF000000u, // 0  黑
    0xFFCD0000u, // 1  红
    0xFF00CD00u, // 2  绿
    0xFFCDCD00u, // 3  黄
    0xFF0000EEu, // 4  蓝
    0xFFCD00CDu, // 5  品红
    0xFF00CDCDu, // 6  青
    0xFFE5E5E5u, // 7  白
    0xFF7F7F7Fu, // 8  亮黑（灰）
    0xFFFF0000u, // 9  亮红
    0xFF00FF00u, // 10 亮绿
    0xFFFFFF00u, // 11 亮黄
    0xFF5C5CFFu, // 12 亮蓝
    0xFFFF00FFu, // 13 亮品红
    0xFF00FFFFu, // 14 亮青
    0xFFFFFFFFu, // 15 亮白
};

constexpr uint32_t makeArgb(uint8_t r, uint8_t g, uint8_t b)
{
    return 0xFF000000u | (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8) | static_cast<uint32_t>(b);
}

// xterm 256 扩展色：16-231 为 6×6×6 立方体，232-255 为灰阶
uint32_t extendedPaletteColor(int idx)
{
    static constexpr uint8_t kLevels[6] = {0, 95, 135, 175, 215, 255};
    if (idx < 232) {
        const int n = idx - 16;
        return makeArgb(kLevels[n / 36], kLevels[(n / 6) % 6], kLevels[n % 6]);
    }
    const uint8_t gray = static_cast<uint8_t>(8 + 10 * (idx - 232));
    return makeArgb(gray, gray, gray);
}

VtermBridge *self(void *user)
{
    return static_cast<VtermBridge *>(user);
}

} // namespace

VtermBridge::VtermBridge(int cols, int rows, uint32_t defaultFgArgb, uint32_t defaultBgArgb)
    : grid_(cols, rows, defaultFgArgb, defaultBgArgb), palette_(kXtermPalette)
{
    // 注意 libvterm 的参数顺序是 (rows, cols)
    vt_ = vterm_new(rows, cols);
    vterm_set_utf8(vt_, 1); // 输入字节流按 UTF-8 解码（中文/emoji 前提）

    screen_ = vterm_obtain_screen(vt_);
    vterm_screen_enable_altscreen(screen_, 1); // 允许 DECSET 1047/1049 切备选缓冲

    static const VTermScreenCallbacks kCallbacks = {
        /*damage=*/&VtermBridge::onDamage,
        /*moverect=*/&VtermBridge::onMoveRect,
        /*movecursor=*/&VtermBridge::onMoveCursor,
        /*settermprop=*/&VtermBridge::onSetTermProp,
        /*bell=*/&VtermBridge::onBell,
        /*resize=*/&VtermBridge::onResize,
        /*sb_pushline=*/&VtermBridge::onSbPushLine,
        /*sb_popline=*/&VtermBridge::onSbPopLine,
        /*sb_clear=*/&VtermBridge::onSbClear,
    };
    vterm_screen_set_callbacks(screen_, &kCallbacks, this);

    // 行级合并 damage：回调按行区间批量到达，配合末尾 flush 不丢脏行
    vterm_screen_set_damage_merge(screen_, VTERM_DAMAGE_ROW);

    vterm_screen_reset(screen_, 1); // hard reset：清空缓冲并把 pen/光标归位
}

VtermBridge::~VtermBridge()
{
    if (vt_)
        vterm_free(vt_);
}

size_t VtermBridge::feed(const char *data, size_t len)
{
    const size_t consumed = vterm_input_write(vt_, data, len);
    // DAMAGE_ROW 合并模式下最后一行的 damage 处于挂起态，flush 保证脏行立即可见
    vterm_screen_flush_damage(screen_);
    return consumed;
}

void VtermBridge::resize(int cols, int rows)
{
    vterm_set_size(vt_, rows, cols); // onResize 回调里完成网格 resize
}

void VtermBridge::setDefaultColors(uint32_t fgArgb, uint32_t bgArgb)
{
    // 默认色影响空白格与 DEFAULT 色解析；vterm 缓冲是内容真源，
    // 换默认色后整屏重读一遍，用新默认色重新解析所有单元格
    grid_ = CellGrid(grid_.cols(), grid_.rows(), fgArgb, bgArgb);
    convertRect(0, 0, grid_.rows(), grid_.cols());
}

// ---------------------------------------------------------------- 回调

int VtermBridge::onDamage(VTermRect rect, void *user)
{
    self(user)->convertRect(rect.start_row, rect.start_col, rect.end_row, rect.end_col);
    return 1;
}

int VtermBridge::onMoveRect(VTermRect dest, VTermRect src, void *user)
{
    VtermBridge *b = self(user);
    const int rowCount = src.end_row - src.start_row;
    const int colCount = src.end_col - src.start_col;
    b->grid_.copyCells(dest.start_row, dest.start_col, src.start_row, src.start_col,
                       rowCount, colCount);
    return 1; // 已自行完成拷贝与标脏，库不再 damage 目标区
}

int VtermBridge::onMoveCursor(VTermPos pos, VTermPos oldpos, int visible, void *user)
{
    VtermBridge *b = self(user);
    b->cursorRow_ = pos.row;
    b->cursorCol_ = pos.col;
    b->cursorVisible_ = visible != 0;
    // 新旧光标格都要重绘（旧格去光标、新格画光标）
    if (oldpos.row >= 0 && oldpos.row < b->grid_.rows())
        b->grid_.setDirty(oldpos.row);
    if (pos.row >= 0 && pos.row < b->grid_.rows())
        b->grid_.setDirty(pos.row);
    return 1;
}

int VtermBridge::onSetTermProp(VTermProp prop, VTermValue *val, void *user)
{
    VtermBridge *b = self(user);
    switch (prop) {
    case VTERM_PROP_TITLE:
        b->accumulatePropString(/*isTitle=*/true, val->string);
        return 1;
    case VTERM_PROP_ICONNAME:
        b->accumulatePropString(/*isTitle=*/false, val->string);
        return 1;
    case VTERM_PROP_ALTSCREEN:
        b->altScreen_ = val->boolean != 0;
        // 屏幕层在本回调之前已完成缓冲切换；库在切入/切出时的 damage 覆盖
        // 依赖内部时序（切入靠 erase 的 damage、切出靠 damagescreen），
        // 这里直接全屏重读一次，两个方向都确定性地落到新缓冲内容
        b->convertRect(0, 0, b->grid_.rows(), b->grid_.cols());
        return 1;
    case VTERM_PROP_CURSORVISIBLE:
        b->cursorVisible_ = val->boolean != 0;
        return 1;
    case VTERM_PROP_MOUSE:
        b->mouseMode_ = static_cast<MouseMode>(val->number);
        return 1;
    case VTERM_PROP_FOCUSREPORT:
        b->focusReport_ = val->boolean != 0;
        return 1;
    default:
        return 1; // CURSORBLINK/CURSORSHAPE/REVERSE 等：暂只吞掉，UI 需要时再记录
    }
}

int VtermBridge::onBell(void *user)
{
    VtermBridge *b = self(user);
    ++b->bellCount_;
    if (b->bellCallback_)
        b->bellCallback_();
    return 1;
}

int VtermBridge::onResize(int rows, int cols, void *user)
{
    VtermBridge *b = self(user);
    b->grid_.resize(cols, rows); // 行列交集保留内容，全部行标脏
    if (b->cursorRow_ >= rows)
        b->cursorRow_ = rows - 1;
    if (b->cursorCol_ >= cols)
        b->cursorCol_ = cols - 1;
    return 1;
}

// TODO(T2)：回滚缓冲槽位。当前不存储，滚动顶出的行直接丢弃。
int VtermBridge::onSbPushLine(int /*cols*/, const VTermScreenCell * /*cells*/, void * /*user*/)
{
    return 0;
}

int VtermBridge::onSbPopLine(int /*cols*/, VTermScreenCell * /*cells*/, void * /*user*/)
{
    return 0; // 0 = 没有可回滚的行，库填入空白行
}

int VtermBridge::onSbClear(void * /*user*/)
{
    return 0; // 0 = 未处理（ED 3 清回滚对本层是空操作）
}

// ---------------------------------------------------------------- 内部逻辑

void VtermBridge::convertRect(int startRow, int startCol, int endRow, int endCol)
{
    // 防御性裁剪：resize 竞态下 damage 矩形可能超出当前网格
    startRow = std::max(startRow, 0);
    startCol = std::max(startCol, 0);
    endRow = std::min(endRow, grid_.rows());
    endCol = std::min(endCol, grid_.cols());

    for (int row = startRow; row < endRow; ++row) {
        for (int col = startCol; col < endCol; ++col) {
            VTermPos pos = {row, col};
            VTermScreenCell vc;
            if (!vterm_screen_get_cell(screen_, pos, &vc))
                continue;

            Cell cell;
            cell.codepoint = vc.chars[0]; // 含 kWideContinuation 续格标记原样透传
            // 组合字符（chars[1..5]）暂只取基础码点；渲染层画组合符是 T4 之后的事
            cell.fgArgb = resolveColor(vc.fg, /*isForeground=*/true, vc.attrs.bold != 0);
            cell.bgArgb = resolveColor(vc.bg, /*isForeground=*/false, false);
            uint16_t attrs = 0;
            if (vc.attrs.bold)
                attrs |= kAttrBold;
            if (vc.attrs.italic)
                attrs |= kAttrItalic;
            if (vc.attrs.underline)
                attrs |= kAttrUnderline;
            if (vc.attrs.blink)
                attrs |= kAttrBlink;
            if (vc.attrs.reverse)
                attrs |= kAttrReverse;
            if (vc.attrs.strike)
                attrs |= kAttrStrike;
            if (vc.width == 2)
                attrs |= kAttrWide;
            cell.attrs = attrs;
            cell.reserved = 0;

            grid_.putCell(row, col, cell);
        }
    }
}

uint32_t VtermBridge::resolveColor(const VTermColor &color, bool isForeground, bool cellBold) const
{
    if (isForeground && VTERM_COLOR_IS_DEFAULT_FG(&color))
        return grid_.defaultFgArgb();
    if (!isForeground && VTERM_COLOR_IS_DEFAULT_BG(&color))
        return grid_.defaultBgArgb();

    if (VTERM_COLOR_IS_INDEXED(&color)) {
        int idx = color.indexed.idx;
        // bold-as-bright：粗体前景的低 8 色映射到高 8 色（仅前景，背景不提亮）
        if (isForeground && cellBold && boldAsBright_ && idx < 8)
            idx += 8;
        if (idx < 16)
            return palette_[static_cast<size_t>(idx)];
        return extendedPaletteColor(idx);
    }

    // VTERM_COLOR_RGB：真彩
    return makeArgb(color.rgb.red, color.rgb.green, color.rgb.blue);
}

void VtermBridge::accumulatePropString(bool isTitle, const VTermStringFragment &frag)
{
    // libvterm 超长 OSC 字符串会分片回调：initial 起新串，final 收尾上抛
    std::string &buf = isTitle ? propBufTitle_ : propBufIcon_;
    if (frag.initial)
        buf.clear();
    buf.append(frag.str, frag.len);
    if (!frag.final)
        return;

    std::string &target = isTitle ? title_ : iconName_;
    target = buf;
    const auto &cb = isTitle ? titleCallback_ : iconNameCallback_;
    if (cb)
        cb(target);
}

} // namespace term
} // namespace sshclient
