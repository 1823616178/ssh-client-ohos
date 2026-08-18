/**
 * KeyMap —— 按键 → VT 序列映射（任务 T6 可测纯逻辑核心，DESIGN §4.3.2 / §4.4）。
 *
 * 键码来源：HarmonyOS `@ohos.multimodalInput.keyCode` 的 KeyCode 枚举
 * （SDK 声明文件 ets/api/@ohos.multimodalInput.keyCode.d.ts，@since 9；
 * 常用键值与 Android 一致：KEYCODE_A=2017、KEYCODE_DPAD_UP=2012 等，
 * 本文件只映射已在该头文件中逐一核对过数值的键，未核实的键一律不映射）。
 *
 * 序列来源：xterm 惯例（ctlseqs「PC-Style Function Keys」与修正参数表）：
 *   - 方向键：普通模式 CSI A/B/C/D，应用光标模式（DECCKM）SS3 A/B/C/D；
 *   - 修正参数 param = 1 + Shift(1) + Alt(2) + Ctrl(4)，组合相加
 *     （Shift→2、Alt→3、Ctrl→5、Shift+Ctrl→6 …），见 modifierParam()；
 *   - 带修饰的方向键/Home/End/F1–F4 用 CSI 1;param<final> 形式；
 *   - Insert/Delete/PgUp/PgDn/F5–F12 用 CSI n[~;param] 形式；
 *   - Home/End 取 xterm 变体 CSI H / CSI F（而非 CSI 1~/4~）；
 *   - Ctrl+字母 → 控制字符（Ctrl+C=0x03 … Ctrl+Z=0x1A），Ctrl+[/\\///]/空格等
 *     经典等价映射一并覆盖；Alt+x → ESC 前缀；Shift+Tab → CSI Z。
 *
 * 已知取舍（真机待验项见各函数注释）：
 *   - 可打印字符按 US 布局换算 Shift 变形（!@#$…）；非 US 布局的物理键盘
 *     应改用 KeyEvent.keyText，属 T10 扩展点（TerminalCanvas 头注有登记）；
 *   - Meta（Win/⌘）暂按 Alt 处理（xterm 修正参数中 Meta 占 8 位，
 *     T10 完整快捷键表落地时再细分）；
 *   - 小键盘（NUMPAD_*，键码 2103+）与 Ctrl+Enter/Backspace 的区分
 *     留给 T10，本版本不映射。
 */
import { util } from '@kit.ArkTS';

// ---------------------------------------------------------------- HarmonyOS 键码常量
//（数值逐一核对自 SDK @ohos.multimodalInput.keyCode.d.ts；命名沿用枚举名去 KEYCODE_ 前缀）

export const KEY_DPAD_UP = 2012;
export const KEY_DPAD_DOWN = 2013;
export const KEY_DPAD_LEFT = 2014;
export const KEY_DPAD_RIGHT = 2015;
/** 字母区连续区间 [2017, 2042]：KEYCODE_A=2017 … KEYCODE_Z=2042 */
export const KEY_A = 2017;
export const KEY_Z = 2042;
/** 数字区连续区间 [2000, 2009]：KEYCODE_0=2000 … KEYCODE_9=2009 */
export const KEY_0 = 2000;
export const KEY_9 = 2009;
export const KEY_COMMA = 2043;
export const KEY_PERIOD = 2044;
export const KEY_TAB = 2049;
export const KEY_SPACE = 2050;
export const KEY_ENTER = 2054;
/** 退格键（PC Backspace；HarmonyOS 命名 DEL 是「向前删」的反义遗留，同 Android） */
export const KEY_BACKSPACE = 2055;
export const KEY_GRAVE = 2056;
export const KEY_MINUS = 2057;
export const KEY_EQUALS = 2058;
export const KEY_LEFT_BRACKET = 2059;
export const KEY_RIGHT_BRACKET = 2060;
export const KEY_BACKSLASH = 2061;
export const KEY_SEMICOLON = 2062;
export const KEY_APOSTROPHE = 2063;
export const KEY_SLASH = 2064;
export const KEY_PAGE_UP = 2068;
export const KEY_PAGE_DOWN = 2069;
export const KEY_ESCAPE = 2070;
/** PC Delete（向前删除） */
export const KEY_FORWARD_DEL = 2071;
/** 键盘 Home/End（同 Android KEYCODE_MOVE_HOME/MOVE_END） */
export const KEY_MOVE_HOME = 2081;
export const KEY_MOVE_END = 2082;
export const KEY_INSERT = 2083;
/** 功能键连续区间 [2090, 2101]：KEYCODE_F1=2090 … KEYCODE_F12=2101 */
export const KEY_F1 = 2090;
export const KEY_F12 = 2101;

