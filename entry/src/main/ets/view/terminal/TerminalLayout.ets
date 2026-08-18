/**
 * 终端版面几何计算（任务 T4，纯函数，hypium 覆盖）。
 *
 * 单位无关：TerminalCanvas 的 Canvas 为默认 vp 单位模式，调用方统一传 vp。
 * cols/rows 下限为 1——PTY 最小尺寸 1×1，「宽度不足一列」「padding 比画布还宽」
 * 等极端输入都钳到 1，由 resize 后的远端回显自然修正。
 */

/** 一次版面计算的结果（内容区左上角 = 左/上内边距，右/下不足一格的像素留白） */
export interface TerminalLayoutMetrics {
  /** 网格列数（≥1） */
  cols: number;
  /** 网格行数（≥1） */
  rows: number;
  /** 内容区左上角 x（= padding） */
  originX: number;
  /** 内容区左上角 y（= padding） */
  originY: number;
  /** 内容区宽 = cols × cellWidth */
  contentWidth: number;
  /** 内容区高 = rows × cellHeight */
  contentHeight: number;
}

/**
 * 由画布尺寸与格宽/格高算 cols/rows。
 * 防御：padding 负值按 0 处理；cellWidth/cellHeight ≤ 0（含字号尚未度量的启动瞬间）
 * 时按 1×1 网格返回，避免除零；cols/rows 恒 ≥ 1。
 */
export function computeTerminalLayout(width: number, height: number, padding: number,
  cellWidth: number, cellHeight: number): TerminalLayoutMetrics {
  const pad = padding > 0 ? padding : 0;
  return computeTerminalLayoutInsets(width, height, pad, pad, pad, pad, cellWidth, cellHeight);
}

/**
 * 分别指定四边内边距。终端页用它只缩进字符网格的左/右/上边，底边仍贴满屏幕；
 * Canvas 本身尺寸不变，因此这些留白始终属于 PTY 背景，而不是页面外层色带。
 */
export function computeTerminalLayoutInsets(width: number, height: number,
  left: number, right: number, top: number, bottom: number,
  cellWidth: number, cellHeight: number): TerminalLayoutMetrics {
  const insetLeft = left > 0 ? left : 0;
  const insetRight = right > 0 ? right : 0;
  const insetTop = top > 0 ? top : 0;
  const insetBottom = bottom > 0 ? bottom : 0;
  const usableW = Math.max(0, width - insetLeft - insetRight);
  const usableH = Math.max(0, height - insetTop - insetBottom);
  const cols = cellWidth > 0 ? Math.max(1, Math.floor(usableW / cellWidth)) : 1;
  const rows = cellHeight > 0 ? Math.max(1, Math.floor(usableH / cellHeight)) : 1;
  return {
    cols: cols,
    rows: rows,
    originX: insetLeft,
    originY: insetTop,
    contentWidth: cellWidth > 0 ? cols * cellWidth : 0,
    contentHeight: cellHeight > 0 ? rows * cellHeight : 0
  };
}

/**
 * onAreaChange 的 Area.width/height 是 Length（number | string | Resource），
 * 真机上取到的是带单位的字符串。直接 `as number` 强转得 NaN，会一路污染到
 * 版面计算：格数算不出来就落到兜底值（表现为终端只占版面一角、PTY 尺寸与
 * 实际画布不符），断点判定也会因 NaN 比较恒 false 而误判成大屏。
 * 故所有 Area 尺寸读取统一经本函数收口；非有限值一律归 0，由后续 onAreaChange 校正。
 */
export function areaLengthToVp(value: Length): number {
  if (typeof value === 'number') {
    return Number.isFinite(value) ? value : 0;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseFloat(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}
