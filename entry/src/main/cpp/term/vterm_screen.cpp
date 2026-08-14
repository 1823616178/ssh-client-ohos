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
 * - 滚动：moverect 返回 0，由库把目标区标 damage、我们按 damage 重读最终内容
 *   （不自行镜像拷贝，原因见 onMoveRect 注释：DAMAGE_ROW 合并下镜像会读到滞后行）。
 *   全宽顶部滚动前库会先调 sb_pushline（T2：顶出行进 ScrollbackBuffer）。
 *   libvterm 0.3.3 只在主屏（PRIMARY buffer）触发 sb_pushline/sb_popline
 *   （screen.c moverect_internal / resize_buffer 的 BUFIDX_PRIMARY 检查），
 *   alt-screen 滚动天然不进回滚——回滚缓冲只属于主屏（DESIGN §4.4：alt 屏
 *   下滚动改发方向键/滚轮序列）。
 * - resize 行数变化时库直接操作回滚：缩行把放不下的主屏行经 sb_pushline 顶出，
 *   增行经 sb_popline 回填顶部空行（libvterm 只在此时拉 popline，别无路径）；
 *   两个回调发生时本层 onResize 尚未被调，回滚行宽与库传入的 old_cols 一致，
 *   onResize 里再统一 resizeCols 到新宽度。
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

// Cell → VTermScreenCell（sb_popline 回填）。颜色无法还原索引/默认色来源，
// 统一按真彩 RGB 回填——显示效果与 push 时解析结果一致；组合字符（chars[1..5]）、
// conceal/font/dwl/dhl 等本层不存的字段随快照丢弃（grid.h 布局本就不含它们）。
void storeVtermCell(const Cell &cell, VTermScreenCell *out)
{
    std::memset(out, 0, sizeof(*out)); // chars 全 0（零终止）、attrs 位域全 0
    out->chars[0] = cell.codepoint;    // kWideContinuation(0xFFFFFFFF) = 库的续格 (uint32_t)-1
    // width 必须 ≥1：库按 sb_buffer[col].width 步进，0 会死循环；
    // 续格宽度填 1 即可——宽字符首格 width=2 时库自行写续格，不读我们的续格内容
    out->width = (cell.attrs & kAttrWide) ? 2 : 1;
    out->attrs.bold = (cell.attrs & kAttrBold) != 0;
    out->attrs.underline = (cell.attrs & kAttrUnderline) ? VTERM_UNDERLINE_SINGLE : VTERM_UNDERLINE_OFF;
    out->attrs.italic = (cell.attrs & kAttrItalic) != 0;
    out->attrs.blink = (cell.attrs & kAttrBlink) != 0;
    // 显示态 reverse：库回填时 ^ global_reverse 得 pen.reverse，之后 get_cell 再异或回来，
    // 无论 global_reverse 开关都自洽
    out->attrs.reverse = (cell.attrs & kAttrReverse) != 0;
    out->attrs.strike = (cell.attrs & kAttrStrike) != 0;
    vterm_color_rgb(&out->fg, static_cast<uint8_t>(cell.fgArgb >> 16),
                    static_cast<uint8_t>(cell.fgArgb >> 8), static_cast<uint8_t>(cell.fgArgb));
    vterm_color_rgb(&out->bg, static_cast<uint8_t>(cell.bgArgb >> 16),
                    static_cast<uint8_t>(cell.bgArgb >> 8), static_cast<uint8_t>(cell.bgArgb));
}

} // namespace

VtermBridge::VtermBridge(int cols, int rows, uint32_t defaultFgArgb, uint32_t defaultBgArgb,
                         size_t scrollbackCapacity)
    : grid_(cols, rows, defaultFgArgb, defaultBgArgb),
      scrollback_(cols, scrollbackCapacity),
      sbScratch_(static_cast<size_t>(cols)),
      palette_(kXtermPalette)
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
    const uint64_t oldRevision = grid_.revision();
    grid_ = CellGrid(grid_.cols(), grid_.rows(), fgArgb, bgArgb);
    // 重建后 revision 从 0 重计数会对外回退，抬回旧值保单调不减（T1 审查跟进项）；
    // 随后 convertRect 逐格 putCell 让 revision 从旧值继续增长——内容全变了必须重绘
    grid_.raiseRevisionFloor(oldRevision);
    convertRect(0, 0, grid_.rows(), grid_.cols());
}

// ---------------------------------------------------------------- 回调

int VtermBridge::onDamage(VTermRect rect, void *user)
{
    self(user)->convertRect(rect.start_row, rect.start_col, rect.end_row, rect.end_col);
    return 1;
}

