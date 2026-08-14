/**
 * TerminalGestures —— 滚动与缩放手势的纯逻辑核心（任务 T9，DESIGN §4.4
 * 「滚动」「缩放」表）。ArkUI 手势事件接线在 TerminalCanvas，本文件只交付
 * 可 hypium 覆盖的判定/换算：
 *
 *  - ScrollLineAccumulator：拖动像素增量 → 整行数（不足一行的余量跨事件累计，
 *    避免慢滑不动、快滑跳变）；
 *  - clampScrollOffset：回滚视图偏移钳制 [0, 回滚行数]；
 *  - buildAltScrollSequences：alt-screen（vim/less）下单指竖滑 → 方向键或
 *    SGR 鼠标滚轮序列（每累计一行发一次；方向语义 = 内容跟手：
 *    手指下滑看旧内容 → ↑ / 滚轮上 64，手指上滑看新内容 → ↓ / 滚轮下 65）；
 *  - clampFontSize：捏合缩放字号钳制 8–32（DESIGN §4.4 字号范围）。
 *
 * 方向约定：deltaYPx > 0 = 手指向下移动。
 */

/** alt-screen 下单指竖滑行为：keys=方向键 / mouse=SGR 滚轮 / view=视图滚动 */
export type AltScrollMode = 'keys' | 'mouse' | 'view';

/** 鼠标上报模式「关」（镜像 native MouseMode::kNone，vterm_screen.h） */
export const MOUSE_MODE_NONE = 0;

/** 捏合字号范围（DESIGN §4.4：8–32） */
export const MIN_FONT_SIZE = 8;
export const MAX_FONT_SIZE = 32;

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
 * alt-screen 竖滑 → 发送序列集合（每累计一行一条）：
 *   - mode='mouse' 且终端已开鼠标上报（mouseMode ≠ None）→ SGR 滚轮
 *     \e[<64;x;yM（上滚）/ \e[<65;x;yM（下滚），x/y 为 1 起网格坐标；
 *   - mode='mouse' 但 mouseMode = None → 回退方向键（应用未开鼠标上报时
 *     发鼠标序列无意义）；
 *   - mode='keys' → 方向键 \e[A / \e[B；
 *   - mode='view' → 空数组（视图滚动由组件本地处理，不向终端发字节）。
 *
 * @param lines 带符号行数（正 = 手指下移 = 看旧内容 = 上滚）
 * @param col1/row1 手指所在网格坐标（1 起，SGR 鼠标序列用；keys 模式忽略）
 */
export function buildAltScrollSequences(mode: AltScrollMode, mouseMode: number, lines: number,
  col1: number, row1: number): Uint8Array[] {
  const result: Uint8Array[] = [];
  if (lines === 0 || mode === 'view') {
    return result;
  }
  const up = lines > 0;
  const count = up ? lines : -lines;
  const useMouse = mode === 'mouse' && mouseMode !== MOUSE_MODE_NONE;
  for (let i = 0; i < count; i++) {
    result.push(useMouse ? sgrMouseWheel(up, col1, row1) : arrowKey(up));
  }
  return result;
}

/** 方向键序列（alt-screen 滚轮回退：↑/↓，普通模式 CSI 形式） */
function arrowKey(up: boolean): Uint8Array {
  return asciiSeq(up ? '\x1b[A' : '\x1b[B');
}

/** SGR 鼠标滚轮序列：64=上滚 65=下滚，坐标 1 起（xterm DECSET 1006 惯例） */
function sgrMouseWheel(up: boolean, col1: number, row1: number): Uint8Array {
  const button = up ? 64 : 65;
  return asciiSeq(`\x1b[<${button};${col1};${row1}M`);
}

/** ASCII 序列 → 字节（本文件序列均为纯 ASCII 控制序列） */
function asciiSeq(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0x7F;
  }
  return out;
}
