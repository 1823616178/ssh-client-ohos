/**
 * 终端版面几何计算（任务 T4，纯函数，hypium 覆盖）。
 *
 * 单位无关：TerminalCanvas 的 Canvas 为默认 vp 单位模式，调用方统一传 vp。
 * cols/rows 下限为 1——PTY 最小尺寸 1×1，「宽度不足一列」「padding 比画布还宽」
 * 等极端输入都钳到 1，由 resize 后的远端回显自然修正。
 */

/** 一次版面计算的结果（内容区左上角 = padding，右/下不足一格的像素留白） */
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
  const usableW = Math.max(0, width - pad * 2);
  const usableH = Math.max(0, height - pad * 2);
  const cols = cellWidth > 0 ? Math.max(1, Math.floor(usableW / cellWidth)) : 1;
  const rows = cellHeight > 0 ? Math.max(1, Math.floor(usableH / cellHeight)) : 1;
  return {
    cols: cols,
    rows: rows,
    originX: pad,
    originY: pad,
    contentWidth: cellWidth > 0 ? cols * cellWidth : 0,
    contentHeight: cellHeight > 0 ? rows * cellHeight : 0
  };
}
