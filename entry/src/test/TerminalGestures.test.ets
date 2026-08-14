/**
 * TerminalGestures / Pasteboard 纯逻辑测试（hypium，任务 T9 + T8 粘贴侧）。
 *
 * 覆盖：
 *  - clampScrollOffset：偏移钳制 [0, 回滚行数]（负值/超界/无回滚）；
 *  - ScrollLineAccumulator：不足一行累计、整行产出、反向（上滑）带符号行数、
 *    reset、格高 0 防御；
 *  - buildAltScrollSequences：keys/mouse/view 三模式映射、每行一条、
 *    方向语义（手指下滑=看旧内容=↑/滚轮上64）、mouseMode=None 回退方向键、
 *    SGR 序列坐标（1 起）；
 *  - clampFontSize：8–32 钳制与非法值；
 *  - wrapBracketedPaste / containsLineBreak（T8 bracketed paste）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ScrollLineAccumulator,
  buildAltScrollSequences,
  clampFontSize,
  clampScrollOffset
} from '../main/ets/view/terminal/TerminalGestures';
import {
  containsLineBreak,
  wrapBracketedPaste
} from '../main/ets/view/terminal/Pasteboard';

/** 字节序列 → 可读字符串（测试断言用；序列为纯 ASCII） */
function bytesToString(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += String.fromCharCode(bytes[i]);
  }
  return s;
}

export default function terminalGesturesTest() {
  describe('TerminalGesturesTest', () => {

    it('scrollOffset钳制', 0, () => {
      expect(clampScrollOffset(5, 10)).assertEqual(5);
      expect(clampScrollOffset(-1, 10)).assertEqual(0);
      expect(clampScrollOffset(15, 10)).assertEqual(10);
      expect(clampScrollOffset(3, -2)).assertEqual(0); // 无回滚（负上限按 0）
      expect(clampScrollOffset(0, 0)).assertEqual(0);
    });

    it('滚动行换算不足一行累计跨事件', 0, () => {
      const acc = new ScrollLineAccumulator();
      // 格高 10vp：4+4 不足一行不出行，再 +4 累计 12 → 1 行，余 2
      expect(acc.push(4, 10)).assertEqual(0);
      expect(acc.push(4, 10)).assertEqual(0);
      expect(acc.push(4, 10)).assertEqual(1);
      // 余量 2 再 +9 = 11 → 1 行
      expect(acc.push(9, 10)).assertEqual(1);
    });

    it('滚动行换算反向带符号', 0, () => {
      const acc = new ScrollLineAccumulator();
      // 手指上滑 25vp（格高 10）→ -2 行（向 0 取整），余 -5
      expect(acc.push(-25, 10)).assertEqual(-2);
      expect(acc.push(-6, 10)).assertEqual(-1); // -5 + -6 = -11 → -1 行
    });

    it('滚动行换算reset与零格高防御', 0, () => {
      const acc = new ScrollLineAccumulator();
      expect(acc.push(12, 10)).assertEqual(1); // 余 2
      acc.reset();
      expect(acc.push(3, 10)).assertEqual(0); // 余量已清
      expect(acc.push(100, 0)).assertEqual(0); // 格高 0（度量未完成）：不滚动
    });

    it('altScroll keys模式映射方向键', 0, () => {
      // 手指下滑 2 行 = 看旧内容 = 两次 ↑
      const down = buildAltScrollSequences('keys', 0, 2, 5, 3);
      expect(down.length).assertEqual(2);
      expect(bytesToString(down[0])).assertEqual('\x1b[A');
      // 手指上滑 3 行 = 看新内容 = 三次 ↓
      const up = buildAltScrollSequences('keys', 0, -3, 5, 3);
      expect(up.length).assertEqual(3);
      expect(bytesToString(up[0])).assertEqual('\x1b[B');
    });

    it('altScroll mouse模式发SGR滚轮序列', 0, () => {
      // mouseMode=2（拖动上报）：下滑 1 行 = 滚轮上 64，坐标 1 起
      const seqs = buildAltScrollSequences('mouse', 2, 1, 5, 3);
      expect(seqs.length).assertEqual(1);
      expect(bytesToString(seqs[0])).assertEqual('\x1b[<64;5;3M');
      const upSeqs = buildAltScrollSequences('mouse', 2, -1, 5, 3);
      expect(bytesToString(upSeqs[0])).assertEqual('\x1b[<65;5;3M');
    });

    it('altScroll mouse模式未开上报回退方向键', 0, () => {
      const seqs = buildAltScrollSequences('mouse', 0, 1, 5, 3);
      expect(seqs.length).assertEqual(1);
      expect(bytesToString(seqs[0])).assertEqual('\x1b[A');
    });

    it('altScroll view模式不发字节', 0, () => {
      expect(buildAltScrollSequences('view', 0, 3, 5, 3).length).assertEqual(0);
      expect(buildAltScrollSequences('keys', 0, 0, 5, 3).length).assertEqual(0);
    });

    it('捏合字号钳制8到32', 0, () => {
      expect(clampFontSize(7.9)).assertEqual(8);
      expect(clampFontSize(8)).assertEqual(8);
      expect(clampFontSize(20)).assertEqual(20);
      expect(clampFontSize(33)).assertEqual(32);
      expect(clampFontSize(Number.NaN)).assertEqual(8);
    });

    it('bracketedPaste包裹与原样', 0, () => {
      expect(wrapBracketedPaste('abc', true)).assertEqual('\x1b[200~abc\x1b[201~');
      expect(wrapBracketedPaste('abc', false)).assertEqual('abc');
      expect(wrapBracketedPaste('a\nb', true)).assertEqual('\x1b[200~a\nb\x1b[201~');
    });

    it('多行检测', 0, () => {
      expect(containsLineBreak('a\nb')).assertTrue();
      expect(containsLineBreak('a\rb')).assertTrue();
      expect(containsLineBreak('abc')).assertFalse();
      expect(containsLineBreak('')).assertFalse();
    });
  });
}