int VtermBridge::onMoveRect(VTermRect /*dest*/, VTermRect /*src*/, void * /*user*/)
{
    // 不自行镜像拷贝，返回 0 让库把 dest 区标 damage、随后按 damage 重读最终内容。
    // T1 曾返回 1（自己 copyCells、库不再 damage）：DAMAGE_ROW 合并下滚动前写入底行的
    // damage 会被库延迟到内部滚动之后才 flush（读到滚动后的内容），此刻我们网格里的
    // 对应行是滞后的，自行 copyCells 把滞后内容扩散——T2 连续输出测试暴露：同一 feed
    // 内「底行写入紧接着滚动」时网格丢行（回滚缓冲反而正确：sb_pushline 直读库缓冲）。
    // 滚动 dest 通常覆盖滚动区全部行，重读成本与渲染层脏行重绘同量级，正确性优先。
    return 0;
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
    // 纯光标移动不写任何单元格，但不重绘会丢光标帧：抬 revision 让帧循环感知
    // （T1 审查跟进项）。决策：选「movecursor 抬 revision」而非另设光标快照比对位——
    // 帧循环判定只有一个 revision 通道，复用它最简单且语义正确（revision = 需要重绘的修订号）。
    b->grid_.bumpRevision();
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
        if (b->mouseModeCallback_)
            b->mouseModeCallback_(b->mouseMode_);
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
    // libvterm 的 damagescreen 先于本回调触发，那时网格还是旧尺寸，convertRect
    // 防御性裁剪会把新增行列丢掉；行数增大时库还可能刚经 sb_popline 回填了顶部行。
    // 网格就位后整屏重读一遍，保证与 vterm 缓冲严格一致（resize 低频，代价可忽略）。
    b->convertRect(0, 0, rows, cols);
    // 回滚行宽跟随新 cols：宽改窄截断、窄改宽补空白格。resize_buffer 期间的
    // sb_pushline/sb_popline 以旧 cols 与本缓冲交互（本回调晚于它们触发），
    // 故 resizeCols 在这里、即「下一次 sb 回调之前」完成即可保持宽度一致。
    b->scrollback_.resizeCols(cols, b->grid_.blankCell());
    b->sbScratch_.assign(static_cast<size_t>(cols), Cell{});
    if (b->cursorRow_ >= rows)
        b->cursorRow_ = rows - 1;
    if (b->cursorCol_ >= cols)
        b->cursorCol_ = cols - 1;
    return 1;
}

int VtermBridge::onSbPushLine(int cols, const VTermScreenCell *cells, void *user)
{
    VtermBridge *b = self(user);
    // libvterm 0.3.3 仅主屏触发本回调（见文件头「滚动」注），这里无需再判 alt-screen。
    // 正常路径 cols == scrollback_.cols()；resize 竞态下防御性截断。
    const int n = std::min(cols, b->scrollback_.cols());
    for (int c = 0; c < n; ++c)
        b->sbScratch_[static_cast<size_t>(c)] = b->convertCell(cells[c]);
    b->scrollback_.pushLine(b->sbScratch_.data(), static_cast<size_t>(n));
    return 1;
}

int VtermBridge::onSbPopLine(int cols, VTermScreenCell *cells, void *user)
{
    VtermBridge *b = self(user);
    // libvterm 0.3.3 只在「resize 行数增大」时经本回调回填屏幕顶部空行，
    // cols 为旧列宽（与回滚当前行宽一致，resizeCols 尚未走）；库按我们填的
    // cell.width 步进拷贝（width 必须 ≥1），宽字符续格由库自行置 (uint32_t)-1。
    // popline 是 resize 低频路径，局部 vector 可接受（push 高频路径才用 sbScratch_）。
    std::vector<Cell> line(static_cast<size_t>(std::min(cols, b->scrollback_.cols())));
    if (line.empty() || !b->scrollback_.popLine(line.data()))
        return 0; // 0 = 没有可回滚的行，库填入空白行
    for (size_t c = 0; c < line.size(); ++c)
        storeVtermCell(line[c], &cells[c]);
    return 1;
}

int VtermBridge::onSbClear(void *user)
{
    // ED 3（CSI 3 J）：清回滚。libvterm 自身不存回滚，语义全在本层，返回 1 = 已处理
    self(user)->scrollback_.clear();
    return 1;
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
            grid_.putCell(row, col, convertCell(vc));
        }
    }
}

Cell VtermBridge::convertCell(const VTermScreenCell &vc) const
{
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
    return cell;
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
