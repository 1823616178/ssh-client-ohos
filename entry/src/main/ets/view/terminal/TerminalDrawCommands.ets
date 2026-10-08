/**
 * 终端行 → 绘制指令 纯函数生成器（任务 T4，hypium 覆盖）。
 *
 * TerminalCanvas 组件只负责把这里产出的指令逐条打到 CanvasRenderingContext2D，
 * 全部绘制决策都在本文件：
 *  - 属性解析管线：reverse（前后景互换）→ bold-as-bright → dim；
 *  - 背景：相邻同背景色合并为一次 fillRect；与默认背景相同的段不产出指令
 *    （组件在画指令前已用默认背景整行清底，重复填充是纯浪费）；
 *  - 文本：相邻同样式合并为一次 fillText（宽字符依赖 T5 等宽字体 1:2 严格对齐；
 *    letterSpacing ≠ 0 时合并会丢字间距，用 perGlyphText 退化为逐格一条）；
 *  - 宽字符：ATTR_WIDE 首格出字形且 cellSpan 计 2，WIDE_CONTINUATION 续格
 *    不出字形（背景照常参与合并）；
 *  - ATTR_BLINK 首版按静止绘制（闪烁定时器见 TerminalCanvas 头注）。
 *
 * 坐标约定：x/y 为像素（vp 单位模式），文本 y 为行垂直中心；组件执行时
 * 使用 alphabetic baseline，并叠加 FontMetrics 实测的视觉居中偏移。
 */
import {
  ATTR_BOLD,
  ATTR_DIM,
  ATTR_ITALIC,
  ATTR_REVERSE,
  ATTR_STRIKE,
  ATTR_UNDERLINE,
  ATTR_WIDE,
  DecodedCell,
  WIDE_CONTINUATION,
  decodeCellAt
} from '../../napi/SshTerminal';
import { CursorStyle } from '../../common/model/models';
import { applyBoldAsBright, applyDim } from './TerminalPalette';

/**
 * native VtermBridge 未注入外观时的默认色（vterm_screen.h kDefault*）。
 * 真实 SSH 网格里「默认底/字」就是这两个值；绘制时替换成外观前后景，
 * 否则改 appearance.background 只动页面外框，字符格仍是纯黑。
 */
export const NATIVE_DEFAULT_FG_ARGB: number = 0xFFE5E5E5;
export const NATIVE_DEFAULT_BG_ARGB: number = 0xFF000000;

/** 一段背景填充（对应一次 fillRect） */
export interface BgRun {
  x: number;
  y: number;
  width: number;
  height: number;
  /** 最终背景色 ARGB（已经过 reverse 等管线） */
  argb: number;
}

/** 一段文本（对应一次 fillText；underline/strike 由组件按 cellSpan 画线） */
export interface TextRun {
  text: string;
  /** 起始格像素 x */
  x: number;
  /** 行垂直中心 y（组件执行时换算为 alphabetic baseline） */
  y: number;
  /** 覆盖格数（宽字符计 2）：underline/strike 的线长 = cellSpan × cellWidth */
  cellSpan: number;
  /** 最终前景色 ARGB */
  fgArgb: number;
  /** 最终背景色 ARGB（文本段合并判定用；绘制仍以 backgrounds 为准） */
  bgArgb: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
}

/** 一行（或一个行区间）的完整绘制指令：先 backgrounds 后 texts */
export interface RowDrawCommands {
  backgrounds: BgRun[];
  texts: TextRun[];
}

/** 行渲染环境（组件每帧重建的纯数据快照，生成器不感知组件/Canvas） */
export interface RowRenderEnv {
  /** 内容区左上角 x（= padding） */
  originX: number;
  /** 内容区左上角 y（= padding） */
  originY: number;
  cellWidth: number;
  cellHeight: number;
  defaultFgArgb: number;
  defaultBgArgb: number;
  /** 16 色调色板 ARGB（bold-as-bright 反查用） */
  paletteArgb: number[];
  boldAsBright: boolean;
  /** true = 逐格出 TextRun（letterSpacing ≠ 0 时组件置位，保字间距对齐） */
  perGlyphText: boolean;
  /**
   * 设备像素比（px/vp）。> 0 时所有矩形边与文本起点吸附到物理像素网格：
   * 分数 vp 行高下相邻行背景不再出现 1px 缝/叠色，光标与选区边缘清晰。
   * 缺省/≤0 = 不吸附（单测旧口径）。
   */
  pixelRatio?: number;
}

