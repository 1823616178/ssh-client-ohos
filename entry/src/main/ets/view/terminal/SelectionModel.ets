/**
 * SelectionModel —— 终端文本选择纯逻辑（任务 T8，DESIGN §4.4「选择复制」：
 * 长按进入选择模式、拖拽调整范围、气泡菜单「复制/全选」）。
 *
 * 职责：
 *  - CellPos/SelectionRange 坐标模型与 SelectionModel 状态机
 *    （begin 长按进入 → extend 拖动活动端 / moveStart·moveEnd 拖两端手柄
 *    → cancel；selectAll 全选）；
 *  - normalizeSelection：锚点/活动端任意方向 → 规范化 [start, end]（两端含）；
 *  - extractSelectionText：跨行拼接，软换行感知——native 在行尾格 reserved bit0
 *    标记「本行自动折行到下一行」（kReservedWrapsNext），这样的行之间不补 '\n'、
 *    行尾空格保留（是内容的一部分）；硬换行之间补 '\n' 并去掉行尾填充空格；
 *    宽字符边界不切半个字（起点落续格前移一格含整字；终点落首格后延一格含整字）；
 *  - SelectionGridReader 行读取抽象：TerminalCanvas 用「绝对行」实现——
 *    abs < scrollbackTotal 读回滚区，否则读主屏第 abs−total 行，选区因此可以
 *    跨越回滚区与主屏，远端继续输出时选区内容也不漂移；
 *  - logicalLineAt：把软换行连起来的逻辑行展开成文本 + 逐字符格坐标（链接识别用）。
 *
 * 坐标语义：row/col 为网格行列（0 起；画布传绝对行）；选区两端均含。
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
  /** 该行是否软换行到下一行（行尾格 reserved bit0）；不可得按 false */
  rowWrapsNext(row: number): boolean;
}

/** 行尾格 reserved 字段 bit0：本行软换行到下一行（与 native grid.h kReservedWrapsNext 一致） */
export const RESERVED_WRAPS_NEXT: number = 1;
const CELL_BYTES_SEL: number = 16;
const RESERVED_OFFSET: number = 14;

