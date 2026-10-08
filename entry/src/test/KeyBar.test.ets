/**
 * KeyBar 功能键条纯逻辑测试（hypium，任务 T7）。
 *
 * 覆盖：
 *  - parseKeyBarLayout：默认布局、合法自定义布局（键序/label 覆盖/char 键）、
 *    非法 JSON / 非数组 / 空数组回退默认、未知键名与非单字符 char 容错跳过；
 *  - keyBarBytesForKey：Esc/Tab/方向键（含应用光标模式与 Ctrl 修饰参数）、
 *    char 键（Ctrl→控制字符、Alt→ESC 前缀）、修饰键自身不出字节；
 *  - 验收路径字节级断言：Ctrl+C=0x03、Ctrl+Z=0x1A（自定义字母键/IME 出口
 *    共用 mapPrintableChar 的同一映射）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  DEFAULT_KEY_BAR_LAYOUT,
  KEY_BAR_MAX_KEYS,
  KeyBarKeySpec,
  addableKnownKeys,
  addableSuggestedChars,
  appendKeyBarKey,
  isRepeatableKey,
  keyBarBytesForKey,
  keyBarLayoutToStore,
  keyFaceOverlayForBackground,
  knownKeySpec,
  makeKeyBarCharKey,
  moveKeyBarKey,
  parseKeyBarLayout,
  removeKeyBarKey,
  serializeKeyBarLayout
} from '../main/ets/view/KeyBarLayout';
import { KEY_DPAD_UP, KEY_ESCAPE, KEY_TAB } from '../main/ets/view/terminal/KeyMap';

/** 字节序列断言（null 视为失败） */
function assertBytes(actual: Uint8Array | null, expected: number[], msg: string): void {
  expect(actual !== null).assertTrue();
  if (actual === null) {
    return;
  }
  expect(actual.length).assertEqual(expected.length);
  for (let i = 0; i < expected.length; i++) {
    expect(actual[i]).assertEqual(expected[i]);
  }
}

function specOf(specs: KeyBarKeySpec[], id: string): KeyBarKeySpec {
  for (const s of specs) {
    if (s.id === id) {
      return s;
    }
  }
  throw new Error(`测试构造失败：布局中无键位 ${id}`);
}

