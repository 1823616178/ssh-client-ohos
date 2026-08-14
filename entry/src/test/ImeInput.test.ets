/**
 * ImeInputHandler 增量与候选期语义测试（hypium，任务 T6）。
 *
 * 覆盖验收标准派生语义（断言为具体字节序列）：
 *   - extractCommittedDelta：纯新增（ASCII/中文）、批量退格、混合编辑、
 *     无变化、候选期（previewActive）不产出；
 *   - committedDeltaToInputBytes：退格 = 0x7F×n、中文 UTF-8 提交、
 *     粘滞 Ctrl+单字符 → 控制字符、粘滞 Alt 前缀、Ctrl+未定义字符整次不发、
 *     Alt+退格 = ESC+0x7F×n；
 *   - 候选期「不更新基线」配合语义：候选中值不参与 diff（中文上屏只发一次）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  CommittedDelta,
  committedDeltaToInputBytes,
  extractCommittedDelta
} from '../main/ets/view/terminal/ImeInputHandler';
import { StickySnapshot } from '../main/ets/view/terminal/StickyModifiers';

const NO_STICKY: StickySnapshot = { ctrl: false, alt: false };
const STICKY_CTRL: StickySnapshot = { ctrl: true, alt: false };
const STICKY_ALT: StickySnapshot = { ctrl: false, alt: true };

/** Uint8Array → 小写 hex 串（null 收编为 'null'） */
function hex(bytes: Uint8Array | null): string {
  if (bytes === null) {
    return 'null';
  }
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    s += bytes[i].toString(16).padStart(2, '0');
  }
  return s;
}

/** 期望值：ASCII 字面量 → hex 串 */
function hexOf(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    out += (s.charCodeAt(i) & 0xFF).toString(16).padStart(2, '0');
  }
  return out;
}

/** 解包 delta：null 时先记一次断言失败再抛错中断本用例（hypium 无 assertNotNull） */
function must(d: CommittedDelta | null): CommittedDelta {
  expect(d === null).assertFalse();
  if (d === null) {
    throw new Error('unreachable: delta is null');
  }
  return d;
}