// 修饰键与锁键自身（按下不产生字节序列，由修饰状态参与组合）
const MODIFIER_KEY_CODES: number[] = [
  2045, 2046, // ALT_LEFT / ALT_RIGHT
  2047, 2048, // SHIFT_LEFT / SHIFT_RIGHT
  2072, 2073, // CTRL_LEFT / CTRL_RIGHT
  2076, 2077, // META_LEFT / META_RIGHT
  2074, 2075, // CAPS_LOCK / SCROLL_LOCK
  2102 // NUM_LOCK
];

const ESC = 0x1B;
const DEL = 0x7F;

// ---------------------------------------------------------------- 基础工具

/**
 * xterm 修正参数：1 + Shift(1) + Alt(2) + Ctrl(4)，组合相加。
 * 无修饰返回 1（xterm 此时不携带参数）；Shift→2、Alt→3、Ctrl→5、
 * Shift+Ctrl→6、Alt+Ctrl→7、Shift+Alt+Ctrl→8。
 */
export function modifierParam(shift: boolean, alt: boolean, ctrl: boolean): number {
  let p = 1;
  if (shift) {
    p += 1;
  }
  if (alt) {
    p += 2;
  }
  if (ctrl) {
    p += 4;
  }
  return p;
}

/** ASCII 字符串 → 字节序列（仅用于映射表内的纯 ASCII 序列，字符必须 < 0x80） */
function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) {
    out[i] = s.charCodeAt(i) & 0x7F;
  }
  return out;
}

/**
 * 任意字符串 → UTF-8 字节（IME 提交的中文等非 ASCII 文本走这里）。
 *
 * 自己实现而不用 util.TextEncoder：真机上 `TextEncoder.create('utf-8').encodeInto(s)`
 * 返回空数组（单测「中文整字提交」即在设备上复现），而 IME 的普通字符提交也走本函数，
 * 于是软键盘敲什么都发不出去。手写编码没有运行时依赖，行为可在单测里完全确定。
 * 按码点遍历，正确处理 BMP 外的代理对（emoji 等 4 字节序列）。
 */
export function utf8Bytes(s: string): Uint8Array {
  const out: number[] = [];
  for (const ch of s) {
    const cp: number = ch.codePointAt(0) ?? 0;
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    } else {
      out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
        0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    }
  }
  return new Uint8Array(out);
}

/** ESC 前缀（Alt/Meta 组合：\x1b + 后续字节） */
function withEscPrefix(rest: Uint8Array): Uint8Array {
  const out = new Uint8Array(rest.length + 1);
  out[0] = ESC;
  out.set(rest, 1);
  return out;
}

/**
 * Ctrl 经典控制字符（xterm/VT 惯例，大小写不敏感）：
 *   a-z → 0x01–0x1A；'2'→0x00；'3'..'7' → 0x1B–0x1F；'8'→0x7F；
 *   '['→ESC、'\\'→0x1C、']'→0x1D、'/'→0x1F、'-'→0x1F、' '→0x00。
 * 未定义的字符返回 -1（调用方按「不映射」处理，绝不乱发字节）。
 */
export function ctrlCharForAscii(ch: string): number {
  if (ch.length !== 1) {
    return -1;
  }
  const c = ch.charCodeAt(0);
  if (c >= 0x61 && c <= 0x7A) { // a-z
    return c - 0x60;
  }
  if (c >= 0x41 && c <= 0x5A) { // A-Z（IME 路径下用户可能按着 Shift）
    return c - 0x40;
  }
  switch (ch) {
    case '2':
    case ' ':
      return 0x00;
    case '3':
    case '[':
      return 0x1B;
    case '4':
    case '\\':
      return 0x1C;
    case '5':
    case ']':
      return 0x1D;
    case '6':
      return 0x1E;
    case '7':
    case '/':
    case '-':
      return 0x1F;
    case '8':
      return 0x7F;
    default:
      return -1;
  }
}

/** 修饰键/锁键自身判定（按下这些键不产生任何字节序列） */
export function isModifierKeyCode(keyCode: number): boolean {
  return MODIFIER_KEY_CODES.indexOf(keyCode) >= 0;
}

/**
 * 可打印键码判定（字母/数字/标点/空格）。IME 前拦截（onKeyPreIme）用它决定
 * 放行还是消费：无 Ctrl/Alt 的可打印键放行给 IME 走增量路径（中文候选不被打断）。
 */
export function isPrintableKeyCode(keyCode: number): boolean {
  if (keyCode >= KEY_A && keyCode <= KEY_Z) {
    return true;
  }
  if (keyCode >= KEY_0 && keyCode <= KEY_9) {
    return true;
  }
  if (keyCode === KEY_SPACE) {
    return true;
  }
  return punctChars(keyCode) !== null;
}

