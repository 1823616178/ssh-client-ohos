/**
 * TerminalGestures —— 滚动/缩放/连点选词/SGR 鼠标上报的纯逻辑核心
 * （任务 T9 + T11，DESIGN §4.3.2 / §4.4）。ArkUI 手势事件接线在
 * TerminalCanvas，本文件只交付可 hypium 覆盖的判定/换算：
 *
 *  - ScrollLineAccumulator：拖动像素增量 → 整行数（不足一行的余量跨事件累计）；
 *  - clampScrollOffset / clampFontSize：回滚偏移与字号钳制；
 *  - buildAltScrollSequences：alt-screen 竖滑 → 方向键或 SGR 滚轮
 *    （applicationCursorKeys=true 时方向键走 DECCKM SS3 形式，T10）；
 *  - clickSelectionMode / ClickSelectTracker：双击选词、三击选行的连点判定；
 *  - wordSelectAt / lineSelectAt：词/行选区边界（CJK/emoji 宽字符不切半个字）；
 *  - encodeSgrMouseEvent：xterm DECSET 1006 SGR 1006 press/move/release/滚轮序列。
 *
 * 方向约定：deltaYPx > 0 = 手指向下移动。
 */

/** alt-screen 下单指竖滑行为：keys=方向键 / mouse=SGR 滚轮 / view=视图滚动 */
export type AltScrollMode = 'keys' | 'mouse' | 'view';

/** 鼠标上报模式「关」（镜像 native MouseMode::kNone，vterm_screen.h） */
export const MOUSE_MODE_NONE = 0;
/** 鼠标上报：点击（DECSET 1000） */
export const MOUSE_MODE_CLICK = 1;
/** 鼠标上报：拖动（DECSET 1002） */
export const MOUSE_MODE_DRAG = 2;
/** 鼠标上报：任意移动（DECSET 1003） */
export const MOUSE_MODE_ANY = 3;

/** 捏合字号范围（DESIGN §4.4：8–32） */
export const MIN_FONT_SIZE = 8;
export const MAX_FONT_SIZE = 32;

/** 宽字符续格码点（与 napi/SshTerminal.WIDE_CONTINUATION 同值；本文件独立常量避免测试耦合） */
export const CLICK_WIDE_CONTINUATION = 0xFFFFFFFF;

// ---------------------------------------------------------------- 滚动

/** 拖动像素 → 整行数换算器（每次手势 begin 时 reset） */
export class ScrollLineAccumulator {
  private remainderPx = 0;

  /**
   * 累计一次拖动增量，返回本次应滚动的带符号整行数
   * （正 = 手指下移；余量留到下次累计）。
   */
  push(deltaYPx: number, cellHeightPx: number): number {
    if (cellHeightPx <= 0) {
      return 0; // 度量未完成（启动瞬间）：不累计不滚动
    }
    this.remainderPx += deltaYPx;
    const lines = Math.trunc(this.remainderPx / cellHeightPx);
    this.remainderPx -= lines * cellHeightPx;
    return lines;
  }

  /** 手势开始/结束复位余量 */
  reset(): void {
    this.remainderPx = 0;
  }
}

/** 回滚视图偏移钳制到 [0, maxOffset]；maxOffset 为负（无回滚）按 0 处理 */
export function clampScrollOffset(offset: number, maxOffset: number): number {
  const cap = maxOffset > 0 ? maxOffset : 0;
  if (offset < 0) {
    return 0;
  }
  return offset > cap ? cap : offset;
}

/** 捏合字号钳制 8–32；非法输入（NaN/Infinity）回退边界内最近值 */
export function clampFontSize(size: number): number {
  if (!isFinite(size)) {
    return MIN_FONT_SIZE;
  }
  if (size < MIN_FONT_SIZE) {
    return MIN_FONT_SIZE;
  }
  return size > MAX_FONT_SIZE ? MAX_FONT_SIZE : size;
}

