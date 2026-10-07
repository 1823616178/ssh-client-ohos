/**
 * KeyMap 按键→VT 序列映射测试（hypium，任务 T6）。
 *
 * 断言全部为具体字节序列（hex 串对拍），覆盖验收标准派生语义：
 *   - modifierParam 修正参数全组合（xterm：1 + Shift1/Alt2/Ctrl4）；
 *   - 方向键普通/应用光标两种模式、Ctrl/Shift/Alt 组合修正参数形式；
 *   - Home/End（xterm 变体 CSI H/F）、PgUp/PgDn、Insert/Delete；
 *   - F1–F12 xterm 序列全表（含带修饰形式）；
 *   - Ctrl+字母全表（a-z → 0x01–0x1A）与经典等价（Ctrl+[/\\//]/空格/2/8）；
 *   - Alt 前缀、Shift+Tab、Meta 按 Alt 处理、Backspace/Enter/Escape；
 *   - 未映射键/修饰键自身/未定义 Ctrl 组合返回 null（不乱发字节）。
 * 另含 FocusManager 聚焦路由语义（register/focus/unregister/监听器）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  KEY_0,
  KEY_A,
  KEY_APOSTROPHE,
  KEY_BACKSLASH,
  KEY_BACKSPACE,
  KEY_DPAD_DOWN,
  KEY_DPAD_LEFT,
  KEY_DPAD_RIGHT,
  KEY_DPAD_UP,
  KEY_ENTER,
  KEY_EQUALS,
  KEY_ESCAPE,
  KEY_F1,
  KEY_FORWARD_DEL,
  KEY_GRAVE,
  KEY_INSERT,
  KEY_LEFT_BRACKET,
  KEY_MINUS,
  KEY_MOVE_END,
  KEY_MOVE_HOME,
  KEY_PAGE_DOWN,
  KEY_PAGE_UP,
  KEY_RIGHT_BRACKET,
  KEY_SEMICOLON,
  KEY_SLASH,
  KEY_SPACE,
  KEY_TAB,
  KEY_Z,
  isModifierKeyCode,
  isPrintableKeyCode,
  mapKeyEvent,
  modifierParam
} from '../main/ets/view/terminal/KeyMap';
import { FocusManager } from '../main/ets/view/terminal/FocusManager';

/** Uint8Array → 小写 hex 串（null 收编为 'null'，便于直接 assertEqual） */
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

/** ASCII/控制字符字面量 → 期望 hex 串（与 hex() 同编码） */
function hexOf(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    out += (s.charCodeAt(i) & 0xFF).toString(16).padStart(2, '0');
  }
  return out;
}

/** 断言映射结果等于期望字面量 */
function assertSeq(actual: Uint8Array | null, expected: string): void {
  expect(hex(actual)).assertEqual(hexOf(expected));
}

/** 无修饰调用简写 */
function key(keyCode: number, appCursorKeys: boolean = false): Uint8Array | null {
  return mapKeyEvent(keyCode, false, false, false, false, appCursorKeys);
}