// ---------------------------------------------------------------- 可打印字符（US 布局）

/** 数字键 Shift 变形（US 布局）：下标即数字——0→')'、1→'!' … 9→'(' */
const SHIFTED_DIGITS = ')!@#$%^&*(';

/** 标点键 Shift 变形表（US 布局）：[plain, shifted] */
function punctChars(keyCode: number): string[] | null {
  switch (keyCode) {
    case KEY_GRAVE:
      return ['`', '~'];
    case KEY_MINUS:
      return ['-', '_'];
    case KEY_EQUALS:
      return ['=', '+'];
    case KEY_LEFT_BRACKET:
      return ['[', '{'];
    case KEY_RIGHT_BRACKET:
      return [']', '}'];
    case KEY_BACKSLASH:
      return ['\\', '|'];
    case KEY_SEMICOLON:
      return [';', ':'];
    case KEY_APOSTROPHE:
      return ['\'', '"'];
    case KEY_COMMA:
      return [',', '<'];
    case KEY_PERIOD:
      return ['.', '>'];
    case KEY_SLASH:
      return ['/', '?'];
    default:
      return null;
  }
}

// ---------------------------------------------------------------- 功能键/导航键映射

/**
 * 「尾字符型」按键（无修饰时 CSI/SS3 + final，带修饰时 CSI 1;param + final）。
 * 方向键专属 application 标志：应用光标模式下无修饰发 SS3。
 */
function mapFinalCharKey(finalChar: string, isCursorKey: boolean, shift: boolean, alt: boolean,
  ctrl: boolean, appCursorKeys: boolean): Uint8Array {
  const mod = modifierParam(shift, alt, ctrl);
  if (mod === 1) {
    if (isCursorKey && appCursorKeys) {
      return asciiBytes('\x1bO' + finalChar); // SS3 形式（应用光标模式）
    }
    return asciiBytes('\x1b[' + finalChar);
  }
  // 带修饰一律 CSI 1;param<final>（xterm 修正参数形式，应用模式下同形）
  return asciiBytes(`\x1b[1;${mod}${finalChar}`);
}

/** 「波浪号型」按键（CSI n~，带修饰 CSI n;param~） */
function mapTildeKey(n: number, shift: boolean, alt: boolean, ctrl: boolean): Uint8Array {
  const mod = modifierParam(shift, alt, ctrl);
  if (mod === 1) {
    return asciiBytes(`\x1b[${n}~`);
  }
  return asciiBytes(`\x1b[${n};${mod}~`);
}

/** F1–F12：F1–F4 尾字符型（SS3 P/Q/R/S），F5–F12 波浪号型 */
function mapFunctionKey(keyCode: number, shift: boolean, alt: boolean, ctrl: boolean): Uint8Array | null {
  if (keyCode < KEY_F1 || keyCode > KEY_F12) {
    return null;
  }
  const n = keyCode - KEY_F1 + 1; // 1..12
  switch (n) {
    case 1:
      return mapFinalCharKey('P', false, shift, alt, ctrl, false);
    case 2:
      return mapFinalCharKey('Q', false, shift, alt, ctrl, false);
    case 3:
      return mapFinalCharKey('R', false, shift, alt, ctrl, false);
    case 4:
      return mapFinalCharKey('S', false, shift, alt, ctrl, false);
    default:
      break;
  }
  // xterm 表：F5=15、F6=17、F7=18、F8=19、F9=20、F10=21、F11=23、F12=24
  const tildeCodes: number[] = [15, 17, 18, 19, 20, 21, 23, 24];
  return mapTildeKey(tildeCodes[n - 5], shift, alt, ctrl);
}

// ---------------------------------------------------------------- 主映射函数

/**
 * 按键事件 → VT 字节序列；null = 未映射（修饰键自身/未知键码/未定义组合），
 * 调用方应放行系统默认处理。
 *
 * @param keyCode HarmonyOS KeyCode 数值（@ohos.multimodalInput.keyCode）
 * @param applicationCursorKeys 终端应用光标模式（DECCKM）标志——native 侧
 *   尚未暴露该模式位（T1 未加），首版由 TerminalCanvas 参数化透传，
 *   native 暴露后接线（待真机核对 vim/htop 内方向键行为）。
 */
