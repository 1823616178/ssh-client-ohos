/**
 * SshTerminal 解码辅助与 R-9 探测纯函数测试（hypium，任务 T3）。
 *
 * 覆盖（均为纯函数，不触 native；native 路径由交叉编译 + 真机验证）：
 *   - decodeCellAt：16 字节 Cell 布局（码点/前景/背景/属性位）按偏移解码；
 *   - isRowDirty：脏行位图按 u32 视图读（字 [row>>5] 的位 row&31），越界防御；
 *   - collectDirtyRanges：连续脏行区间合并（含头/尾边界）；
 *   - buildSelfTestPattern / matchesSelfTestPattern：与 native
 *     terminal_bridge.cpp MakeSelfTestPattern 锚定（magic、端序、递增值），
 *     长度/内容不符的 buffer 判不匹配。
 *
 * 单元格布局与位图编码必须与 cpp/term/grid.h 保持一致（index.d.ts 有对照说明）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ATTR_BOLD,
  ATTR_WIDE,
  ATTR_REVERSE,
  CELL_BYTES,
  WIDE_CONTINUATION,
  DecodedCell,
  DirtyRange,
  buildSelfTestPattern,
  collectDirtyRanges,
  decodeCellAt,
  isRowDirty,
  matchesSelfTestPattern
} from '../main/ets/napi/SshTerminal';

/** 造一格 16 字节单元格写进 buf（小端，布局同 cpp/term/grid.h） */
function putCell(buf: Uint8Array, cellIndex: number, codepoint: number, fg: number,
  bg: number, attrs: number): void {
  const view = new DataView(buf.buffer);
  const off = cellIndex * CELL_BYTES;
  view.setUint32(off, codepoint, true);
  view.setUint32(off + 4, fg, true);
  view.setUint32(off + 8, bg, true);
  view.setUint16(off + 12, attrs, true);
  view.setUint16(off + 14, 0, true);
}

/** 造 rows 行的脏行位图（dirtyRows 为脏行号列表），编码同 native u64 字数组 */
function makeDirtyBitmap(rows: number, dirtyRows: number[]): ArrayBuffer {
  const words = Math.ceil(rows / 32);
  const buf = new ArrayBuffer(words * 4);
  const view = new DataView(buf);
  for (let i = 0; i < dirtyRows.length; i++) {
    const r = dirtyRows[i];
    const w = r >> 5;
    view.setUint32(w * 4, view.getUint32(w * 4, true) | (1 << (r & 31)), true);
  }
  return buf;
}