/**
 * 捏合松手时的最终字号：起始字号 × 倍率 → 取整 → 钳制。
 * 取整让字号落在整数档（字形度量缓存命中、与设置页步进一致），手势过程中只做
 * 画面缩放预览，松手才真正重排一次（一次 PTY resize）。
 */
export function pinchCommitFontSize(baseFontSize: number, scale: number): number {
  if (!isFinite(scale) || scale <= 0) {
    return clampFontSize(baseFontSize);
  }
  return clampFontSize(Math.round(baseFontSize * scale));
}

/** 捏合预览的画面缩放倍率（连续跟手；已按字号上下限钳制，到边界后不再放大/缩小） */
export function pinchPreviewScale(baseFontSize: number, scale: number): number {
  if (!(baseFontSize > 0) || !isFinite(scale) || scale <= 0) {
    return 1;
  }
  return clampFontSize(baseFontSize * scale) / baseFontSize;
}

/**
 * alt-screen 竖滑 → 发送序列集合（每累计一行一条）：
 *   - mode='mouse' 且终端已开鼠标上报（mouseMode ≠ None）→ SGR 滚轮
 *     \e[<64;x;yM（上滚）/ \e[<65;x;yM（下滚），x/y 为 1 起网格坐标；
 *   - mode='mouse' 但 mouseMode = None → 回退方向键；
 *   - mode='keys' → 方向键；applicationCursorKeys=true（DECCKM）时发 SS3
 *     \eOA / \eOB（T10：alt-screen 方向键随 DECCKM 切 SS3）；
 *   - mode='view' → 空数组（视图滚动由组件本地处理）。
 *
 * @param lines 带符号行数（正 = 手指下移 = 看旧内容 = 上滚）
 * @param col1/row1 手指所在网格坐标（1 起，SGR 鼠标序列用；keys 模式忽略）
 * @param applicationCursorKeys DECCKM 应用光标键模式（缺省 false）
 */
export function buildAltScrollSequences(mode: AltScrollMode, mouseMode: number, lines: number,
  col1: number, row1: number, applicationCursorKeys: boolean = false): Uint8Array[] {
  const result: Uint8Array[] = [];
  if (lines === 0 || mode === 'view') {
    return result;
  }
  const up = lines > 0;
  const count = up ? lines : -lines;
  const useMouse = mode === 'mouse' && mouseMode !== MOUSE_MODE_NONE;
  for (let i = 0; i < count; i++) {
    result.push(useMouse ? sgrMouseWheel(up, col1, row1) : arrowKey(up, applicationCursorKeys));
  }
  return result;
}

/** 方向键序列：普通模式 CSI A/B；DECCKM 应用光标模式 SS3 A/B */
function arrowKey(up: boolean, applicationCursorKeys: boolean): Uint8Array {
  if (applicationCursorKeys) {
    return asciiSeq(up ? '\x1bOA' : '\x1bOB');
  }
  return asciiSeq(up ? '\x1b[A' : '\x1b[B');
}

/** SGR 鼠标滚轮序列：64=上滚 65=下滚，坐标 1 起（xterm DECSET 1006 惯例） */
function sgrMouseWheel(up: boolean, col1: number, row1: number): Uint8Array {
  const button = up ? 64 : 65;
  return asciiSeq(`\x1b[<${button};${col1};${row1}M`);
}

// ---------------------------------------------------------------- T11 连点选词/选行

/** 连点选区模式：none=单击 / word=双击选词 / line=三击选行 */
export type ClickSelectionMode = 'none' | 'word' | 'line';

/** 双击窗口（ms）与位置容差（格）；超窗或超距则连点计数重置 */
export const DOUBLE_CLICK_WINDOW_MS = 400;
export const CLICK_POSITION_SLOP_CELLS = 2;

/** 选词字符类别：space=空白 / word=ASCII 词字符 / wide=CJK·emoji / other=标点等 */
export type ClickCharClass = 'space' | 'word' | 'wide' | 'other';

