/**
 * SelectionModel —— 终端文本选择纯逻辑（任务 T8，DESIGN §4.4「选择复制」：
 * 长按进入选择模式、拖拽调整范围、气泡菜单「复制/全选」）。
 *
 * 职责：
 *  - CellPos/SelectionRange 坐标模型与 SelectionModel 状态机
 *    （begin 长按进入 → extend 拖动活动端 → cancel；selectAll 全选）；
 *  - normalizeSelection：锚点/活动端任意方向 → 规范化 [start, end]（两端含）；
 *  - extractSelectionText：跨行拼接（行间补 '\n'、行尾去空格——终端惯例），
 *    宽字符边界不切半个字（起点落续格前移一格含整字；终点落首格后延一格含整字）；
 *  - SelectionGridReader 行读取抽象：主屏由 TerminalCanvas 用帧 DataView 构造
 *    （dataViewGridReader），回滚区理论上可由 copyScrollbackWindow 构造——
 *    首版只支持主屏选择（回滚区选择登记后续，TerminalCanvas 在
 *    scrollOffset>0 时不进入选择模式），放大镜省略（T8 任务书允许）。
 *
 * 坐标语义：row/col 为网格行列（0 起）；选区两端均含（end 是最后一个被选格）。
 * 纯逻辑不碰 ArkUI/native，全部可 hypium 覆盖。
 */

import {
  ATTR_WIDE,
  DecodedCell,
  WIDE_CONTINUATION,
  decodeCellAt
} from '../../napi/SshTerminal';

/** 网格坐标（0 起） */
export interface CellPos {
  row: number;
  col: number;
}

/** 规范化选区 [start, end]（两端均含；start ≤ end 按行优先字典序） */
export interface SelectionRange {
  startRow: number;
  startCol: number;
  endRow: number;
  endCol: number;
}

/**
 * 行读取抽象：「(row) => 该行的单元格解码结果」。
 * 主屏实现见 dataViewGridReader；行不可得（越界/帧失效）返回 null，按空行处理。
 */
export interface SelectionGridReader {
  readonly rows: number;
  readonly cols: number;
  rowCells(row: number): DecodedCell[] | null;
}

/**
 * 主屏网格 → SelectionGridReader（view 为 readRows(frame, 0, rows) 的切片，
 * 第 0 格 = (0,0)；帧生命周期保护语义同 SshTerminal 头注）。
 * 只解码取文本所需的码点与宽字符属性，颜色属性原样透传不解释。
 */
export function dataViewGridReader(view: DataView, rows: number, cols: number): SelectionGridReader {
  return new DataViewGridReader(view, rows, cols);
}

/** DataView 网格行读取实现（arkts 对象字面量不承载方法，用显式类） */
class DataViewGridReader implements SelectionGridReader {
  readonly rows: number;
  readonly cols: number;
  private readonly view: DataView;

  constructor(view: DataView, rows: number, cols: number) {
    this.view = view;
    this.rows = rows;
    this.cols = cols;
  }

  rowCells(row: number): DecodedCell[] | null {
    if (row < 0 || row >= this.rows) {
      return null;
    }
    const cells: DecodedCell[] = [];
    for (let c = 0; c < this.cols; c++) {
      cells.push(decodeCellAt(this.view, row * this.cols + c));
    }
    return cells;
  }
}

/** 坐标先后比较（行优先字典序）：a ≤ b 返回 true */
function posLessOrEqual(a: CellPos, b: CellPos): boolean {
  return a.row < b.row || (a.row === b.row && a.col <= b.col);
}

/** 锚点/活动端 → 规范化选区（任意拖动方向都收敛为 start ≤ end，两端含） */
export function normalizeSelection(anchor: CellPos, active: CellPos): SelectionRange {
  const start = posLessOrEqual(anchor, active) ? anchor : active;
  const end = posLessOrEqual(anchor, active) ? active : anchor;
  return { startRow: start.row, startCol: start.col, endRow: end.row, endCol: end.col };
}

/**
 * 宽字符边界修正（验收标准「宽字符边界不切半个字」）：
 *   - 起点落在宽字符续格（WIDE_CONTINUATION）→ 前移一格，含整字；
 *   - 终点落在宽字符首格（ATTR_WIDE）→ 后延一格，含整字（网格右边缘无法后延则保持）。
 * 修正保持 start ≤ end（起点只左移、终点只右移）。
 */
