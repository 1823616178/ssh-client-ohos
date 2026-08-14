/**
 * SelectionModel 选择模型测试（hypium，任务 T8）。
 *
 * 覆盖（全部不触 ArkUI/native，网格用 16B/格 DataView 手工构造）：
 *  - 单行/跨行提取：行间补 '\n'、行内空单元格当空格、行尾去空格；
 *  - 规范化：反向拖动（锚点晚于活动端）收敛为 start ≤ end；
 *  - 宽字符边界：起点落续格前移含整字、终点落首格后延含整字（不切半个字）；
 *  - SelectionModel 状态机：begin/extend/cancel/selectAll/range/extractText。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ATTR_WIDE,
  CELL_BYTES,
  WIDE_CONTINUATION
} from '../main/ets/napi/SshTerminal';
import {
  CellPos,
  SelectionGridReader,
  SelectionModel,
  dataViewGridReader,
  extractSelectionText,
  normalizeSelection
} from '../main/ets/view/terminal/SelectionModel';

const FG = 0xFFE8EEFB;
const BG = 0xFF0E131D;

/** 造一格 16 字节单元格（布局同 cpp/term/grid.h，与 TerminalRender.test 同口径） */
function putCell(view: DataView, cellIndex: number, codepoint: number, attrs: number): void {
  const off = cellIndex * CELL_BYTES;
  view.setUint32(off, codepoint, true);
  view.setUint32(off + 4, FG, true);
  view.setUint32(off + 8, BG, true);
  view.setUint16(off + 12, attrs, true);
  view.setUint16(off + 14, 0, true);
}

/** 构造 rows×cols 网格并写入各行文本；wideCols 登记宽字符（码点）落位 */
function makeGrid(lines: string[], cols: number, wideRows: number[] = []): DataView {
  const rows = lines.length;
  const view = new DataView(new ArrayBuffer(rows * cols * CELL_BYTES));
  for (let i = 0; i < rows * cols; i++) {
    putCell(view, i, 0, 0);
  }
  for (let r = 0; r < rows; r++) {
    const wide = wideRows.indexOf(r) >= 0;
    let c = 0;
    for (const ch of Array.from(lines[r])) {
      if (c >= cols) {
        break;
      }
      const cp = ch.codePointAt(0) ?? 0;
      if (wide) {
        // 测试里 wideRows 的每个字符都按宽字符落位（首格 + 续格）
        putCell(view, r * cols + c, cp, ATTR_WIDE);
        if (c + 1 < cols) {
          putCell(view, r * cols + c + 1, WIDE_CONTINUATION, 0);
        }
        c += 2;
      } else {
        putCell(view, r * cols + c, cp, 0);
        c += 1;
      }
    }
  }
  return view;
}

function readerOf(lines: string[], cols: number, wideRows: number[] = []): SelectionGridReader {
  const view = makeGrid(lines, cols, wideRows);
  return dataViewGridReader(view, lines.length, cols);
}

export default function selectionModelTest() {
  describe('SelectionModelTest', () => {

    it('单行提取', 0, () => {
      const reader = readerOf(['hello world'], 11);
      const text = extractSelectionText(reader, { row: 0, col: 0 }, { row: 0, col: 4 });
      expect(text).assertEqual('hello');
    });

    it('跨行拼接含换行且行尾去空格', 0, () => {
      // 行0 "abc" 右侧是空单元格；选 (0,1) → (1,2)
      const reader = readerOf(['abc', 'def'], 8);
      const text = extractSelectionText(reader, { row: 0, col: 1 }, { row: 1, col: 2 });
      expect(text).assertEqual('bc\ndef');
    });

    it('行尾填充空格被去除但行内空格保留', 0, () => {
      const reader = readerOf(['a b'], 10);
      // 选满整行（含右侧 7 个空单元格）：行内 a␣b 的空格保留，行尾空格去掉
      const text = extractSelectionText(reader, { row: 0, col: 0 }, { row: 0, col: 9 });
      expect(text).assertEqual('a b');
    });

    it('反向拖动规范化start不大于end', 0, () => {
      const anchor: CellPos = { row: 1, col: 2 };
      const active: CellPos = { row: 0, col: 1 };
      const range = normalizeSelection(anchor, active);
      expect(range.startRow).assertEqual(0);
      expect(range.startCol).assertEqual(1);
      expect(range.endRow).assertEqual(1);
      expect(range.endCol).assertEqual(2);
      // 反向选择的提取结果与正向一致
      const reader = readerOf(['abc', 'def'], 8);
      const forward = extractSelectionText(reader, { row: 0, col: 1 }, { row: 1, col: 2 });
      const backward = extractSelectionText(reader, anchor, active);
      expect(backward).assertEqual(forward);
    });

    it('起点落在宽字符续格前移一格含整字', 0, () => {
      // 第0行按宽字符落位：'甲' 占 (0,0)+(0,1)，'乙' 占 (0,2)+(0,3)
      const reader = readerOf(['甲乙'], 6, [0]);
      // 从 '甲' 的续格 (0,1) 开始选到 '乙' 续格 (0,3)：起点前移含整字
      const text = extractSelectionText(reader, { row: 0, col: 1 }, { row: 0, col: 3 });
      expect(text).assertEqual('甲乙');
    });

    it('终点落在宽字符首格后延一格含整字', 0, () => {
      const reader = readerOf(['甲乙'], 6, [0]);
      // 只选到 '甲' 的首格 (0,0)：终点后延含整字，不会切出半个 '甲'
      const text = extractSelectionText(reader, { row: 0, col: 0 }, { row: 0, col: 0 });
      expect(text).assertEqual('甲');
    });

    it('跨行宽字符边界与换行同时成立', 0, () => {
      // 行0 宽字符，行1 普通；从 '甲' 续格选到行1 'xy' 的 'x'
      const reader = readerOf(['甲乙', 'xyz'], 6, [0]);
      const text = extractSelectionText(reader, { row: 0, col: 3 }, { row: 1, col: 0 });
      expect(text).assertEqual('乙\nx');
    });

    it('状态机begin extend cancel语义', 0, () => {
      const m = new SelectionModel();
      expect(m.selecting).assertFalse();
      expect(m.range()).assertNull();
      m.extend({ row: 2, col: 2 }); // 未进入选择模式：忽略
      expect(m.selecting).assertFalse();
      m.begin({ row: 0, col: 1 });
      expect(m.selecting).assertTrue();
      m.extend({ row: 2, col: 3 });
      const range = m.range();
      expect(range?.startRow).assertEqual(0);
      expect(range?.startCol).assertEqual(1);
      expect(range?.endRow).assertEqual(2);
      expect(range?.endCol).assertEqual(3);
      m.cancel();
      expect(m.selecting).assertFalse();
      expect(m.range()).assertNull();
    });

    it('全选覆盖整个主屏', 0, () => {
      const reader = readerOf(['ab', 'cde'], 8);
      const m = new SelectionModel();
      m.selectAll(2, 8);
      expect(m.selecting).assertTrue();
      expect(m.extractText(reader)).assertEqual('ab\ncde');
    });

    it('模型extractText与函数口径一致', 0, () => {
      const reader = readerOf(['hello', 'world'], 8);
      const m = new SelectionModel();
      m.begin({ row: 0, col: 1 });
      m.extend({ row: 1, col: 3 });
      expect(m.extractText(reader)).assertEqual('ello\nworl');
      m.cancel();
      expect(m.extractText(reader)).assertEqual('');
    });
  });
}