/** 连点格子快照（codepoint=0 表示空格；续格码点 = CLICK_WIDE_CONTINUATION） */
export interface ClickSelectCell {
  readonly codepoint: number;
  /** 宽字符首格（ATTR_WIDE）；续格可不设，靠 codepoint 判定 */
  readonly wide: boolean;
}

/** 连点选区用网格抽象（TerminalCanvas 用帧 DataView 适配；测试可徒手构造） */
export interface ClickSelectGrid {
  readonly rows: number;
  readonly cols: number;
  cellAt(row: number, col: number): ClickSelectCell | null;
}

/** 规范化选区（与 SelectionModel.SelectionRange 同形，本文件独立定义避免环依赖） */
export interface ClickSelectionRange {
  startRow: number;
  startCol: number;
  endRow: number;
  endCol: number;
}

/** 连点次数 → 选区模式（3+ 按行，2 按词，其余无） */
export function clickSelectionMode(clickCount: number): ClickSelectionMode {
  if (clickCount >= 3) {
    return 'line';
  }
  if (clickCount === 2) {
    return 'word';
  }
  return 'none';
}

/**
 * 连点状态机：tap 在双击窗口内、位置邻近（容差格）时递增计数，否则从 1 重计。
 * 调用方在拖动/选择模式退出时 reset。
 */
export class ClickSelectTracker {
  private lastTimeMs = 0;
  private lastRow = -1;
  private lastCol = -1;
  private count = 0;

  /** 记录一次点按，返回本次连点应触发的选区模式 */
  tap(row: number, col: number, nowMs: number,
    windowMs: number = DOUBLE_CLICK_WINDOW_MS,
    slopCells: number = CLICK_POSITION_SLOP_CELLS): ClickSelectionMode {
    const near: boolean = this.count > 0 &&
      Math.abs(row - this.lastRow) <= slopCells &&
      Math.abs(col - this.lastCol) <= slopCells;
    if (near && nowMs - this.lastTimeMs <= windowMs) {
      this.count++;
    } else {
      this.count = 1;
    }
    this.lastTimeMs = nowMs;
    this.lastRow = row;
    this.lastCol = col;
    return clickSelectionMode(this.count);
  }

  /** 当前连点计数（测试/诊断用） */
  get clickCount(): number {
    return this.count;
  }

  reset(): void {
    this.count = 0;
    this.lastTimeMs = 0;
    this.lastRow = -1;
    this.lastCol = -1;
  }
}

/**
 * 码点 + 宽字符标志 → 选词类别（边界规则，DESIGN §4.3.2 双击选词）：
 *   - 空单元格 / 空格 / 制表符 → space；
 *   - 宽字符首格或续格 → wide（CJK/emoji 按「同一类连续宽字符」合并选区）；
 *   - ASCII 字母/数字/下划线 → word；
 *   - East Asian Wide/Hiragana/Katakana/Hangul/CJK 区即使未标 ATTR_WIDE
 *     也归 wide（网格属性缺失时的码点兜底）；
 *   - 其余（标点、控制符）→ other。
 */
export function classifyClickCodepoint(codepoint: number, wide: boolean): ClickCharClass {
  if (codepoint === CLICK_WIDE_CONTINUATION) {
    return 'wide';
  }
  if (codepoint === 0 || codepoint === 0x20 || codepoint === 0x09) {
    return 'space';
  }
  if (wide || isCjkOrEmojiCodepoint(codepoint)) {
    return 'wide';
  }
  if (codepoint >= 0x30 && codepoint <= 0x39) {
    return 'word'; // 0-9
  }
  if (codepoint >= 0x41 && codepoint <= 0x5A) {
    return 'word'; // A-Z
  }
  if (codepoint >= 0x61 && codepoint <= 0x7A) {
    return 'word'; // a-z
  }
  if (codepoint === 0x5F) {
    return 'word'; // _
  }
  return 'other';
}