export default function keyMapTest() {
  describe('KeyMapTest', () => {

    it('modifierParam修正参数全组合', 0, () => {
      expect(modifierParam(false, false, false)).assertEqual(1); // 无修饰不携带参数
      expect(modifierParam(true, false, false)).assertEqual(2); // Shift
      expect(modifierParam(false, true, false)).assertEqual(3); // Alt
      expect(modifierParam(true, true, false)).assertEqual(4);
      expect(modifierParam(false, false, true)).assertEqual(5); // Ctrl
      expect(modifierParam(true, false, true)).assertEqual(6);
      expect(modifierParam(false, true, true)).assertEqual(7);
      expect(modifierParam(true, true, true)).assertEqual(8);
    });

    it('方向键普通模式CSI', 0, () => {
      assertSeq(key(KEY_DPAD_UP), '\x1b[A');
      assertSeq(key(KEY_DPAD_DOWN), '\x1b[B');
      assertSeq(key(KEY_DPAD_RIGHT), '\x1b[C');
      assertSeq(key(KEY_DPAD_LEFT), '\x1b[D');
    });

    it('方向键应用光标模式SS3', 0, () => {
      assertSeq(key(KEY_DPAD_UP, true), '\x1bOA');
      assertSeq(key(KEY_DPAD_DOWN, true), '\x1bOB');
      assertSeq(key(KEY_DPAD_RIGHT, true), '\x1bOC');
      assertSeq(key(KEY_DPAD_LEFT, true), '\x1bOD');
    });

    it('带修饰方向键CSI修正参数形式', 0, () => {
      assertSeq(mapKeyEvent(KEY_DPAD_UP, false, false, true, false, false), '\x1b[1;5A'); // Ctrl+↑
      assertSeq(mapKeyEvent(KEY_DPAD_DOWN, false, true, false, false, false), '\x1b[1;3B'); // Alt+↓
      assertSeq(mapKeyEvent(KEY_DPAD_RIGHT, true, false, false, false, false), '\x1b[1;2C'); // Shift+→
      assertSeq(mapKeyEvent(KEY_DPAD_LEFT, true, true, true, false, false), '\x1b[1;8D'); // 全修饰
      // 应用光标模式下带修饰仍是 CSI 修正参数形式（xterm 惯例）
      assertSeq(mapKeyEvent(KEY_DPAD_UP, false, false, true, false, true), '\x1b[1;5A');
    });

    it('Home_End取xterm变体', 0, () => {
      assertSeq(key(KEY_MOVE_HOME), '\x1b[H');
      assertSeq(key(KEY_MOVE_END), '\x1b[F');
      assertSeq(mapKeyEvent(KEY_MOVE_HOME, false, false, true, false, false), '\x1b[1;5H');
      assertSeq(mapKeyEvent(KEY_MOVE_END, true, false, false, false, false), '\x1b[1;2F');
    });

    it('PgUp_PgDn_Insert_Delete波浪号形式', 0, () => {
      assertSeq(key(KEY_PAGE_UP), '\x1b[5~');
      assertSeq(key(KEY_PAGE_DOWN), '\x1b[6~');
      assertSeq(key(KEY_INSERT), '\x1b[2~');
      assertSeq(key(KEY_FORWARD_DEL), '\x1b[3~');
      assertSeq(mapKeyEvent(KEY_PAGE_DOWN, false, true, false, false, false), '\x1b[6;3~');
      assertSeq(mapKeyEvent(KEY_FORWARD_DEL, false, false, true, false, false), '\x1b[3;5~');
    });

    it('F1到F12全表xterm序列', 0, () => {
      assertSeq(key(KEY_F1), '\x1bOP');
      assertSeq(key(KEY_F1 + 1), '\x1bOQ');
      assertSeq(key(KEY_F1 + 2), '\x1bOR');
      assertSeq(key(KEY_F1 + 3), '\x1bOS');
      assertSeq(key(KEY_F1 + 4), '\x1b[15~'); // F5
      assertSeq(key(KEY_F1 + 5), '\x1b[17~');
      assertSeq(key(KEY_F1 + 6), '\x1b[18~');
      assertSeq(key(KEY_F1 + 7), '\x1b[19~');
      assertSeq(key(KEY_F1 + 8), '\x1b[20~');
      assertSeq(key(KEY_F1 + 9), '\x1b[21~');
      assertSeq(key(KEY_F1 + 10), '\x1b[23~'); // F11
      assertSeq(key(KEY_F1 + 11), '\x1b[24~'); // F12
      // 带修饰：F1–F4 转 CSI 尾字符形式，F5+ 插参数
      assertSeq(mapKeyEvent(KEY_F1, false, false, true, false, false), '\x1b[1;5P');
      assertSeq(mapKeyEvent(KEY_F1 + 4, true, false, false, false, false), '\x1b[15;2~'); // Shift+F5
      assertSeq(mapKeyEvent(KEY_F1 + 11, false, true, true, false, false), '\x1b[24;7~'); // Alt+Ctrl+F12
    });

    it('T10_F1F4_SS3与DECCKM无关_导航键随标志切SS3', 0, () => {
      // xterm PC-Style：未修饰 F1–F4 一律 SS3，应用光标模式下同形
      assertSeq(key(KEY_F1, true), '\x1bOP');
      assertSeq(key(KEY_F1 + 3, true), '\x1bOS');
      // Home/End/PgUp/PgDn 不受 DECCKM 影响（xterm 变体 CSI H/F 与波浪号型）
      assertSeq(key(KEY_MOVE_HOME, true), '\x1b[H');
      assertSeq(key(KEY_MOVE_END, true), '\x1b[F');
      assertSeq(key(KEY_PAGE_UP, true), '\x1b[5~');
      assertSeq(key(KEY_PAGE_DOWN, true), '\x1b[6~');
      // 方向键在 DECCKM 下 SS3（已有用例，此处与 F 键对照锚定）
      assertSeq(key(KEY_DPAD_UP, true), '\x1bOA');
      // Alt+B / Alt+F（readline 词跳转，T10 验收点）
      assertSeq(mapKeyEvent(KEY_A + 1, false, true, false, false, false), '\x1bb');
      assertSeq(mapKeyEvent(KEY_A + 5, false, true, false, false, false), '\x1bf');
    });

    it('Ctrl加字母全表a到z', 0, () => {
      for (let i = 0; i < 26; i++) {
        const bytes = mapKeyEvent(KEY_A + i, false, false, true, false, false);
        const expected = new Uint8Array([i + 1]); // Ctrl+A=0x01 … Ctrl+Z=0x1A
        expect(hex(bytes)).assertEqual(hex(expected));
      }
      // 点名验收键：Ctrl+C=0x03、Ctrl+D=0x04、Ctrl+Z=0x1A
      assertSeq(mapKeyEvent(KEY_A + 2, false, false, true, false, false), '\x03');
      assertSeq(mapKeyEvent(KEY_A + 3, false, false, true, false, false), '\x04');
      assertSeq(mapKeyEvent(KEY_Z, false, false, true, false, false), '\x1a');
      // Shift 不改变控制字符（Ctrl+Shift+C 仍是 0x03）
      assertSeq(mapKeyEvent(KEY_A + 2, true, false, true, false, false), '\x03');
    });

    it('Ctrl经典等价映射', 0, () => {
      assertSeq(mapKeyEvent(KEY_LEFT_BRACKET, false, false, true, false, false), '\x1b'); // Ctrl+[ = Esc
      assertSeq(mapKeyEvent(KEY_BACKSLASH, false, false, true, false, false), '\x1c');
      assertSeq(mapKeyEvent(KEY_RIGHT_BRACKET, false, false, true, false, false), '\x1d');
      assertSeq(mapKeyEvent(KEY_SLASH, false, false, true, false, false), '\x1f');
      assertSeq(mapKeyEvent(KEY_MINUS, false, false, true, false, false), '\x1f');
      assertSeq(mapKeyEvent(KEY_SPACE, false, false, true, false, false), '\x00');
      assertSeq(mapKeyEvent(KEY_0 + 2, false, false, true, false, false), '\x00'); // Ctrl+2
      assertSeq(mapKeyEvent(KEY_0 + 6, false, false, true, false, false), '\x1e'); // Ctrl+6
      assertSeq(mapKeyEvent(KEY_0 + 8, false, false, true, false, false), '\x7f'); // Ctrl+8
    });

    it('Alt前缀与Meta按Alt处理', 0, () => {
      assertSeq(mapKeyEvent(KEY_A + 1, false, true, false, false, false), '\x1bb'); // Alt+B（readline 后退一词）
      assertSeq(mapKeyEvent(KEY_A, true, true, false, false, false), '\x1bA'); // Alt+Shift+A
      assertSeq(mapKeyEvent(KEY_0 + 1, false, true, false, false, false), '\x1b1'); // Alt+1
      assertSeq(mapKeyEvent(KEY_A + 1, false, false, false, true, false), '\x1bb'); // Meta+B 同 Alt
    });

    it('Tab三态与Backspace_Enter_Escape', 0, () => {
      assertSeq(key(KEY_TAB), '\x09');
      assertSeq(mapKeyEvent(KEY_TAB, true, false, false, false, false), '\x1b[Z'); // Shift+Tab
      assertSeq(mapKeyEvent(KEY_TAB, false, false, true, false, false), '\x1b[1;5I'); // Ctrl+Tab
      assertSeq(mapKeyEvent(KEY_TAB, false, true, false, false, false), '\x1b\x09'); // Alt+Tab
      assertSeq(key(KEY_BACKSPACE), '\x7f'); // Backspace = DEL
      assertSeq(mapKeyEvent(KEY_BACKSPACE, false, true, false, false, false), '\x1b\x7f'); // Alt+Backspace
      assertSeq(key(KEY_ENTER), '\x0d');
      assertSeq(key(KEY_ESCAPE), '\x1b');
    });

    it('无修饰可打印字符US布局', 0, () => {
      assertSeq(key(KEY_A), 'a');
      assertSeq(mapKeyEvent(KEY_A, true, false, false, false, false), 'A');
      assertSeq(key(KEY_0 + 1), '1');
      assertSeq(mapKeyEvent(KEY_0 + 1, true, false, false, false, false), '!'); // Shift+1
      assertSeq(mapKeyEvent(KEY_0, true, false, false, false, false), ')'); // Shift+0
      assertSeq(key(KEY_MINUS), '-');
      assertSeq(mapKeyEvent(KEY_MINUS, true, false, false, false, false), '_');
      assertSeq(key(KEY_LEFT_BRACKET), '[');
      assertSeq(mapKeyEvent(KEY_LEFT_BRACKET, true, false, false, false, false), '{');
      assertSeq(key(KEY_SEMICOLON), ';');
      assertSeq(mapKeyEvent(KEY_APOSTROPHE, true, false, false, false, false), '"');
      assertSeq(key(KEY_GRAVE), '`');
      assertSeq(mapKeyEvent(KEY_EQUALS, true, false, false, false, false), '+');
      assertSeq(key(KEY_SPACE), ' ');
    });

    it('未映射与未定义组合返回null', 0, () => {
      expect(mapKeyEvent(9999, false, false, false, false, false)).assertNull(); // 未知键码
      expect(mapKeyEvent(2103, false, false, false, false, false)).assertNull(); // 小键盘（T10 再扩）
      expect(mapKeyEvent(KEY_SEMICOLON, false, false, true, false, false)).assertNull(); // Ctrl+; 未定义
      expect(mapKeyEvent(KEY_0 + 1, false, false, true, false, false)).assertNull(); // Ctrl+1 未定义
      expect(mapKeyEvent(KEY_GRAVE, false, false, true, false, false)).assertNull(); // Ctrl+` 未定义
    });

    it('修饰键自身返回null且可判定', 0, () => {
      const modifierCodes: number[] = [2045, 2046, 2047, 2048, 2072, 2073, 2074, 2075, 2076, 2077, 2102];
      for (const code of modifierCodes) {
        expect(isModifierKeyCode(code)).assertTrue();
        expect(mapKeyEvent(code, false, false, false, false, false)).assertNull();
      }
      expect(isModifierKeyCode(KEY_A)).assertFalse();
      expect(isPrintableKeyCode(KEY_A)).assertTrue();
      expect(isPrintableKeyCode(KEY_0)).assertTrue();
      expect(isPrintableKeyCode(KEY_SPACE)).assertTrue();
      expect(isPrintableKeyCode(KEY_SLASH)).assertTrue();
      expect(isPrintableKeyCode(KEY_DPAD_UP)).assertFalse();
      expect(isPrintableKeyCode(KEY_F1)).assertFalse();
      expect(isPrintableKeyCode(KEY_TAB)).assertFalse(); // Tab 有专属序列，不算可打印
    });
  });
}