export default function keyBarTest() {
  describe('KeyBarTest', () => {

    it('空串回退默认布局', 0, () => {
      const keys = parseKeyBarLayout('');
      expect(keys.length).assertEqual(DEFAULT_KEY_BAR_LAYOUT.length);
      expect(keys[0].id).assertEqual('esc');
      // 默认布局含 DESIGN §4.4 版面的全部键，外加剪贴板动作键 复制/粘贴
      const ids = keys.map((k: KeyBarKeySpec) => k.id);
      expect(ids.join(',')).assertEqual(
        'esc,tab,ctrl,alt,up,down,left,right,enter,backspace,char:-,char:|,char:~,char:/,copy,paste');
    });

    it('非法JSON回退默认布局', 0, () => {
      expect(parseKeyBarLayout('not-json').length).assertEqual(DEFAULT_KEY_BAR_LAYOUT.length);
      expect(parseKeyBarLayout('{"a":1}').length).assertEqual(DEFAULT_KEY_BAR_LAYOUT.length);
      expect(parseKeyBarLayout('[]').length).assertEqual(DEFAULT_KEY_BAR_LAYOUT.length);
    });

    it('合法自定义布局按序解析', 0, () => {
      const json = '[{"key":"ctrl"},{"key":"char","char":"c"},{"key":"char","char":"z"},' +
        '{"key":"esc","label":"退出"},{"key":"home"}]';
      const keys = parseKeyBarLayout(json);
      expect(keys.length).assertEqual(5);
      expect(keys[0].kind).assertEqual('ctrl');
      expect(keys[1].id).assertEqual('char:c');
      expect(keys[2].id).assertEqual('char:z');
      expect(keys[3].label).assertEqual('退出'); // label 覆盖
      expect(keys[3].keyCode).assertEqual(KEY_ESCAPE);
      expect(keys[4].id).assertEqual('home');
    });

    it('未知键名与非法条目跳过', 0, () => {
      const json = '[{"key":"esc"},{"key":"no-such-key"},{"key":"char","char":"ab"},' +
        '{"foo":1},{"key":"tab"}]';
      const keys = parseKeyBarLayout(json);
      expect(keys.length).assertEqual(2);
      expect(keys[0].id).assertEqual('esc');
      expect(keys[1].id).assertEqual('tab');
    });

    it('Esc与Tab字节', 0, () => {
      const keys = DEFAULT_KEY_BAR_LAYOUT;
      assertBytes(keyBarBytesForKey(specOf(keys, 'esc'), false, false, false), [0x1B], 'esc');
      assertBytes(keyBarBytesForKey(specOf(keys, 'tab'), false, false, false), [0x09], 'tab');
    });

    it('方向键普通与应用光标模式', 0, () => {
      const up = specOf(DEFAULT_KEY_BAR_LAYOUT, 'up');
      expect(up.keyCode).assertEqual(KEY_DPAD_UP);
      assertBytes(keyBarBytesForKey(up, false, false, false), [0x1B, 0x5B, 0x41], 'CSI A');
      assertBytes(keyBarBytesForKey(up, false, false, true), [0x1B, 0x4F, 0x41], 'SS3 A');
    });

    it('方向键带粘滞Ctrl修饰参数', 0, () => {
      const up = specOf(DEFAULT_KEY_BAR_LAYOUT, 'up');
      // Ctrl+↑ = CSI 1;5A（modifierParam=5）
      assertBytes(keyBarBytesForKey(up, true, false, false),
        [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41], 'CSI 1;5A');
    });

    it('char键直发与粘滞修饰组合', 0, () => {
      const minus = specOf(DEFAULT_KEY_BAR_LAYOUT, 'char:-');
      assertBytes(keyBarBytesForKey(minus, false, false, false), [0x2D], '-');
      // Ctrl+'-' = 0x1F（经典等价映射）；Alt+'-' = ESC '-'
      assertBytes(keyBarBytesForKey(minus, true, false, false), [0x1F], 'Ctrl+-');
      assertBytes(keyBarBytesForKey(minus, false, true, false), [0x1B, 0x2D], 'Alt+-');
    });

    it('修饰键自身不出字节', 0, () => {
      const keys = DEFAULT_KEY_BAR_LAYOUT;
      expect(keyBarBytesForKey(specOf(keys, 'ctrl'), false, false, false)).assertNull();
      expect(keyBarBytesForKey(specOf(keys, 'alt'), true, true, false)).assertNull();
    });

    it('验收路径Ctrl+C与Ctrl+Z字节正确', 0, () => {
      // 自定义字母键（或 IME 出口同款映射）：粘滞 Ctrl 生效时单字符走控制字符
      const keys = parseKeyBarLayout('[{"key":"char","char":"c"},{"key":"char","char":"z"}]');
      assertBytes(keyBarBytesForKey(keys[0], true, false, false), [0x03], 'Ctrl+C');
      assertBytes(keyBarBytesForKey(keys[1], true, false, false), [0x1A], 'Ctrl+Z');
    });

    it('Tab补全路径不受粘滞影响以外的键直达', 0, () => {
      const tab = specOf(DEFAULT_KEY_BAR_LAYOUT, 'tab');
      expect(tab.keyCode).assertEqual(KEY_TAB);
      assertBytes(keyBarBytesForKey(tab, false, false, false), [0x09], 'Tab 补全');
    });

    it('键面颜色按终端背景明暗自动适配', 0, () => {
      expect(keyFaceOverlayForBackground('#0E131D')).assertEqual('#26FFFFFF');
      expect(keyFaceOverlayForBackground('#F5F7FA')).assertEqual('#1F000000');
      expect(keyFaceOverlayForBackground('invalid')).assertEqual('#26FFFFFF');
    });
    it('键位编辑器_候选去重_增删上限下限_默认存空串_⌨键', 0, () => {
      const base: KeyBarKeySpec[] = DEFAULT_KEY_BAR_LAYOUT.slice();
      const known: KeyBarKeySpec[] = addableKnownKeys(base);
      // 默认布局已有 esc/tab/ctrl/alt/方向/回车/退格/复制/粘贴：候选只剩 home/end/pgup/pgdn/keyboard
      const ids: string[] = known.map((k: KeyBarKeySpec) => k.id);
      expect(ids.join(',')).assertEqual('home,end,pgup,pgdn,keyboard');
      expect(addableSuggestedChars(base).indexOf('-')).assertEqual(-1);
      expect(addableSuggestedChars(base).indexOf('_') >= 0).assertTrue();
      expect(keyBarLayoutToStore(base)).assertEqual('');
      const kb: KeyBarKeySpec | null = knownKeySpec('keyboard');
      expect(kb !== null && kb.kind === 'keyboard').assertTrue();
      expect(isRepeatableKey(kb as KeyBarKeySpec)).assertFalse();
      const added: KeyBarKeySpec[] = appendKeyBarKey(base, kb as KeyBarKeySpec);
      expect(added.length).assertEqual(base.length + 1);
      expect(appendKeyBarKey(added, kb as KeyBarKeySpec).length).assertEqual(added.length);
      const stored: string = keyBarLayoutToStore(added);
      expect(stored).assertEqual(serializeKeyBarLayout(added));
      expect(stored.indexOf('"keyboard"') >= 0).assertTrue();
      const moved: KeyBarKeySpec[] = moveKeyBarKey(added, added.length - 1, 0);
      expect(moved[0].id).assertEqual('keyboard');
      let one: KeyBarKeySpec[] = [base[0]];
      one = removeKeyBarKey(one, 0);
      expect(one.length).assertEqual(1);
      expect(removeKeyBarKey(base, 99).length).assertEqual(base.length);
      expect(removeKeyBarKey(base, 0)[0].id).assertEqual('tab');
      let many: KeyBarKeySpec[] = [];
      const chars: string = 'abcdefghijklmnopqrstuvwxyz0123456789';
      for (let i = 0; i < chars.length; i++) {
        many = appendKeyBarKey(many, makeKeyBarCharKey(chars.charAt(i)) as KeyBarKeySpec);
      }
      expect(many.length).assertEqual(KEY_BAR_MAX_KEYS);
    });
  });
}