/** 吸附到物理像素网格（ratio ≤ 0 时原样返回） */
export function snapToPixel(v: number, ratio: number): number {
  if (!(ratio > 0)) {
    return v;
  }
  return Math.round(v * ratio) / ratio;
}

function envRatio(env: RowRenderEnv): number {
  return env.pixelRatio !== undefined && env.pixelRatio > 0 ? env.pixelRatio : 0;
}

/** 第 col 列左边界（已吸附） */
export function cellLeftX(env: RowRenderEnv, col: number): number {
  return snapToPixel(env.originX + col * env.cellWidth, envRatio(env));
}

/** 第 row 行上边界（已吸附） */
export function cellTopY(env: RowRenderEnv, row: number): number {
  return snapToPixel(env.originY + row * env.cellHeight, envRatio(env));
}

/** 单元格属性管线的最终样式（fg/bg 已按 reverse/bold-as-bright/dim 结算） */
interface ResolvedStyle {
  fg: number;
  bg: number;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
}

/** 属性管线：reverse 互换 → bold-as-bright → dim（blink 首版忽略，见文件头注） */
function resolveStyle(cell: DecodedCell, env: RowRenderEnv): ResolvedStyle {
  let fg = cell.fgArgb === NATIVE_DEFAULT_FG_ARGB ? env.defaultFgArgb : cell.fgArgb;
  let bg = cell.bgArgb === NATIVE_DEFAULT_BG_ARGB ? env.defaultBgArgb : cell.bgArgb;
  const bold = (cell.attrs & ATTR_BOLD) !== 0;
  if ((cell.attrs & ATTR_REVERSE) !== 0) {
    const swap = fg;
    fg = bg;
    bg = swap;
  }
  fg = applyBoldAsBright(fg, bold, env.paletteArgb, env.boldAsBright);
  if ((cell.attrs & ATTR_DIM) !== 0) {
    fg = applyDim(fg, bg);
  }
  return {
    fg: fg,
    bg: bg,
    bold: bold,
    italic: (cell.attrs & ATTR_ITALIC) !== 0,
    underline: (cell.attrs & ATTR_UNDERLINE) !== 0,
    strike: (cell.attrs & ATTR_STRIKE) !== 0
  };
}

/**
 * 为一个行区间生成绘制指令。
 * @param view     readRows 切片：第 0 格 = (startRow, 0) 列
 * @param startRow 区间首行号（网格坐标，用于算 y）
 * @param rowCount 区间行数
 * @param cols     网格列数（以帧快照为准）
 */
export function generateRowsCommands(view: DataView, startRow: number, rowCount: number,
  cols: number, env: RowRenderEnv): RowDrawCommands {
  const result: RowDrawCommands = { backgrounds: [], texts: [] };
  if (cols <= 0 || rowCount <= 0 || env.cellWidth <= 0 || env.cellHeight <= 0) {
    return result;
  }
  for (let r = 0; r < rowCount; r++) {
    const rowY = cellTopY(env, startRow + r);
    const rowBottom = cellTopY(env, startRow + r + 1);
    let bgStart = -1;
    let bgArgb = 0;
    let run: TextRun | null = null;
    for (let c = 0; c < cols; c++) {
      const cell = decodeCellAt(view, r * cols + c);
      const style = resolveStyle(cell, env);
      // ---- 背景合并：默认背景段不出指令（整行已由组件清底）----
      if (style.bg === env.defaultBgArgb) {
        if (bgStart >= 0) {
          result.backgrounds.push(makeBgRun(bgStart, c, rowY, rowBottom, bgArgb, env));
          bgStart = -1;
        }
      } else if (bgStart < 0) {
        bgStart = c;
        bgArgb = style.bg;
      } else if (style.bg !== bgArgb) {
        result.backgrounds.push(makeBgRun(bgStart, c, rowY, rowBottom, bgArgb, env));
        bgStart = c;
        bgArgb = style.bg;
      }
      // ---- 文本合并：空格与宽字符续格不出字形，且打断当前文本段 ----
      if (cell.codepoint === 0 || cell.codepoint === WIDE_CONTINUATION) {
        run = null;
        continue;
      }
      // 宽字符占 2 格：字形画在首格，续格只有背景（上面的背景循环已覆盖）
      const wide: boolean = (cell.attrs & ATTR_WIDE) !== 0;
      const span = wide && c + 1 < cols ? 2 : 1;
      // 宽字符（CJK/emoji）的实际字形宽度不一定恰好 = 2×ASCII 格宽（回退字体度量不同），
      // 与相邻字符合并成一条 fillText 会让后续字形累计漂移出格子；宽字符一律独占一条，
      // 并且打断前后段，每个宽字形都从自己的格子左缘起笔。
      if (!env.perGlyphText && !wide && run !== null && sameTextStyle(run, style)) {
        run.text += String.fromCodePoint(cell.codepoint);
        run.cellSpan += span;
      } else {
        run = {
          text: String.fromCodePoint(cell.codepoint),
          x: cellLeftX(env, c),
          y: rowY + (rowBottom - rowY) / 2,
          cellSpan: span,
          fgArgb: style.fg,
          bgArgb: style.bg,
          bold: style.bold,
          italic: style.italic,
          underline: style.underline,
          strike: style.strike
        };
        result.texts.push(run);
        if (wide) {
          run = null;
        }
      }
    }
    if (bgStart >= 0) {
      result.backgrounds.push(makeBgRun(bgStart, cols, rowY, rowBottom, bgArgb, env));
    }
  }
  return result;
}