/** CJK / 假名 / 谚文 / 常见 emoji 码点区间（宽字符选区兜底） */
function isCjkOrEmojiCodepoint(cp: number): boolean {
  if (cp >= 0x1100 && cp <= 0x115F) {
    return true; // Hangul Jamo
  }
  if (cp >= 0x2E80 && cp <= 0xA4CF) {
    return true; // CJK 部首/假名/汉字/彝文（含 0x3040–0x30FF）
  }
  if (cp >= 0xAC00 && cp <= 0xD7AF) {
    return true; // Hangul 音节
  }
  if (cp >= 0xF900 && cp <= 0xFAFF) {
    return true; // CJK 兼容汉字
  }
  if (cp >= 0xFE30 && cp <= 0xFE4F) {
    return true; // CJK 兼容形式
  }
  if (cp >= 0xFF00 && cp <= 0xFFEF) {
    return true; // 全角形式
  }
  if (cp >= 0x1F300 && cp <= 0x1FAFF) {
    return true; // emoji 杂项符号与象形文字
  }
  if (cp >= 0x2600 && cp <= 0x27BF) {
    return true; // 杂项符号/装饰符号（部分为 emoji）
  }
  return false;
}

/**
 * 双击选词：从落点向两侧扩展，**同一 ClickCharClass** 连续格并入；
 * 遇不同类别或网格边界停。宽字符/续格一并纳入（不切半个字）。
 *
 * 边界示例：
 *   "foo|bar baz" 落 b → 选 bar（遇空格停）
 *   "你好世界" 落中 → 选整串 CJK（连续 wide）
 *   "a中b" 落中 → 只选「中」（两侧 word 与 wide 异类）
 *   "a👍b" 落 👍 → 只选该宽字符及其续格
 *   ",,," 落中逗号 → 选连续 other 类
 */
export function wordSelectAt(grid: ClickSelectGrid, row: number, col: number): ClickSelectionRange | null {
  if (row < 0 || row >= grid.rows || col < 0 || col >= grid.cols) {
    return null;
  }
  const cell = grid.cellAt(row, col);
  if (cell === null) {
    return null;
  }
  const klass = classifyClickCodepoint(cell.codepoint, cell.wide);
  /** 相邻格是否应并入选区：同类，或（选中 wide 时）宽字符续格/首格补全 */
  const mergesWith = (other: ClickSelectCell | null): boolean => {
    if (other === null) {
      return false;
    }
    const otherClass = classifyClickCodepoint(other.codepoint, other.wide);
    if (otherClass === klass) {
      return true;
    }
    // 宽字符续格永远跟 wide 类；落点在续格时左侧 wide 首格也并入
    return klass === 'wide' && (otherClass === 'wide' || other.codepoint === CLICK_WIDE_CONTINUATION);
  };
  let start = col;
  let end = col;
  while (start > 0 && mergesWith(grid.cellAt(row, start - 1))) {
    start--;
  }
  while (end + 1 < grid.cols && mergesWith(grid.cellAt(row, end + 1))) {
    end++;
  }
  return {
    startRow: row,
    startCol: start,
    endRow: row,
    endCol: end
  };
}

/**
 * 三击选行：整行 [0, lastNonSpace]（全空白行给 [0, cols-1] 的空内容选区，
 * extract 侧仍会去行尾空格）。不含跨行——三击语义是「本逻辑行」。
 */
export function lineSelectAt(grid: ClickSelectGrid, row: number): ClickSelectionRange | null {
  if (row < 0 || row >= grid.rows || grid.cols <= 0) {
    return null;
  }
  let endCol = grid.cols - 1;
  while (endCol > 0) {
    const cell = grid.cellAt(row, endCol);
    if (cell === null || cell.codepoint === 0 || cell.codepoint === 0x20 ||
      cell.codepoint === CLICK_WIDE_CONTINUATION) {
      endCol--;
      continue;
    }
    break;
  }
  // 终点若落在宽字符首格，后延一格含整字（边界右缘除外）
  const endCell = grid.cellAt(row, endCol);
  if (endCell !== null && endCell.wide && endCol + 1 < grid.cols) {
    endCol++;
  }
  return {
    startRow: row,
    startCol: 0,
    endRow: row,
    endCol: endCol
  };
}

