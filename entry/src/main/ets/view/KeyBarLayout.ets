/**
 * KeyBarLayout —— 功能键条的纯逻辑（从 KeyBar.ets 拆出，Node/hypium 单测不依赖组件）：
 * 键位模型、默认布局、自定义布局 JSON 解析/序列化（键位编辑器）、键位 → VT 字节、
 * 自动连发判定、键面配色。KeyBar.ets re-export 全部符号，旧 import 路径不变。
 */

import { JSON } from '@kit.ArkTS';
import {
  KEY_BACKSPACE,
  KEY_DPAD_DOWN,
  KEY_DPAD_LEFT,
  KEY_DPAD_RIGHT,
  KEY_DPAD_UP,
  KEY_ENTER,
  KEY_ESCAPE,
  KEY_MOVE_END,
  KEY_MOVE_HOME,
  KEY_PAGE_DOWN,
  KEY_PAGE_UP,
  KEY_TAB,
  mapKeyEvent,
  mapPrintableChar
} from './terminal/KeyMap';
import { Logger } from '../common/utils/Logger';

// ---------------------------------------------------------------- 键位模型与默认布局

/**
 * 键位类别：char=直接字符 / keyCode=经 KeyMap 映射的功能键 / ctrl/alt=粘滞修饰 /
 * copy|paste=剪贴板动作（不产出字节，经 onAction 交给宿主的终端画布执行）
 */
export type KeyBarKeyKind = 'char' | 'keyCode' | 'ctrl' | 'alt' | 'copy' | 'paste' | 'keyboard';

/** 一个键位（自定义布局 JSON 反序列化结果；字段补全为完整形态便于渲染） */
export interface KeyBarKeySpec {
  /** 稳定 id（ForEach 键生成器与测试断言用；自定义布局里同名校验不强制） */
  readonly id: string;
  /** 键面文字 */
  readonly label: string;
  readonly kind: KeyBarKeyKind;
  /** kind=char 时的发送字符（必须是单字符） */
  readonly char: string;
  /** kind=keyCode 时的 HarmonyOS 键码（@ohos.multimodalInput.keyCode 数值） */
  readonly keyCode: number;
}

function makeKeyCodeKey(id: string, label: string, keyCode: number): KeyBarKeySpec {
  return { id: id, label: label, kind: 'keyCode', char: '', keyCode: keyCode };
}

function makeCharKey(ch: string, label?: string): KeyBarKeySpec {
  return { id: `char:${ch}`, label: label ?? ch, kind: 'char', char: ch, keyCode: 0 };
}

/** 内置默认布局（DESIGN §4.4 版面图；C3 keyBarLayout 空串时使用） */
export const DEFAULT_KEY_BAR_LAYOUT: KeyBarKeySpec[] = [
  makeKeyCodeKey('esc', 'Esc', KEY_ESCAPE),
  makeKeyCodeKey('tab', 'Tab', KEY_TAB),
  { id: 'ctrl', label: 'Ctrl', kind: 'ctrl', char: '', keyCode: 0 },
  { id: 'alt', label: 'Alt', kind: 'alt', char: '', keyCode: 0 },
  makeKeyCodeKey('up', '↑', KEY_DPAD_UP),
  makeKeyCodeKey('down', '↓', KEY_DPAD_DOWN),
  makeKeyCodeKey('left', '←', KEY_DPAD_LEFT),
  makeKeyCodeKey('right', '→', KEY_DPAD_RIGHT),
  // 回车/退格：部分输入法（及外接键盘收起软键盘时）没有可靠的回车/空行退格，
  // 键条常驻一份兜底；长按自动连发
  makeKeyCodeKey('enter', '⏎', KEY_ENTER),
  makeKeyCodeKey('backspace', '⌫', KEY_BACKSPACE),
  makeCharKey('-'),
  makeCharKey('|'),
  makeCharKey('~'),
  makeCharKey('/'),
  { id: 'copy', label: '复制', kind: 'copy', char: '', keyCode: 0 },
  { id: 'paste', label: '粘贴', kind: 'paste', char: '', keyCode: 0 }
];

