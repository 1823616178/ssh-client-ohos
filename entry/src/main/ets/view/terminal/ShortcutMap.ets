/**
 * ShortcutMap —— 应用级快捷键表（DESIGN §4.3.2「键盘快捷键……全部可自定义」）。
 *
 * 职责边界：
 *   - 本文件只做「按键组合 → 动作」的纯匹配，零 UI、零会话副作用；
 *   - 命中后由 TerminalCanvas.handleKeyInput 消费（不再 mapKeyEvent 送给远端），
 *     复制/粘贴在画布内处理，标签/分屏/切焦点交给 TerminalViewModel.handleShortcut；
 *   - 默认组合对齐 Windows Terminal，刻意避开 Ctrl+C/Z/D/W 等终端常用键
 *     （复制是 Ctrl+Shift+C，关窗格是 Ctrl+Shift+W）。
 *
 * 自定义：C3 `keyboardShortcuts` JSON 数组，空串 = 本表默认。语义与
 * keyBarLayout 相同——整表替换，不是与默认合并。非法条目跳过；解析结果
 * 为空则回退默认，不让快捷键整表消失。
 *
 * JSON 条目：
 *   { "action": "newTab", "ctrl": true, "shift": true, "key": "T" }
 *   可选 "alt" / "meta"；也可用 "keyCode": 2036 直接写 HarmonyOS 键码。
 */

import { JSON } from '@kit.ArkTS';
import { Logger } from '../../common/utils/Logger';
import {
  KEY_0,
  KEY_A,
  KEY_DPAD_DOWN,
  KEY_DPAD_LEFT,
  KEY_DPAD_RIGHT,
  KEY_DPAD_UP,
  KEY_EQUALS,
  KEY_MINUS,
  KEY_PAGE_DOWN,
  KEY_PAGE_UP,
  KEY_TAB
} from './KeyMap';

const LOG_TAG: string = 'ShortcutMap';

/** 应用快捷动作（与 VM / 画布约定同一套名字，自定义 JSON 也用这些字面量） */
export type ShortcutAction =
  'newTab' | 'closePane' | 'closeTab' | 'nextTab' | 'prevTab' |
  'splitRow' | 'splitColumn' |
  'focusLeft' | 'focusRight' | 'focusUp' | 'focusDown' |
  'copy' | 'paste';

/** 一条绑定：修饰键全部显式给出，匹配时必须四者都对上（缺省 = 不按） */
export interface ShortcutBinding {
  readonly action: ShortcutAction;
  readonly ctrl: boolean;
  readonly alt: boolean;
  readonly shift: boolean;
  readonly meta: boolean;
  readonly keyCode: number;
}

const ALL_ACTIONS: ShortcutAction[] = [
  'newTab', 'closePane', 'closeTab', 'nextTab', 'prevTab',
  'splitRow', 'splitColumn',
  'focusLeft', 'focusRight', 'focusUp', 'focusDown',
  'copy', 'paste'
];

function bind(action: ShortcutAction, keyCode: number, ctrl: boolean, alt: boolean,
  shift: boolean, meta: boolean): ShortcutBinding {
  return {
    action: action,
    keyCode: keyCode,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    meta: meta
  };
}

/** 字母键码：KEYCODE_A=2017 … KEYCODE_Z=2042 */
export function letterKeyCode(letter: string): number {
  if (letter.length !== 1) {
    return -1;
  }
  const upper: string = letter.toUpperCase();
  const code: number = upper.charCodeAt(0);
  if (code < 65 || code > 90) {
    return -1;
  }
  return KEY_A + (code - 65);
}

/** 键名 → HarmonyOS 键码（大小写不敏感；单字母 / 单数字 / 功能名） */
export function keyCodeOfName(name: string): number {
  if (name.length === 0) {
    return -1;
  }
  const upper: string = name.toUpperCase();
  if (upper.length === 1) {
    const letter: number = letterKeyCode(upper);
    if (letter >= 0) {
      return letter;
    }
    const digit: number = upper.charCodeAt(0);
    if (digit >= 48 && digit <= 57) {
      return KEY_0 + (digit - 48);
    }
  }
  switch (upper) {
    case 'TAB':
      return KEY_TAB;
    case 'LEFT':
      return KEY_DPAD_LEFT;
    case 'RIGHT':
      return KEY_DPAD_RIGHT;
    case 'UP':
      return KEY_DPAD_UP;
    case 'DOWN':
      return KEY_DPAD_DOWN;
    case 'MINUS':
    case '-':
      return KEY_MINUS;
    case 'EQUALS':
    case 'PLUS':
    case '=':
    case '+':
      return KEY_EQUALS;
    case 'PAGEUP':
    case 'PGUP':
      return KEY_PAGE_UP;
    case 'PAGEDOWN':
    case 'PGDN':
      return KEY_PAGE_DOWN;
    default:
      return -1;
  }
}