// ---------------------------------------------------------------- T11 SGR 鼠标上报（DECSET 1006）

/** SGR 按钮码（xterm 1006）：左/中/右；滚轮上 64 / 下 65；无键移动 3 */
export const SGR_BUTTON_LEFT = 0;
export const SGR_BUTTON_MIDDLE = 1;
export const SGR_BUTTON_RIGHT = 2;
export const SGR_BUTTON_NONE = 3;
export const SGR_BUTTON_WHEEL_UP = 64;
export const SGR_BUTTON_WHEEL_DOWN = 65;

/** SGR 事件修饰位（加在 button 码上） */
export const SGR_MOD_SHIFT = 4;
export const SGR_MOD_ALT = 8;
export const SGR_MOD_CTRL = 16;
/** SGR 移动标志（拖动/悬停时 button |= 32） */
export const SGR_MOTION_FLAG = 32;

/** 鼠标事件种类 */
export type SgrMouseKind = 'press' | 'move' | 'release';

/**
 * SGR 1006 事件编码（xterm ctlseqs「CSI < Pb ; Px ; Py M/m」）：
 *   - press/move/wheel 用终符 'M'，release 用 'm'；
 *   - move 时 button 加 SGR_MOTION_FLAG(32)；无键悬停 = 3+32=35；
 *   - 坐标 1 起；非法坐标（<1）返回 null（调用方不发送）；
 *   - mouseMode=NONE 时调用方不应调用本函数（帧元信息已在 TerminalCanvas 过滤）。
 *
 * @param buttonCode SGR_BUTTON_* 基码（wheel 传 64/65）
 * @param kind press | move | release（wheel 用 press + 64/65）
 * @param col1/row1 1 起网格坐标
 * @param mods SGR_MOD_* 按位或
 */
export function encodeSgrMouseEvent(buttonCode: number, kind: SgrMouseKind, col1: number,
  row1: number, mods: number = 0): Uint8Array | null {
  if (col1 < 1 || row1 < 1 || !isFinite(col1) || !isFinite(row1)) {
    return null;
  }
  let button = buttonCode;
  if (mods !== 0) {
    button |= (mods & (SGR_MOD_SHIFT | SGR_MOD_ALT | SGR_MOD_CTRL));
  }
  if (kind === 'move' && button < SGR_BUTTON_WHEEL_UP) {
    button |= SGR_MOTION_FLAG;
  }
  const finalChar = kind === 'release' ? 'm' : 'M';
  return asciiSeq(`\x1b[<${Math.trunc(button)};${Math.trunc(col1)};${Math.trunc(row1)}${finalChar}`);
}

/**
 * 便捷封装：滚轮 SGR 序列（mode='mouse' 的 alt-scroll 与鼠标滚轮共用语义）。
 * @param up true=滚轮上（64）false=滚轮下（65）
 */
export function encodeSgrWheel(up: boolean, col1: number, row1: number,
  mods: number = 0): Uint8Array | null {
  return encodeSgrMouseEvent(up ? SGR_BUTTON_WHEEL_UP : SGR_BUTTON_WHEEL_DOWN,
    'press', col1, row1, mods);
}

/**
 * HarmonyOS MouseEvent.button → SGR 按钮码。
 * OHOS：0=Left 1=Right 2=Middle；SGR：0=left 1=middle 2=right——**必须重映射**。
 * 未知/无键 → SGR_BUTTON_NONE(3)。
 */
export function sgrButtonFromOhosButton(ohosButton: number): number {
  if (ohosButton === 0) {
    return SGR_BUTTON_LEFT;
  }
  if (ohosButton === 2) {
    return SGR_BUTTON_MIDDLE;
  }
  if (ohosButton === 1) {
    return SGR_BUTTON_RIGHT;
  }
  return SGR_BUTTON_NONE;
}