/** DataView 中第 row 行（行宽 cols）是否软换行 */
export function dataViewRowWrapsNext(view: DataView, row: number, cols: number): boolean {
  if (cols <= 0) {
    return false;
  }
  const off: number = (row * cols + cols - 1) * CELL_BYTES_SEL + RESERVED_OFFSET;
  if (off < 0 || off + 2 > view.byteLength) {
    return false;
  }
  return (view.getUint16(off, true) & RESERVED_WRAPS_NEXT) !== 0;
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

  rowWrapsNext(row: number): boolean {
    if (row < 0 || row >= this.rows) {
      return false;
    }
    return dataViewRowWrapsNext(this.view, row, this.cols);
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
  return extractRangeText(reader, range);
}

/** 已规范化（且已做宽字符修正）的选区 → 文本（软换行感知，规则见 extractSelectionText） */
export function extractRangeText(reader: SelectionGridReader, range: SelectionRange): string {
  let out = '';
  let nextCells: DecodedCell[] | null = reader.rowCells(range.startRow);
  for (let r = range.startRow; r <= range.endRow; r++) {
    const cells: DecodedCell[] | null = nextCells;
    nextCells = r < range.endRow ? reader.rowCells(r + 1) : null;
    const lo = r === range.startRow ? range.startCol : 0;
    const hi = r === range.endRow ? range.endCol : reader.cols - 1;
    const wraps: boolean = r < range.endRow && reader.rowWrapsNext(r);
    if (wraps) {
      // 软换行：行尾是内容的一部分，不补换行、不去空格；唯一例外是宽字符放不下
      // 行尾最后一格时 libvterm 留下的那格空白（下一行以宽字符开头）
      let end = hi;
      if (cells !== null && end === reader.cols - 1 && end >= lo && end < cells.length &&
        cells[end].codepoint === 0 && nextCells !== null && nextCells.length > 0 &&
        (nextCells[0].attrs & ATTR_WIDE) !== 0) {
        end--;
      }
      out += extractLineText(cells, lo, end, false);
    } else {
      out += extractLineText(cells, lo, hi, true);
      if (r < range.endRow) {
        out += '\n';
      }
    }
  }
  return out;
}

/** 单行 [lo, hi]（含）区间 → 文本：空单元格当空格、续格跳过；trim=true 时去行尾空格 */
function extractLineText(cells: DecodedCell[] | null, lo: number, hi: number, trim: boolean): string {
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
  return trim ? trimTrailingSpaces(line) : line;
}

/** 软换行拼接后的逻辑行：文本 + 每个 UTF-16 单元对应的格坐标 */
export interface LogicalLine {
  text: string;
  positions: CellPos[];
  startRow: number;
  endRow: number;
}

/** 逻辑行最多向上/向下追溯的物理行数（防御超长折行） */
const LOGICAL_LINE_MAX_ROWS: number = 64;

/**
 * 包含 row 的逻辑行（向上追到「上一行不折行」，向下追到「本行不折行」）。
 * minRow 为可读的最小行号（回滚最旧行）。
 */
export function logicalLineAt(reader: SelectionGridReader, row: number, minRow: number = 0): LogicalLine {
  let start: number = row;
  while (start > minRow && row - start < LOGICAL_LINE_MAX_ROWS && reader.rowWrapsNext(start - 1)) {
    start--;
  }
  let end: number = row;
  while (end < reader.rows - 1 && end - row < LOGICAL_LINE_MAX_ROWS && reader.rowWrapsNext(end)) {
    end++;
  }
  let text = '';
  const positions: CellPos[] = [];
  for (let r = start; r <= end; r++) {
    const cells: DecodedCell[] | null = reader.rowCells(r);
    if (cells === null) {
      continue;
    }
    for (let c = 0; c < cells.length; c++) {
      const cp: number = cells[c].codepoint;
      if (cp === WIDE_CONTINUATION) {
        continue;
      }
      const ch: string = cp === 0 ? ' ' : String.fromCodePoint(cp);
      text += ch;
      for (let k = 0; k < ch.length; k++) {
        positions.push({ row: r, col: c });
      }
    }
  }
  return { text: text, positions: positions, startRow: start, endRow: end };
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

  /**
   * 拖动选区起点手柄：另一端钉在当前终点，起点跟手。
   * 越过终点时 normalize 仍保证 range.start ≤ range.end。
   */
  moveStart(pos: CellPos): void {
    const current: SelectionRange | null = this.range();
    if (current === null) {
      return;
    }
    this.anchorPos = { row: current.endRow, col: current.endCol };
    this.activePos = { row: pos.row, col: pos.col };
  }

  /** 拖动选区终点手柄：另一端钉在当前起点，终点跟手。 */
  moveEnd(pos: CellPos): void {
    const current: SelectionRange | null = this.range();
    if (current === null) {
      return;
    }
    this.anchorPos = { row: current.startRow, col: current.startCol };
    this.activePos = { row: pos.row, col: pos.col };
  }

  /** 全选（气泡菜单「全选」）：锚点 (firstRow,0)，活动端 (firstRow+rows−1, cols−1) */
  selectAll(rows: number, cols: number, firstRow: number = 0): void {
    if (rows <= 0 || cols <= 0) {
      return;
    }
    this.anchorPos = { row: firstRow, col: 0 };
    this.activePos = { row: firstRow + rows - 1, col: cols - 1 };
  }

  /** 直接设定选区（双击选词/三击选行/点链接） */
  setRange(start: CellPos, end: CellPos): void {
    this.anchorPos = { row: start.row, col: start.col };
    this.activePos = { row: end.row, col: end.col };
  }

  /** 选区整体平移 delta 行（绝对行坐标体系重建时用；当前未用于常规路径） */
  shiftRows(delta: number): void {
    if (this.anchorPos === null || this.activePos === null || delta === 0) {
      return;
    }
    this.anchorPos = { row: this.anchorPos.row + delta, col: this.anchorPos.col };
    this.activePos = { row: this.activePos.row + delta, col: this.activePos.col };
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