export function adjustWideCharBoundary(reader: SelectionGridReader,
  range: SelectionRange): SelectionRange {
  let startCol = range.startCol;
  let endCol = range.endCol;
  const startCells = reader.rowCells(range.startRow);
  if (startCells !== null && startCol > 0 && startCol < startCells.length &&
    startCells[startCol].codepoint === WIDE_CONTINUATION) {
    startCol--;
  }
  const endCells = reader.rowCells(range.endRow);
  if (endCells !== null && endCol >= 0 && endCol < endCells.length &&
    (endCells[endCol].attrs & ATTR_WIDE) !== 0 && endCol + 1 < reader.cols) {
    endCol++;
  }
  return {
    startRow: range.startRow,
    startCol: startCol,
    endRow: range.endRow,
    endCol: endCol
  };
}

/**
 * 提取选区文本：跨行拼接，行间补 '\n'；每行行尾空格去掉（终端惯例——
 * 网格右侧填充的空格不属于内容）；行内空格（含空单元格）原样保留；
 * 宽字符续格不出字符（字形由首格产出），宽字符边界先经 adjustWideCharBoundary 修正。
 *
 * @param reader 行读取抽象（首版：主屏网格）
 * @param anchor 锚点（长按落点）
 * @param active 活动端（拖拽终点；可与锚点同格 = 选一格）
 */
export function extractSelectionText(reader: SelectionGridReader, anchor: CellPos,
  active: CellPos): string {
  const range = adjustWideCharBoundary(reader, normalizeSelection(anchor, active));
  const lines: string[] = [];
  for (let r = range.startRow; r <= range.endRow; r++) {
    const lo = r === range.startRow ? range.startCol : 0;
    const hi = r === range.endRow ? range.endCol : reader.cols - 1;
    lines.push(extractLineText(reader.rowCells(r), lo, hi));
  }
  return lines.join('\n');
}

/** 单行 [lo, hi]（含）区间 → 文本：空单元格当空格、续格跳过、行尾去空格 */
function extractLineText(cells: DecodedCell[] | null, lo: number, hi: number): string {
  if (cells === null || hi < lo || hi < 0) {
    return '';
  }
  const end = Math.min(hi, cells.length - 1);
  let line = '';
  for (let c = Math.max(lo, 0); c <= end; c++) {
    const cp = cells[c].codepoint;
    if (cp === WIDE_CONTINUATION) {
      continue; // 宽字符续格：字形已由首格产出
    }
    line += cp === 0 ? ' ' : String.fromCodePoint(cp);
  }
  return trimTrailingSpaces(line);
}

/** 行尾空格去除（只去 ASCII 空格——网格填充物；行内空格不受影响） */
function trimTrailingSpaces(s: string): string {
  let end = s.length;
  while (end > 0 && s.charAt(end - 1) === ' ') {
    end--;
  }
  return s.substring(0, end);
}

// ---------------------------------------------------------------- 选择状态机

/**
 * 选择会话状态机（TerminalCanvas 持有一个实例）：
 *   idle ──begin(长按)──▶ selecting ──extend(拖动)──▶ selecting（活动端跟进）
 *   selecting ──cancel(点击他处/复制完成)──▶ idle
 * 坐标的网格边界钳制由组件侧（像素→网格换算处）完成，本类只管端点与规范化。
 */
export class SelectionModel {
  private anchorPos: CellPos | null = null;
  private activePos: CellPos | null = null;

  /** 是否处于选择模式 */
  get selecting(): boolean {
    return this.anchorPos !== null && this.activePos !== null;
  }

  /** 长按进入选择模式：锚点与活动端同置落点 */
  begin(pos: CellPos): void {
    this.anchorPos = { row: pos.row, col: pos.col };
    this.activePos = { row: pos.row, col: pos.col };
  }

  /** 拖动更新活动端（未在选择模式时静默忽略） */
  extend(pos: CellPos): void {
    if (!this.selecting) {
      return;
    }
    this.activePos = { row: pos.row, col: pos.col };
  }

  /** 全选（气泡菜单「全选」）：锚点 (0,0)，活动端最后一格 */
  selectAll(rows: number, cols: number): void {
    if (rows <= 0 || cols <= 0) {
      return;
    }
    this.anchorPos = { row: 0, col: 0 };
    this.activePos = { row: rows - 1, col: cols - 1 };
  }

  /** 退出选择模式（复制完成/点击他处/终端换绑） */
  cancel(): void {
    this.anchorPos = null;
    this.activePos = null;
  }

  /** 规范化选区；非选择模式返回 null */
  range(): SelectionRange | null {
    if (!this.selecting) {
      return null;
    }
    const anchor = this.anchorPos as CellPos;
    const active = this.activePos as CellPos;
    return normalizeSelection(anchor, active);
  }

  /** 提取当前选区文本（含宽字符边界修正）；非选择模式返回空串 */
  extractText(reader: SelectionGridReader): string {
    if (!this.selecting) {
      return '';
    }
    const anchor = this.anchorPos as CellPos;
    const active = this.activePos as CellPos;
    return extractSelectionText(reader, anchor, active);
  }
}