/** 自定义布局里可按名引用的已知功能键（key 字段 → 规格；char 键走另一条路径） */
export function knownKeySpec(name: string): KeyBarKeySpec | null {
  switch (name) {
    case 'esc':
      return makeKeyCodeKey('esc', 'Esc', KEY_ESCAPE);
    case 'tab':
      return makeKeyCodeKey('tab', 'Tab', KEY_TAB);
    case 'ctrl':
      return { id: 'ctrl', label: 'Ctrl', kind: 'ctrl', char: '', keyCode: 0 };
    case 'alt':
      return { id: 'alt', label: 'Alt', kind: 'alt', char: '', keyCode: 0 };
    case 'up':
      return makeKeyCodeKey('up', '↑', KEY_DPAD_UP);
    case 'down':
      return makeKeyCodeKey('down', '↓', KEY_DPAD_DOWN);
    case 'left':
      return makeKeyCodeKey('left', '←', KEY_DPAD_LEFT);
    case 'right':
      return makeKeyCodeKey('right', '→', KEY_DPAD_RIGHT);
    case 'home':
      return makeKeyCodeKey('home', 'Home', KEY_MOVE_HOME);
    case 'end':
      return makeKeyCodeKey('end', 'End', KEY_MOVE_END);
    case 'pgup':
      return makeKeyCodeKey('pgup', 'PgUp', KEY_PAGE_UP);
    case 'pgdn':
      return makeKeyCodeKey('pgdn', 'PgDn', KEY_PAGE_DOWN);
    case 'enter':
      return makeKeyCodeKey('enter', '⏎', KEY_ENTER);
    case 'backspace':
      return makeKeyCodeKey('backspace', '⌫', KEY_BACKSPACE);
    case 'copy':
      return { id: 'copy', label: '复制', kind: 'copy', char: '', keyCode: 0 };
    case 'paste':
      return { id: 'paste', label: '粘贴', kind: 'paste', char: '', keyCode: 0 };
    case 'keyboard':
      return { id: 'keyboard', label: '⌨', kind: 'keyboard', char: '', keyCode: 0 };
    default:
      return null;
  }
}

/**
 * 解析 C3 keyBarLayout 自定义布局 JSON：
 *   [{"key":"esc"},{"key":"ctrl"},{"key":"char","char":";","label":":"}, ...]
 *   - key 为已知功能键名（esc/tab/ctrl/alt/方向/home/end/pgup/pgdn/enter/backspace），
 *     可选 "label" 覆盖键面文字；
 *   - {"key":"char","char":"X"} 定义任意单字符键；
 *   - 容错：非法 JSON / 非数组 / 未知键名 / 非单字符 char 一律跳过或回退默认布局，
 *     绝不因配置损坏让键条消失（空串与解析结果为空均回退 DEFAULT_KEY_BAR_LAYOUT）。
 */
export function parseKeyBarLayout(json: string): KeyBarKeySpec[] {
  if (json.trim().length === 0) {
    return DEFAULT_KEY_BAR_LAYOUT;
  }
  let parsed: Object | null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    Logger.warn(`功能键条布局 JSON 非法，回退默认布局：${JSON.stringify(err)}`, 'KeyBar');
    return DEFAULT_KEY_BAR_LAYOUT;
  }
  if (parsed === null || !Array.isArray(parsed)) {
    Logger.warn('功能键条布局不是数组，回退默认布局', 'KeyBar');
    return DEFAULT_KEY_BAR_LAYOUT;
  }
  const result: KeyBarKeySpec[] = [];
  for (const item of parsed as Object[]) {
    const spec = parseKeyBarEntry(item);
    if (spec !== null) {
      result.push(spec);
    }
  }
  if (result.length === 0) {
    Logger.warn('功能键条布局无有效键位，回退默认布局', 'KeyBar');
    return DEFAULT_KEY_BAR_LAYOUT;
  }
  return result;
}

/** 单条自定义键位解析；非法条目返回 null（跳过，容错） */
function parseKeyBarEntry(item: Object): KeyBarKeySpec | null {
  const entry = item as Record<string, Object>;
  const key = entry['key'];
  if (typeof key !== 'string') {
    return null;
  }
  const labelOverride = entry['label'];
  const label = typeof labelOverride === 'string' && labelOverride.length > 0 ? labelOverride : '';
  if (key === 'char') {
    const ch = entry['char'];
    // 单字符判定按码点计（避免把代理对当成两个字符）
    if (typeof ch !== 'string' || Array.from(ch).length !== 1) {
      return null;
    }
    return makeCharKey(ch, label.length > 0 ? label : undefined);
  }
  const known = knownKeySpec(key);
  if (known === null) {
    return null; // 未知键名：跳过
  }
  if (label.length === 0) {
    return known;
  }
  return { id: known.id, label: label, kind: known.kind, char: known.char, keyCode: known.keyCode };
}