function makeBgRun(startCol: number, endCol: number, rowY: number, rowBottom: number, argb: number,
  env: RowRenderEnv): BgRun {
  const x0: number = cellLeftX(env, startCol);
  const x1: number = cellLeftX(env, endCol);
  return {
    x: x0,
    y: rowY,
    width: x1 - x0,
    height: rowBottom - rowY,
    argb: argb
  };
}

function sameTextStyle(run: TextRun, style: ResolvedStyle): boolean {
  // 背景也参与合并判定：默认底↔自定义底、reverse 互换等场景下同 fg 不可跨段合并
  return run.fgArgb === style.fg && run.bgArgb === style.bg &&
    run.bold === style.bold && run.italic === style.italic &&
    run.underline === style.underline && run.strike === style.strike;
}

// 光标条/下划线的几何比例：终端内部几何常量（非 Design Token 范畴）
const CURSOR_BAR_MIN_WIDTH_VP = 1.5;
const CURSOR_BAR_WIDTH_FRACTION = 0.15;
const CURSOR_UNDERLINE_MIN_HEIGHT_VP = 1.5;
const CURSOR_UNDERLINE_HEIGHT_FRACTION = 0.12;

/**
 * 光标闪烁整周期（ms）。常见终端 half≈530ms；这里整周期 1060ms，
 * `cursorVisibleAt` 前半可见、后半不可见。
 */
export const CURSOR_BLINK_PERIOD_MS: number = 1060;

/**
 * 光标可见性纯函数（A3 residual）。
 * blinkEnabled=false 或 periodMs 非法 → 恒可见（静止语义）；
 * true 时按 now 相对周期的半段奇偶判定（floor 稳定，避免浮点边界抖动）。
 */
export function cursorVisibleAt(now: number, blinkEnabled: boolean, periodMs: number): boolean {
  if (!blinkEnabled) {
    return true;
  }
  if (!(periodMs > 0) || !Number.isFinite(now)) {
    return true;
  }
  const half: number = Math.floor(periodMs / 2);
  if (half <= 0) {
    return true;
  }
  return (Math.floor(now / half) % 2) === 0;
}

/**
 * 生成光标绘制指令。
 *  - block：反色语义——光标格最终前景/背景互换后重画（含原字符）；
 *    view 必须是光标行的单行视图（readRows(frame, cursorRow, 1)），
 *    null 时按默认前后景画纯色块（防御路径）；
 *  - bar / underline：cursorArgb 纯色竖条 / 下划线（不反色）。
 * 越界（col/尺寸非法）返回空指令。
 */