function isShortcutAction(value: string): boolean {
  for (const action of ALL_ACTIONS) {
    if (action === value) {
      return true;
    }
  }
  return false;
}

/**
 * 内置默认表（Windows Terminal 同构，不抢终端常用键）：
 *   Ctrl+Shift+T 新标签 / Ctrl+Shift+W 关窗格 / Ctrl+Shift+Q 关标签
 *   Ctrl+Tab / Ctrl+Shift+Tab 切标签
 *   Alt+Shift+= 左右分屏 / Alt+Shift+- 上下分屏
 *   Alt+方向 切焦点窗格
 *   Ctrl+Shift+C 复制 / Ctrl+Shift+V 粘贴
 */
export const DEFAULT_SHORTCUTS: ShortcutBinding[] = [
  bind('newTab', letterKeyCode('T'), true, false, true, false),
  bind('closePane', letterKeyCode('W'), true, false, true, false),
  bind('closeTab', letterKeyCode('Q'), true, false, true, false),
  bind('nextTab', KEY_TAB, true, false, false, false),
  bind('prevTab', KEY_TAB, true, false, true, false),
  bind('splitRow', KEY_EQUALS, false, true, true, false),
  bind('splitColumn', KEY_MINUS, false, true, true, false),
  bind('focusLeft', KEY_DPAD_LEFT, false, true, false, false),
  bind('focusRight', KEY_DPAD_RIGHT, false, true, false, false),
  bind('focusUp', KEY_DPAD_UP, false, true, false, false),
  bind('focusDown', KEY_DPAD_DOWN, false, true, false, false),
  bind('copy', letterKeyCode('C'), true, false, true, false),
  bind('paste', letterKeyCode('V'), true, false, true, false)
];

/**
 * 匹配快捷键（先命中先赢）。修饰键必须四者精确相等——
 * Ctrl+C 不会命中 Ctrl+Shift+C，Ctrl+W 不会命中 Ctrl+Shift+W。
 */
export function matchShortcut(bindings: ShortcutBinding[], keyCode: number,
  ctrl: boolean, alt: boolean, shift: boolean, meta: boolean): ShortcutAction | null {
  for (const binding of bindings) {
    if (binding.keyCode === keyCode &&
      binding.ctrl === ctrl &&
      binding.alt === alt &&
      binding.shift === shift &&
      binding.meta === meta) {
      return binding.action;
    }
  }
  return null;
}

/** 空串 / 非法 / 无有效条目 → 默认表；有效条目整表替换默认 */
export function parseShortcutLayout(json: string): ShortcutBinding[] {
  if (json.trim().length === 0) {
    return DEFAULT_SHORTCUTS;
  }
  let parsed: Object | null;
  try {
    parsed = JSON.parse(json) as Object;
  } catch (err) {
    Logger.warn(`快捷键表 JSON 非法，回退默认：${JSON.stringify(err)}`, LOG_TAG);
    return DEFAULT_SHORTCUTS;
  }
  if (parsed === null || !Array.isArray(parsed)) {
    Logger.warn('快捷键表不是数组，回退默认', LOG_TAG);
    return DEFAULT_SHORTCUTS;
  }
  const result: ShortcutBinding[] = [];
  const items: Object[] = parsed as Object[];
  for (const item of items) {
    const binding: ShortcutBinding | null = parseShortcutEntry(item);
    if (binding !== null) {
      result.push(binding);
    }
  }
  if (result.length === 0) {
    Logger.warn('快捷键表无有效条目，回退默认', LOG_TAG);
    return DEFAULT_SHORTCUTS;
  }
  return result;
}

function parseShortcutEntry(item: Object): ShortcutBinding | null {
  const entry: Record<string, Object> = item as Record<string, Object>;
  const actionRaw: Object | undefined = entry['action'];
  if (typeof actionRaw !== 'string' || !isShortcutAction(actionRaw)) {
    return null;
  }
  const keyCodeRaw: Object | undefined = entry['keyCode'];
  let keyCode: number = -1;
  if (typeof keyCodeRaw === 'number' && keyCodeRaw > 0) {
    keyCode = keyCodeRaw as number;
  } else {
    const keyRaw: Object | undefined = entry['key'];
    if (typeof keyRaw === 'string') {
      keyCode = keyCodeOfName(keyRaw);
    }
  }
  if (keyCode < 0) {
    return null;
  }
  return bind(
    actionRaw as ShortcutAction,
    keyCode,
    readFlag(entry, 'ctrl'),
    readFlag(entry, 'alt'),
    readFlag(entry, 'shift'),
    readFlag(entry, 'meta')
  );
}

function readFlag(entry: Record<string, Object>, name: string): boolean {
  const value: Object | undefined = entry[name];
  return value === true;
}