/**
 * 键位 → VT 字节序列（点击非修饰键时调用；粘滞 Ctrl/Alt 快照在此并入）：
 *   char 键 → mapPrintableChar（Ctrl→控制字符、Alt→ESC 前缀，未定义组合 null 不发送）；
 *   keyCode 键 → mapKeyEvent（方向键序列、Tab、Esc 等，修饰参数由 KeyMap 结算）；
 *   ctrl/alt 修饰键返回 null（不产生字节，只驱动 StickyModifiers 状态机）。
 */
export function keyBarBytesForKey(spec: KeyBarKeySpec, ctrl: boolean, alt: boolean,
  applicationCursorKeys: boolean): Uint8Array | null {
  if (spec.kind === 'char') {
    return mapPrintableChar(spec.char, alt, ctrl);
  }
  if (spec.kind === 'keyCode') {
    return mapKeyEvent(spec.keyCode, false, alt, ctrl, false, applicationCursorKeys);
  }
  return null;
}

/** 键面底色：叠在终端背景上的低透明度白，深/浅终端外观下都能与底色拉开层次 */
const KEY_FACE_DARK_OVERLAY = '#26FFFFFF';
const KEY_FACE_LIGHT_OVERLAY = '#1F000000';

function terminalBackgroundIsDark(color: string): boolean {
  if (!/^#[0-9a-fA-F]{6}$/.test(color)) {
    return true;
  }
  const red: number = parseInt(color.substring(1, 3), 16);
  const green: number = parseInt(color.substring(3, 5), 16);
  const blue: number = parseInt(color.substring(5, 7), 16);
  return red * 299 + green * 587 + blue * 114 < 128000;
}

/** 终端背景明暗 → 键面叠加色；导出供纯逻辑测试覆盖浅色主题适配。 */
export function keyFaceOverlayForBackground(color: string): string {
  return terminalBackgroundIsDark(color) ? KEY_FACE_DARK_OVERLAY : KEY_FACE_LIGHT_OVERLAY;
}


/** 键位编辑器可选的内置键名（顺序即编辑器「添加按键」列表顺序） */
export const KEY_BAR_KNOWN_KEY_NAMES: string[] = [
  'esc', 'tab', 'ctrl', 'alt', 'up', 'down', 'left', 'right', 'enter', 'backspace',
  'home', 'end', 'pgup', 'pgdn', 'copy', 'paste', 'keyboard'
];

/** 编辑器「添加字符键」的常用候选 */
export const KEY_BAR_SUGGESTED_CHARS: string[] = [
  '-', '/', '|', '~', '_', ':', ';', '=', '*', '&', '$', '#', '!', '?', '\\', '`', "'", '"',
  '<', '>', '[', ']', '{', '}', '(', ')', '@', '%', '^', '+', '.', ','
];

/** 键位 → 布局 JSON 条目名（char 键为 'char'） */
export function keyBarEntryName(spec: KeyBarKeySpec): string {
  return spec.kind === 'char' ? 'char' : spec.id;
}

/** 默认键面文字（判断 label 是否被用户覆盖用） */
function defaultLabelOf(spec: KeyBarKeySpec): string {
  if (spec.kind === 'char') {
    return spec.char;
  }
  const known: KeyBarKeySpec | null = knownKeySpec(spec.id);
  return known === null ? spec.label : known.label;
}

/** 序列化布局（键位编辑器保存 → SettingsRepository.setKeyBarLayout）；与 parseKeyBarLayout 互逆 */
export function serializeKeyBarLayout(specs: KeyBarKeySpec[]): string {
  const entries: Record<string, string>[] = [];
  for (const spec of specs) {
    const entry: Record<string, string> = {};
    entry['key'] = keyBarEntryName(spec);
    if (spec.kind === 'char') {
      entry['char'] = spec.char;
    }
    if (spec.label !== defaultLabelOf(spec)) {
      entry['label'] = spec.label;
    }
    entries.push(entry);
  }
  return JSON.stringify(entries);
}

/** 布局是否等同内置默认（编辑器保存时等同默认则写空串，日后默认布局升级能自动跟上） */
export function isDefaultKeyBarLayout(specs: KeyBarKeySpec[]): boolean {
  if (specs.length !== DEFAULT_KEY_BAR_LAYOUT.length) {
    return false;
  }
  for (let i = 0; i < specs.length; i++) {
    const a: KeyBarKeySpec = specs[i];
    const b: KeyBarKeySpec = DEFAULT_KEY_BAR_LAYOUT[i];
    if (a.id !== b.id || a.label !== b.label || a.kind !== b.kind || a.char !== b.char) {
      return false;
    }
  }
  return true;
}