export function generateCursorCommands(style: CursorStyle, view: DataView | null, col: number,
  row: number, cols: number, env: RowRenderEnv, cursorArgb: number): RowDrawCommands {
  const result: RowDrawCommands = { backgrounds: [], texts: [] };
  if (col < 0 || col >= cols || row < 0 || env.cellWidth <= 0 || env.cellHeight <= 0) {
    return result;
  }
  const ratio: number = envRatio(env);
  const x = cellLeftX(env, col);
  const rowY = cellTopY(env, row);
  const rowH = cellTopY(env, row + 1) - rowY;
  if (style === 'bar') {
    const w = Math.max(CURSOR_BAR_MIN_WIDTH_VP, snapToPixel(env.cellWidth * CURSOR_BAR_WIDTH_FRACTION, ratio));
    result.backgrounds.push({ x: x, y: rowY, width: w, height: rowH, argb: cursorArgb });
    return result;
  }
  if (style === 'underline') {
    const h = Math.max(CURSOR_UNDERLINE_MIN_HEIGHT_VP,
      snapToPixel(env.cellHeight * CURSOR_UNDERLINE_HEIGHT_FRACTION, ratio));
    result.backgrounds.push({
      x: x,
      y: rowY + rowH - h,
      width: cellLeftX(env, col + 1) - x,
      height: h,
      argb: cursorArgb
    });
    return result;
  }
  // block：反色。宽字符下光标块覆盖 2 格。
  let fg = env.defaultFgArgb;
  let bg = env.defaultBgArgb;
  let glyph = '';
  let bold = false;
  let italic = false;
  let cellSpan = 1;
  if (view !== null) {
    const cell = decodeCellAt(view, col);
    const resolved = resolveStyle(cell, env);
    fg = resolved.fg;
    bg = resolved.bg;
    bold = resolved.bold;
    italic = resolved.italic;
    if (cell.codepoint !== 0 && cell.codepoint !== WIDE_CONTINUATION) {
      glyph = String.fromCodePoint(cell.codepoint);
      if ((cell.attrs & ATTR_WIDE) !== 0 && col + 1 < cols) {
        cellSpan = 2;
      }
    }
  }
  result.backgrounds.push({
    x: x,
    y: rowY,
    width: cellLeftX(env, col + cellSpan) - x,
    height: rowH,
    argb: fg // 反色：原前景当块色
  });
  if (glyph.length > 0) {
    result.texts.push({
      text: glyph,
      x: x,
      y: rowY + rowH / 2,
      cellSpan: cellSpan,
      fgArgb: bg, // 反色：原背景当字形色
      bgArgb: fg,
      bold: bold,
      italic: italic,
      underline: false,
      strike: false
    });
  }
  return result;
}

/**
 * Canvas font 字符串（CSS font shorthand；字号带 vp 单位，与 Canvas 默认单位模式一致）。
 * fontFamily 支持逗号分隔的字族栈（T5：'JetBrains Mono, Sarasa Term SC'）——逐项加
 * 双引号：含空格字族不加引号不是合法 shorthand，而整串加一个引号会被当成单个
 * 含逗号的字族名（匹配不到任何字体）。
 * ⚠️ 字族列表的逐字回退（ASCII 用前者、CJK 落后者）是否生效需真机验证（TASKS T5）。
 */
/** 通用等宽族名：Canvas 唯一可靠解析到真等宽字体的写法（不加引号，CSS 通用族） */
const GENERIC_MONOSPACE: string = 'monospace';

export function buildFontString(italic: boolean, bold: boolean, fontWeight: number,
  fontSizeVp: number, fontFamily: string): string {
  const styleToken = italic ? 'italic' : 'normal';
  const weightToken = bold ? 'bold' : (fontWeight === 400 ? 'normal' : `${fontWeight}`);
  const quoted: string[] = fontFamily.split(',')
    .map((name: string) => name.trim())
    .filter((name: string) => name.length > 0)
    .map((name: string) => name.startsWith('"') ? name : `"${name}"`);
  // 末尾恒兜通用 monospace：真机实测 Canvas 解析不了 registerFont 注册的自定义
  // 字族（"JetBrains Mono" 的度量与一个不存在的字体名完全一致：W=13.52/i=3.37，
  // 即回落到了默认比例字体，终端列宽全错），而字族列表回退是生效的，
  // 且 monospace 是真等宽（W=i=8.40）。保留自定义名在前，便于日后设备支持时自动启用。
  // 去重按去引号后的名字比较：字族栈里已显式写了 monospace 时不再重复追加
  const alreadyMono: boolean = quoted.some((name: string) =>
    name.replace(/"/g, '') === GENERIC_MONOSPACE);
  if (!alreadyMono) {
    quoted.push(GENERIC_MONOSPACE);
  }
  return `${styleToken} ${weightToken} ${fontSizeVp}vp ${quoted.join(', ')}`;
}