/**
 * 当前 mouseMode 是否应向远端转发鼠标事件：
 *   mode=1 点击：press/release
 *   mode=2 拖动：press/release + 带键 move
 *   mode=3 任意移动：上述 + 悬停 move
 */
export function shouldForwardMouseEvent(mouseMode: number, kind: SgrMouseKind,
  buttonCode: number): boolean {
  if (mouseMode === MOUSE_MODE_NONE) {
    return false;
  }
  if (kind === 'move') {
    if (mouseMode >= MOUSE_MODE_ANY) {
      return true;
    }
    return mouseMode >= MOUSE_MODE_DRAG && buttonCode !== SGR_BUTTON_NONE;
  }
  return mouseMode >= MOUSE_MODE_CLICK;
}

/** ASCII 序列 → 字节（本文件序列均为纯 ASCII 控制序列） */
function asciiSeq(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0x7F;
  }
  return out;
}

// ---------------------------------------------------------------- T8 选区拖拽手柄 hit 区（纯几何）

/** 选区手柄 id：none=未命中 / start=起点 / end=终点 */
export type SelectionHandleId = 'none' | 'start' | 'end';

/** 手柄命中矩形（vp，与 TerminalCanvas 布局同口径） */
export interface HandleHitRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 选区两端手柄命中矩形集合 */
export interface SelectionHandleGeometry {
  start: HandleHitRect;
  end: HandleHitRect;
}

/** 手柄锚点（圆钮中心，vp） */
export interface HandleAnchor {
  x: number;
  y: number;
}

/** 默认几何常量（与 TerminalCanvas HANDLE_* 同值；测试独立引用，避免组件耦合） */
export const SELECTION_HANDLE_KNOB_VP = 22;
export const SELECTION_HANDLE_BAR_WIDTH_VP = 4;
export const SELECTION_HANDLE_HIT_WIDTH_VP = 36;

/**
 * 选区两端手柄的命中矩形：
 * - start：贴选区第一格**左侧**（x = startLeft − hitWidth）
 * - end：贴选区末格**右侧**（x = endRight）
 * - 高度 = max(barHeight, knob)；宽度 = hitWidth（触摸热区）
 */
export function selectionHandleHitRects(
  originX: number, originY: number,
  cellWidth: number, cellHeight: number,
  startRow: number, startCol: number,
  endRow: number, endCol: number,
  barHeight: number = -1,
  hitWidth: number = SELECTION_HANDLE_HIT_WIDTH_VP,
  knob: number = SELECTION_HANDLE_KNOB_VP): SelectionHandleGeometry {
  const bar = barHeight > 0 ? barHeight : cellHeight;
  const h = Math.max(bar, knob);
  const startLeft = originX + startCol * cellWidth;
  const startTop = originY + startRow * cellHeight;
  const endRight = originX + (endCol + 1) * cellWidth;
  const endTop = originY + endRow * cellHeight;
  return {
    start: { x: startLeft - hitWidth, y: startTop, width: hitWidth, height: h },
    end: { x: endRight, y: endTop, width: hitWidth, height: h }
  };
}

/**
 * 手柄命中半径：热区半宽（圆钮落在热区中部时等于 hitWidth/2）。
 * 点到手柄锚点距离 ≤ radius 也可视为命中（圆形热区回退路径）。
 */
export function selectionHandleHitRadius(
  hitWidth: number = SELECTION_HANDLE_HIT_WIDTH_VP,
  knob: number = SELECTION_HANDLE_KNOB_VP): number {
  return Math.max(hitWidth, knob) / 2;
}

/** 点是否落在矩形内（左闭右开，与像素网格一致） */
export function pointInHandleRect(x: number, y: number, r: HandleHitRect): boolean {
  return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
}

/**
 * 点落在哪只手柄上。
 * 重叠时 **end 优先**（终点手柄视觉在上层；纯几何不依赖 zIndex）。
 */