export function focusManagerTest() {
  describe('FocusManagerTest', () => {

    it('register首个窗格自动聚焦', 0, () => {
      const fm = new FocusManager();
      expect(fm.focusedId).assertEqual('');
      expect(fm.register('pane-a')).assertTrue();
      expect(fm.focusedId).assertEqual('pane-a');
      expect(fm.isFocused('pane-a')).assertTrue();
      expect(fm.register('pane-b')).assertTrue();
      expect(fm.focusedId).assertEqual('pane-a'); // 第二个不抢焦点
      expect(fm.size).assertEqual(2);
    });

    it('focus切换后仅聚焦窗格收输入', 0, () => {
      const fm = new FocusManager();
      fm.register('pane-a');
      fm.register('pane-b');
      expect(fm.focus('pane-b')).assertTrue();
      expect(fm.isFocused('pane-a')).assertFalse(); // 分屏下只有聚焦窗格收到输入
      expect(fm.isFocused('pane-b')).assertTrue();
      expect(fm.focusedId).assertEqual('pane-b');
      expect(fm.focus('pane-a')).assertTrue();
      expect(fm.isFocused('pane-a')).assertTrue();
      expect(fm.isFocused('pane-b')).assertFalse();
    });

    it('focus未知id拒绝且焦点不动', 0, () => {
      const fm = new FocusManager();
      fm.register('pane-a');
      expect(fm.focus('ghost')).assertFalse();
      expect(fm.focusedId).assertEqual('pane-a');
      expect(fm.isFocused('')).assertFalse(); // 空 id 永不聚焦
    });

    it('unregister聚焦窗格不自动改投', 0, () => {
      const fm = new FocusManager();
      fm.register('pane-a');
      fm.register('pane-b');
      expect(fm.unregister('pane-a')).assertTrue(); // 注销聚焦窗格
      expect(fm.focusedId).assertEqual(''); // 焦点置空而非改投 pane-b（防误投）
      expect(fm.isFocused('pane-b')).assertFalse();
      expect(fm.unregister('ghost')).assertFalse();
      expect(fm.size).assertEqual(1);
      // 显式 focus 恢复
      expect(fm.focus('pane-b')).assertTrue();
      expect(fm.isFocused('pane-b')).assertTrue();
    });

    it('重复注册与空id拒绝', 0, () => {
      const fm = new FocusManager();
      expect(fm.register('')).assertFalse();
      expect(fm.register('pane-a')).assertTrue();
      expect(fm.register('pane-a')).assertFalse();
      expect(fm.size).assertEqual(1);
    });

    it('焦点变化按序通知监听器', 0, () => {
      const fm = new FocusManager();
      const events: string[] = [];
      const remove = fm.addListener((id: string) => {
        events.push(id);
      });
      fm.addListener((id: string) => {
        events.push(`L2:${id}`);
      });
      fm.register('pane-a'); // 自动聚焦 → 通知
      fm.focus('pane-a'); // 同值不重复通知
      fm.register('pane-b');
      fm.focus('pane-b');
      fm.unregister('pane-b'); // 聚焦窗格注销 → 通知空串
      expect(events.length).assertEqual(6);
      expect(events[0]).assertEqual('pane-a');
      expect(events[1]).assertEqual('L2:pane-a');
      expect(events[2]).assertEqual('pane-b');
      expect(events[3]).assertEqual('L2:pane-b');
      expect(events[4]).assertEqual('');
      expect(events[5]).assertEqual('L2:');
      remove();
      fm.register('pane-c');
      fm.focus('pane-c');
      expect(events.length).assertEqual(7); // 解除后只剩 L2
      expect(events[6]).assertEqual('L2:pane-c');
    });
  });
}