export default function imeInputTest() {
  describe('ImeInputTest', () => {

    it('纯新增ASCII文本', 0, () => {
      const d = must(extractCommittedDelta('hel', 'hello', false));
      expect(d.text).assertEqual('lo');
      expect(d.backspaces).assertEqual(0);
    });

    it('中文整字提交', 0, () => {
      const d = must(extractCommittedDelta('', '你好', false));
      expect(d.text).assertEqual('你好');
      expect(d.backspaces).assertEqual(0);
      // UTF-8：你 E4BDA0、好 E5A5BD
      expect(hex(committedDeltaToInputBytes(d, NO_STICKY))).assertEqual('e4bda0e5a5bd');
    });

    it('候选期不发送', 0, () => {
      // 拼音候选：值在变化但 previewText 非空 → 一律 null（DESIGN §4.4 验收标准）
      expect(extractCommittedDelta('', 'n', true)).assertNull();
      expect(extractCommittedDelta('n', 'ni', true)).assertNull();
      expect(extractCommittedDelta('ni', 'ni h', true)).assertNull();
      // 候选期含删除也不产出
      expect(extractCommittedDelta('ni', 'n', true)).assertNull();
    });

    it('候选期基线不更新配合语义', 0, () => {
      // 模拟组件策略：候选期不更新 lastValue，提交时与候选前基线 diff
      const base = 'ls ';
      // 候选中：值变为 'ls n'、'ls ni'（previewActive → 跳过且不更新基线）
      expect(extractCommittedDelta(base, 'ls n', true)).assertNull();
      expect(extractCommittedDelta(base, 'ls ni', true)).assertNull();
      // 提交「你」：preview 结束，与候选前基线 diff → 只发「你」
      const d = must(extractCommittedDelta(base, 'ls 你', false));
      expect(d.text).assertEqual('你');
      expect(d.backspaces).assertEqual(0);
      // 候选取消（值回到基线）：diff 为空 → null 不误发
      expect(extractCommittedDelta(base, base, false)).assertNull();
    });

    it('退格批量与码点计数', 0, () => {
      const d = must(extractCommittedDelta('hello', 'hel', false));
      expect(d.text).assertEqual('');
      expect(d.backspaces).assertEqual(2);
      expect(hex(committedDeltaToInputBytes(d, NO_STICKY))).assertEqual(hexOf('\x7f\x7f'));
      // emoji 代理对按 1 个码点计（一次退格一个字符）
      const e = must(extractCommittedDelta('a😀', 'a', false));
      expect(e.backspaces).assertEqual(1);
      expect(hex(committedDeltaToInputBytes(e, NO_STICKY))).assertEqual(hexOf('\x7f'));
      // 中文退格同样按字符
      expect(must(extractCommittedDelta('你好', '你', false)).backspaces).assertEqual(1);
    });

    it('混合编辑等价删尾补尾', 0, () => {
      const d = must(extractCommittedDelta('hello', 'heXllo', false));
      expect(d.backspaces).assertEqual(3); // 'llo' 被删
      expect(d.text).assertEqual('Xllo');
      // 字节：3×0x7F + 'Xllo'
      expect(hex(committedDeltaToInputBytes(d, NO_STICKY)))
        .assertEqual(hexOf('\x7f\x7f\x7fXllo'));
    });

    it('无变化返回null', 0, () => {
      expect(extractCommittedDelta('abc', 'abc', false)).assertNull();
      expect(extractCommittedDelta('', '', false)).assertNull();
    });

    it('粘滞Ctrl加单字符为控制字符', 0, () => {
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'c', false)), STICKY_CTRL)))
        .assertEqual(hexOf('\x03')); // 粘滞 Ctrl+C
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'd', false)), STICKY_CTRL)))
        .assertEqual(hexOf('\x04'));
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'z', false)), STICKY_CTRL)))
        .assertEqual(hexOf('\x1a'));
      // 大写同样映射（Shift 不影响控制字符）
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'C', false)), STICKY_CTRL)))
        .assertEqual(hexOf('\x03'));
    });

    it('粘滞Alt加单字符ESC前缀', 0, () => {
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'b', false)), STICKY_ALT)))
        .assertEqual(hexOf('\x1bb')); // Alt+B
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'A', false)), STICKY_ALT)))
        .assertEqual(hexOf('\x1bA'));
    });

    it('粘滞Ctrl加未定义字符整次不发送', 0, () => {
      // Ctrl+';' 未定义 → null（宁可不发也不乱发）
      expect(committedDeltaToInputBytes(must(extractCommittedDelta('', ';', false)), STICKY_CTRL))
        .assertNull();
    });

    it('粘滞修饰不施加于多字符整词提交', 0, () => {
      // 中文整词上屏时粘滞 Ctrl 不逐字施加（IME 提交无单键修饰语义）
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', '你好', false)), STICKY_CTRL)))
        .assertEqual('e4bda0e5a5bd');
      expect(hex(committedDeltaToInputBytes(must(extractCommittedDelta('', 'ab', false)), STICKY_ALT)))
        .assertEqual(hexOf('ab'));
    });

    it('粘滞Alt加退格ESC前缀一次', 0, () => {
      const d = must(extractCommittedDelta('hello', 'he', false));
      expect(hex(committedDeltaToInputBytes(d, STICKY_ALT)))
        .assertEqual(hexOf('\x1b\x7f\x7f\x7f')); // ESC + 3×DEL
      // Ctrl 不改变退格（xterm Backspace 惯例）
      expect(hex(committedDeltaToInputBytes(d, STICKY_CTRL))).assertEqual(hexOf('\x7f\x7f\x7f'));
    });

    it('空增量返回null', 0, () => {
      expect(committedDeltaToInputBytes({ text: '', backspaces: 0 }, NO_STICKY)).assertNull();
    });
  });
}