export default function sshTerminalTest() {
  describe('SshTerminalTest', () => {

    it('decodeCellAt_按16字节布局解码', 0, () => {
      const buf = new Uint8Array(4 * CELL_BYTES);
      putCell(buf, 0, 0x61, 0xFFE5E5E5, 0xFF000000, 0);
      putCell(buf, 1, 0x4E2D, 0xFFFF0000, 0xFF0000FF, ATTR_BOLD);
      putCell(buf, 2, WIDE_CONTINUATION, 0xFF00FF00, 0xFF111111, 0);
      putCell(buf, 3, 0x1F600, 0xFFFFFFFF, 0xFF222222, ATTR_WIDE | ATTR_REVERSE);
      const view = new DataView(buf.buffer);

      const c0: DecodedCell = decodeCellAt(view, 0);
      expect(c0.codepoint).assertEqual(0x61);
      expect(c0.fgArgb).assertEqual(0xFFE5E5E5);
      expect(c0.bgArgb).assertEqual(0xFF000000);
      expect(c0.attrs).assertEqual(0);

      const c1: DecodedCell = decodeCellAt(view, 1);
      expect(c1.codepoint).assertEqual(0x4E2D); // 「中」
      expect(c1.fgArgb).assertEqual(0xFFFF0000);
      expect(c1.attrs).assertEqual(ATTR_BOLD);

      const c2: DecodedCell = decodeCellAt(view, 2);
      expect(c2.codepoint).assertEqual(WIDE_CONTINUATION);

      const c3: DecodedCell = decodeCellAt(view, 3);
      expect(c3.attrs & ATTR_WIDE).assertEqual(ATTR_WIDE);
      expect(c3.attrs & ATTR_REVERSE).assertEqual(ATTR_REVERSE);
      expect(c3.attrs & ATTR_BOLD).assertEqual(0);
    });

    it('isRowDirty_位图按行号命中', 0, () => {
      // 100 行（跨 u64 字边界：行 63/64 分属两个 u64 字）
      const dirty = makeDirtyBitmap(100, [0, 5, 63, 64, 99]);
      expect(isRowDirty(dirty, 0)).assertTrue();
      expect(isRowDirty(dirty, 5)).assertTrue();
      expect(isRowDirty(dirty, 63)).assertTrue();
      expect(isRowDirty(dirty, 64)).assertTrue();
      expect(isRowDirty(dirty, 99)).assertTrue();
      expect(isRowDirty(dirty, 1)).assertFalse();
      expect(isRowDirty(dirty, 62)).assertFalse();
      expect(isRowDirty(dirty, 65)).assertFalse();
      expect(isRowDirty(dirty, 98)).assertFalse();
    });

    it('isRowDirty_越界行防御为干净', 0, () => {
      const dirty = makeDirtyBitmap(24, [23]);
      expect(isRowDirty(dirty, 23)).assertTrue();
      expect(isRowDirty(dirty, 24)).assertFalse();  // 超出位图容量
      expect(isRowDirty(dirty, 1000)).assertFalse();
    });

    it('collectDirtyRanges_连续区间合并', 0, () => {
      const dirty = makeDirtyBitmap(24, [0, 1, 2, 5, 7, 8, 23]);
      const ranges: DirtyRange[] = collectDirtyRanges(dirty, 24);
      expect(ranges.length).assertEqual(4);
      expect(ranges[0].start).assertEqual(0);
      expect(ranges[0].end).assertEqual(3);
      expect(ranges[1].start).assertEqual(5);
      expect(ranges[1].end).assertEqual(6);
      expect(ranges[2].start).assertEqual(7);
      expect(ranges[2].end).assertEqual(9);
      expect(ranges[3].start).assertEqual(23);
      expect(ranges[3].end).assertEqual(24); // 尾边界：最后一行脏，end 收在 rows
    });

    it('collectDirtyRanges_全干净与全脏', 0, () => {
      expect(collectDirtyRanges(makeDirtyBitmap(24, []), 24).length).assertEqual(0);
      const all: number[] = [];
      for (let i = 0; i < 24; i++) {
        all.push(i);
      }
      const ranges = collectDirtyRanges(makeDirtyBitmap(24, all), 24);
      expect(ranges.length).assertEqual(1);
      expect(ranges[0].start).assertEqual(0);
      expect(ranges[0].end).assertEqual(24);
    });

    it('selfTestPattern_与native模式锚定', 0, () => {
      const p = buildSelfTestPattern();
      expect(p.length).assertEqual(32);
      // magic "SSHTGRID"
      expect(String.fromCharCode(p[0], p[1], p[2], p[3])).assertEqual('SSHT');
      expect(String.fromCharCode(p[4], p[5], p[6], p[7])).assertEqual('GRID');
      // 端序校验字：u32 LE 读回 0x01020304
      const view = new DataView(p.buffer);
      expect(view.getUint32(8, true)).assertEqual(0x01020304);
      expect(view.getUint32(12, true)).assertEqual(0xA5A55A5A);
      // 递增值
      for (let i = 16; i < 32; i++) {
        expect(p[i]).assertEqual(i - 16);
      }
    });

    it('matchesSelfTestPattern_一致与不一致', 0, () => {
      const good = buildSelfTestPattern();
      expect(matchesSelfTestPattern(good.buffer.slice(0))).assertTrue();

      const bad = buildSelfTestPattern();
      bad[20] = 0xFF; // 篡改一字节
      expect(matchesSelfTestPattern(bad.buffer.slice(0))).assertFalse();

      expect(matchesSelfTestPattern(new ArrayBuffer(16))).assertFalse(); // 长度不符
      expect(matchesSelfTestPattern(new ArrayBuffer(64))).assertFalse();
    });

  });
}