export function selectionHandleAtPoint(x: number, y: number,
  geo: SelectionHandleGeometry): SelectionHandleId {
  if (pointInHandleRect(x, y, geo.end)) {
    return 'end';
  }
  if (pointInHandleRect(x, y, geo.start)) {
    return 'start';
  }
  return 'none';
}

/**
 * 手柄拖动锚点：选区端点格的中心（垂直居中于所在行）。
 * TerminalCanvas.beginHandleDrag 以此为拖动 origin，手指位移叠加在端点格中心上——
 * 起手 offset=0 时换算回来恰好还是原端点格，选区不会跳。
 * （旧实现取圆钮中心，start 手柄在左缘外 hitWidth/2≈18vp，起拖瞬间端点就跳左两格。）
 * hitWidth 参数保留兼容旧调用，不再参与计算。
 */
export function selectionHandleAnchor(which: SelectionHandleId,
  originX: number, originY: number,
  cellWidth: number, cellHeight: number,
  row: number, col: number,
  hitWidth: number = SELECTION_HANDLE_HIT_WIDTH_VP): HandleAnchor {
  const cy = originY + row * cellHeight + cellHeight / 2;
  const cx = originX + col * cellWidth + cellWidth / 2;
  return { x: cx, y: cy };
}

// ---------------------------------------------------------------- 鼠标滚轮 / 触控板轴事件（2in1）

/** 鼠标滚轮一格对应的轴值（OHOS 以角度计，一格 15°） */
export const WHEEL_NOTCH_AXIS_VALUE: number = 15;
/** 系统未给 scrollStep 时，鼠标滚轮一格滚动的行数 */
export const WHEEL_DEFAULT_STEP_LINES: number = 3;
/** 单个轴事件最多换算的行数（防止高精度滚轮一次甩出几百行 / 几百个方向键） */
export const WHEEL_MAX_LINES_PER_EVENT: number = 12;

/**
 * 轴事件 → 整行换算（余量跨事件累计）。
 * 返回值符号：正 = 向下滚（看更新的内容），负 = 向上滚（看更旧的内容）。
 *   - 鼠标滚轮（scrollStep > 0 或明确是鼠标）：value / 15 × step 行；
 *   - 触控板双指（无 scrollStep）：value 视作 vp 位移，按行高换算。
 */
export class WheelLineAccumulator {
  private residual: number = 0;

  push(axisValue: number, scrollStep: number, isMouseWheel: boolean, cellHeightVp: number): number {
    if (!Number.isFinite(axisValue) || axisValue === 0) {
      return 0;
    }
    if (isMouseWheel) {
      const step: number = scrollStep > 0 ? scrollStep : WHEEL_DEFAULT_STEP_LINES;
      this.residual += axisValue / WHEEL_NOTCH_AXIS_VALUE * step;
    } else {
      this.residual += axisValue / Math.max(1, cellHeightVp);
    }
    let lines: number = Math.trunc(this.residual);
    this.residual -= lines;
    if (lines > WHEEL_MAX_LINES_PER_EVENT) {
      lines = WHEEL_MAX_LINES_PER_EVENT;
    } else if (lines < -WHEEL_MAX_LINES_PER_EVENT) {
      lines = -WHEEL_MAX_LINES_PER_EVENT;
    }
    return lines;
  }

  reset(): void {
    this.residual = 0;
  }
}

/**
 * 滚轮在 alt-screen / 鼠标上报模式下要发给远端的 SGR 滚轮序列（每行一条）。
 * @param downLines 正 = 向下，负 = 向上
 */
export function wheelSgrSequences(downLines: number, col1: number, row1: number): Uint8Array[] {
  const out: Uint8Array[] = [];
  const count: number = Math.min(Math.abs(Math.trunc(downLines)), WHEEL_MAX_LINES_PER_EVENT);
  for (let i = 0; i < count; i++) {
    const seq: Uint8Array | null = encodeSgrWheel(downLines < 0, col1, row1);
    if (seq !== null) {
      out.push(seq);
    }
  }
  return out;
}