/** 构造一个字符键（编辑器用）；非单字符返回 null */
export function makeKeyBarCharKey(ch: string, label: string = ''): KeyBarKeySpec | null {
  if (Array.from(ch).length !== 1) {
    return null;
  }
  return makeCharKey(ch, label.length > 0 ? label : undefined);
}

/** 列表内移动（编辑器上移/下移）；越界返回原数组副本 */
export function moveKeyBarKey(specs: KeyBarKeySpec[], from: number, to: number): KeyBarKeySpec[] {
  const out: KeyBarKeySpec[] = specs.slice();
  if (from < 0 || from >= out.length || to < 0 || to >= out.length || from === to) {
    return out;
  }
  const item: KeyBarKeySpec = out.splice(from, 1)[0];
  out.splice(to, 0, item);
  return out;
}

/** 已存在同 id 的键（编辑器去重：同一功能键只放一次，字符键按字符去重） */
export function keyBarContains(specs: KeyBarKeySpec[], id: string): boolean {
  for (const s of specs) {
    if (s.id === id) {
      return true;
    }
  }
  return false;
}

/** 长按自动连发的键：方向键、退格、翻页、Delete 类（修饰/剪贴板/回车/Esc/Tab 不连发） */
export function isRepeatableKey(spec: KeyBarKeySpec): boolean {
  if (spec.kind !== 'keyCode') {
    return false;
  }
  return spec.id === 'up' || spec.id === 'down' || spec.id === 'left' || spec.id === 'right' ||
    spec.id === 'backspace' || spec.id === 'pgup' || spec.id === 'pgdn';
}

/** 自动连发：按住 REPEAT_DELAY_MS 后开始，每 REPEAT_INTERVAL_MS 一次 */
export const KEY_REPEAT_DELAY_MS: number = 400;
export const KEY_REPEAT_INTERVAL_MS: number = 60;

/** 键条最少保留的键数（全删光键条就成了空白条，编辑器禁止） */
export const KEY_BAR_MIN_KEYS: number = 1;
/** 键条最多键数（再多横滑找键反而慢） */
export const KEY_BAR_MAX_KEYS: number = 32;

/** 编辑器「添加内置键」候选：尚未放进布局的内置键 */
export function addableKnownKeys(specs: KeyBarKeySpec[]): KeyBarKeySpec[] {
  const out: KeyBarKeySpec[] = [];
  for (const name of KEY_BAR_KNOWN_KEY_NAMES) {
    const spec: KeyBarKeySpec | null = knownKeySpec(name);
    if (spec !== null && !keyBarContains(specs, spec.id)) {
      out.push(spec);
    }
  }
  return out;
}

/** 编辑器「添加字符键」候选：尚未放进布局的常用字符 */
export function addableSuggestedChars(specs: KeyBarKeySpec[]): string[] {
  const out: string[] = [];
  for (const ch of KEY_BAR_SUGGESTED_CHARS) {
    if (!keyBarContains(specs, `char:${ch}`)) {
      out.push(ch);
    }
  }
  return out;
}

/** 追加一个键（去重、上限）；不可加时返回原数组副本 */
export function appendKeyBarKey(specs: KeyBarKeySpec[], spec: KeyBarKeySpec): KeyBarKeySpec[] {
  const out: KeyBarKeySpec[] = specs.slice();
  if (out.length >= KEY_BAR_MAX_KEYS || keyBarContains(out, spec.id)) {
    return out;
  }
  out.push(spec);
  return out;
}

/** 删除一个键（保底 KEY_BAR_MIN_KEYS）；越界返回原数组副本 */
export function removeKeyBarKey(specs: KeyBarKeySpec[], index: number): KeyBarKeySpec[] {
  const out: KeyBarKeySpec[] = specs.slice();
  if (index < 0 || index >= out.length || out.length <= KEY_BAR_MIN_KEYS) {
    return out;
  }
  out.splice(index, 1);
  return out;
}

/** 编辑器保存：等同内置默认写空串（日后默认布局升级能自动跟上），否则写 JSON */
export function keyBarLayoutToStore(specs: KeyBarKeySpec[]): string {
  return isDefaultKeyBarLayout(specs) ? '' : serializeKeyBarLayout(specs);
}
