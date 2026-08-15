/**
 * ShortcutMap 单元测试（DESIGN §4.3.2 可自定义快捷键表）。
 *
 * 覆盖：默认表命中 / 不抢 Ctrl+C/Z/D/W / 自定义 JSON 整表替换 /
 * 非法 JSON 与空表回退默认 / 键名大小写 / keyCode 直写 / 修饰键必须精确匹配。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  KEY_DPAD_LEFT,
  KEY_EQUALS,
  KEY_MINUS,
  KEY_TAB
} from '../main/ets/view/terminal/KeyMap';
import {
  DEFAULT_SHORTCUTS,
  ShortcutAction,
  ShortcutBinding,
  keyCodeOfName,
  letterKeyCode,
  matchShortcut,
  parseShortcutLayout
} from '../main/ets/view/terminal/ShortcutMap';

function matchDefault(keyCode: number, ctrl: boolean, alt: boolean, shift: boolean): ShortcutAction | null {
  return matchShortcut(DEFAULT_SHORTCUTS, keyCode, ctrl, alt, shift, false);
}

export default function shortcutMapTest() {
  describe('ShortcutMapTest', () => {

    it('默认表_WindowsTerminal同构组合全部命中', 0, () => {
      expect(matchDefault(letterKeyCode('T'), true, false, true)).assertEqual('newTab');
      expect(matchDefault(letterKeyCode('W'), true, false, true)).assertEqual('closePane');
      expect(matchDefault(letterKeyCode('Q'), true, false, true)).assertEqual('closeTab');
      expect(matchDefault(KEY_TAB, true, false, false)).assertEqual('nextTab');
      expect(matchDefault(KEY_TAB, true, false, true)).assertEqual('prevTab');
      expect(matchDefault(KEY_EQUALS, false, true, true)).assertEqual('splitRow');
      expect(matchDefault(KEY_MINUS, false, true, true)).assertEqual('splitColumn');
      expect(matchDefault(KEY_DPAD_LEFT, false, true, false)).assertEqual('focusLeft');
      expect(matchDefault(letterKeyCode('C'), true, false, true)).assertEqual('copy');
      expect(matchDefault(letterKeyCode('V'), true, false, true)).assertEqual('paste');
    });

    it('默认表_不抢终端常用键_CtrlC与CtrlW与CtrlD与AltLeft无Shift', 0, () => {
      expect(matchDefault(letterKeyCode('C'), true, false, false)).assertNull();
      expect(matchDefault(letterKeyCode('Z'), true, false, false)).assertNull();
      expect(matchDefault(letterKeyCode('D'), true, false, false)).assertNull();
      expect(matchDefault(letterKeyCode('W'), true, false, false)).assertNull();
      expect(matchDefault(letterKeyCode('L'), true, false, false)).assertNull();
      // Alt+B / Alt+F 是 readline 词跳转，默认表只用 Alt+方向
      expect(matchDefault(letterKeyCode('B'), false, true, false)).assertNull();
      expect(matchDefault(letterKeyCode('F'), false, true, false)).assertNull();
    });

    it('修饰键必须四者精确相等_少Shift或不该有的Ctrl都不命中', 0, () => {
      expect(matchDefault(letterKeyCode('T'), true, false, false)).assertNull();
      expect(matchDefault(letterKeyCode('T'), false, false, true)).assertNull();
      expect(matchDefault(letterKeyCode('T'), true, true, true)).assertNull();
      expect(matchShortcut(DEFAULT_SHORTCUTS, letterKeyCode('T'), true, false, true, true)).assertNull();
    });

    it('parse_空串回退默认_非法JSON回退默认', 0, () => {
      const empty: ShortcutBinding[] = parseShortcutLayout('');
      expect(empty.length).assertEqual(DEFAULT_SHORTCUTS.length);
      expect(parseShortcutLayout('   ').length).assertEqual(DEFAULT_SHORTCUTS.length);
      expect(parseShortcutLayout('{not json}').length).assertEqual(DEFAULT_SHORTCUTS.length);
      expect(parseShortcutLayout('{"action":"newTab"}').length).assertEqual(DEFAULT_SHORTCUTS.length);
      expect(parseShortcutLayout('[]').length).assertEqual(DEFAULT_SHORTCUTS.length);
    });

    it('parse_自定义整表替换_按key名与keyCode', 0, () => {
      const json: string =
        '[{"action":"newTab","ctrl":true,"key":"n"},' +
        '{"action":"closePane","alt":true,"keyCode":' + letterKeyCode('X') + '}]';
      const bindings: ShortcutBinding[] = parseShortcutLayout(json);
      expect(bindings.length).assertEqual(2);
      expect(matchShortcut(bindings, letterKeyCode('N'), true, false, false, false)).assertEqual('newTab');
      expect(matchShortcut(bindings, letterKeyCode('T'), true, false, true, false)).assertNull();
      expect(matchShortcut(bindings, letterKeyCode('X'), false, true, false, false)).assertEqual('closePane');
    });

    it('parse_跳过非法条目_保留合法条目', 0, () => {
      const json: string =
        '[{"action":"ghost","ctrl":true,"key":"T"},' +
        '{"action":"nextTab","ctrl":true,"key":"Tab"},' +
        '{"ctrl":true,"key":"W"}]';
      const bindings: ShortcutBinding[] = parseShortcutLayout(json);
      expect(bindings.length).assertEqual(1);
      expect(matchShortcut(bindings, KEY_TAB, true, false, false, false)).assertEqual('nextTab');
    });

    it('keyCodeOfName_字母数字与功能名', 0, () => {
      expect(keyCodeOfName('t')).assertEqual(letterKeyCode('T'));
      expect(keyCodeOfName('T')).assertEqual(letterKeyCode('T'));
      expect(keyCodeOfName('Tab')).assertEqual(KEY_TAB);
      expect(keyCodeOfName('LEFT')).assertEqual(KEY_DPAD_LEFT);
      expect(keyCodeOfName('+')).assertEqual(KEY_EQUALS);
      expect(keyCodeOfName('Minus')).assertEqual(KEY_MINUS);
      expect(keyCodeOfName('')).assertEqual(-1);
      expect(keyCodeOfName('F13')).assertEqual(-1);
      expect(letterKeyCode('TT')).assertEqual(-1);
    });
  });
}