export function mapKeyEvent(keyCode: number, shift: boolean, alt: boolean, ctrl: boolean,
  meta: boolean, applicationCursorKeys: boolean): Uint8Array | null {
  if (isModifierKeyCode(keyCode)) {
    return null;
  }
  // Meta 暂按 Alt 处理（文件头注「已知取舍」）
  const effAlt = alt || meta;

  // ---- 方向键 ----
  switch (keyCode) {
    case KEY_DPAD_UP:
      return mapFinalCharKey('A', true, shift, effAlt, ctrl, applicationCursorKeys);
    case KEY_DPAD_DOWN:
      return mapFinalCharKey('B', true, shift, effAlt, ctrl, applicationCursorKeys);
    case KEY_DPAD_RIGHT:
      return mapFinalCharKey('C', true, shift, effAlt, ctrl, applicationCursorKeys);
    case KEY_DPAD_LEFT:
      return mapFinalCharKey('D', true, shift, effAlt, ctrl, applicationCursorKeys);
    default:
      break;
  }

  // ---- Home/End（xterm 变体 CSI H / CSI F）----
  if (keyCode === KEY_MOVE_HOME) {
    return mapFinalCharKey('H', false, shift, effAlt, ctrl, false);
  }
  if (keyCode === KEY_MOVE_END) {
    return mapFinalCharKey('F', false, shift, effAlt, ctrl, false);
  }

  // ---- 波浪号型导航键 ----
  if (keyCode === KEY_INSERT) {
    return mapTildeKey(2, shift, effAlt, ctrl);
  }
  if (keyCode === KEY_FORWARD_DEL) {
    return mapTildeKey(3, shift, effAlt, ctrl);
  }
  if (keyCode === KEY_PAGE_UP) {
    return mapTildeKey(5, shift, effAlt, ctrl);
  }
  if (keyCode === KEY_PAGE_DOWN) {
    return mapTildeKey(6, shift, effAlt, ctrl);
  }

  // ---- F1–F12 ----
  const fn = mapFunctionKey(keyCode, shift, effAlt, ctrl);
  if (fn !== null) {
    return fn;
  }

  // ---- 特殊键 ----
  if (keyCode === KEY_ESCAPE) {
    return new Uint8Array([ESC]);
  }
  if (keyCode === KEY_ENTER) {
    return new Uint8Array([0x0D]); // CR
  }
  if (keyCode === KEY_BACKSPACE) {
    // Alt+Backspace = ESC DEL（readline backward-kill-word 惯例）；其余修饰不区分
    const bs = new Uint8Array([DEL]);
    return effAlt ? withEscPrefix(bs) : bs;
  }
  if (keyCode === KEY_TAB) {
    if (ctrl) {
      // xterm 修正参数形式：CSI 1;param I
      return asciiBytes(`\x1b[1;${modifierParam(shift, effAlt, true)}I`);
    }
    if (shift) {
      return asciiBytes('\x1b[Z'); // Shift+Tab（back-tab）
    }
    if (effAlt) {
      return asciiBytes('\x1b\t');
    }
    return new Uint8Array([0x09]);
  }

  // ---- 可打印字符 ----
  if (keyCode === KEY_SPACE) {
    return mapPrintableChar(' ', effAlt, ctrl);
  }
  if (keyCode >= KEY_A && keyCode <= KEY_Z) {
    const base = String.fromCharCode(0x61 + (keyCode - KEY_A)); // 小写基准
    return mapPrintableChar(shift ? base.toUpperCase() : base, effAlt, ctrl);
  }
  if (keyCode >= KEY_0 && keyCode <= KEY_9) {
    const digit = keyCode - KEY_0;
    const ch = shift ? SHIFTED_DIGITS.charAt(digit) : String(digit);
    return mapPrintableChar(ch, effAlt, ctrl);
  }
  const punct = punctChars(keyCode);
  if (punct !== null) {
    return mapPrintableChar(shift ? punct[1] : punct[0], effAlt, ctrl);
  }

  return null; // 未映射：小键盘/多媒体键等（T10 再扩）
}

/**
 * 单个已成形字符 + 修饰 → VT 字节（IME 提交路径的粘滞修饰出口，
 * 也供 mapKeyEvent 的可打印分支复用）：
 *   Ctrl → 经典控制字符（ctrlCharForAscii，未定义组合返回 null 不发送）；
 *   Alt  → ESC 前缀 + 字符 UTF-8；
 *   无修饰 → 字符 UTF-8（中文等多字节字符走此路径）。
 *
 * @param ch 单个字符（多字符字符串仅在前两者之外按整串 UTF-8 发送）
 */
export function mapPrintableChar(ch: string, alt: boolean, ctrl: boolean): Uint8Array | null {
  if (ctrl) {
    const code = ctrlCharForAscii(ch);
    if (code < 0) {
      return null; // Ctrl+未定义字符：不发送（宁可不发也不乱发）
    }
    return new Uint8Array([code]);
  }
  const body = utf8Bytes(ch);
  return alt ? withEscPrefix(body) : body;
}
