/**
 * ImeInputLogic —— 终端 IME 输入的纯逻辑（从 ImeInputHandler 拆出，便于 Node/hypium
 * 单测；ImeInputHandler 仍 re-export 全部符号，旧 import 路径不变）。
 *
 * 两条 IME 通路共用这里的字节语义：
 *  - 主通路：inputMethod 自绘编辑器（TerminalImeEditor）——insertText / deleteLeft /
 *    sendFunctionKey 直接是「提交文本 / 退格 n 次 / 回车」，不再靠 diff 猜增量；
 *  - 兜底通路：隐藏 TextInput（ImeInputSink）——onChange 前后值 diff
 *    （extractCommittedDelta），带零宽哨兵以识别空缓冲上的退格。
 */
import { mapPrintableChar, utf8Bytes } from './KeyMap';
import { StickySnapshot } from './StickyModifiers';

const DEL = 0x7F;
const ESC = 0x1B;
/** 隐藏 TextInput 的已提交文本上限；到阈值即清空，避免长会话 diff 退化。 */
export const IME_BUFFER_RESET_THRESHOLD = 64;

/** IME 一次提交的内容增量（extractCommittedDelta 输出） */
export interface CommittedDelta {
  /** 新增文本（可能为空串，如纯退格） */
  text: string;
  /** 删除的字符数（按码点计；0 = 无删除） */
  backspaces: number;
}

/** 字符串码点数（退格按字符计，代理对如 emoji 只算 1 次）。不用 Array.from：ArkTS 下对代理对可能按 UTF-16 单元拆开。 */
function codePointCount(s: string): number {
  let n = 0;
  let i = 0;
  while (i < s.length) {
    const code = s.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        i += 2;
        n++;
        continue;
      }
    }
    i++;
    n++;
  }
  return n;
}

/**
 * 由 onChange 的前后两个完整值 diff 出提交增量：
 *   最长公共前缀之后，prev 的剩余部分 = 被删除（\x7F×码点数），
 *   curr 的剩余部分 = 新增文本。隐藏输入框内无可见光标，编辑恒发生在尾部，
 *   前缀 diff 足够；中间编辑（拖动光标改字）也会按「删尾+补尾」等价处理。
 *
 * @param previewActive 候选期标志（previewText.value 非空）：候选期返回 null
 *   且不视为提交——候选中的拼音字母绝不发给通道（DESIGN §4.4 验收标准）。
 * 返回 null = 无可提交内容（含前后值一致）。
 */
export function extractCommittedDelta(prev: string, curr: string,
  previewActive: boolean): CommittedDelta | null {
  if (previewActive) {
    return null;
  }
  let prefix = 0;
  const limit = Math.min(prev.length, curr.length);
  while (prefix < limit && prev.charCodeAt(prefix) === curr.charCodeAt(prefix)) {
    prefix++;
  }
  const backspaces = codePointCount(prev.substring(prefix));
  const text = curr.substring(prefix);
  if (backspaces === 0 && text.length === 0) {
    return null;
  }
  return { text, backspaces };
}

/**
 * 增量 → VT 字节（null = 本次不发送，如 Ctrl+未定义字符）：
 *   - 退格：0x7F×n；粘滞 Alt 生效时整体加一次 ESC 前缀
 *     （readline backward-kill-word 惯例）；
 *   - 单字符文本 + 粘滞 Ctrl/Alt：走 mapPrintableChar（Ctrl+C → 0x03、
 *     Alt+B → \x1Bb）；Ctrl+未定义字符返回 null 不发送；
 *   - 多字符文本（中文整词上屏等）：整串 UTF-8，粘滞修饰不施加
 *     （IME 整词提交无单键修饰语义）；退格与新增混合时两段各自按
 *     上述规则处理（单字符新增照常施加粘滞修饰）。
 */
export function committedDeltaToInputBytes(delta: CommittedDelta,
  sticky: StickySnapshot): Uint8Array | null {
  if (delta.backspaces === 0 && delta.text.length === 0) {
    return null;
  }
  const parts: Uint8Array[] = [];
  let total = 0;
  const push = (part: Uint8Array): void => {
    parts.push(part);
    total += part.length;
  };
  if (delta.backspaces > 0) {
    const bs = new Uint8Array(delta.backspaces);
    bs.fill(DEL);
    if (sticky.alt) {
      push(new Uint8Array([ESC]));
    }
    push(bs);
  }
  if (delta.text.length > 0) {
    const singleChar = codePointCount(delta.text) === 1;
    if (singleChar && (sticky.ctrl || sticky.alt)) {
      const mapped = mapPrintableChar(delta.text, sticky.alt, sticky.ctrl);
      if (mapped === null) {
        return null; // Ctrl+未定义字符：整次不发送（退格部分也不发，保持原子）
      }
      push(mapped);
    } else {
      push(utf8Bytes(delta.text));
    }
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/**
 * 兜底 TextInput 的哨兵字符（零宽空格）。缓冲区恒以它开头：用户在「空」输入框上
 * 按退格时，删掉的是哨兵，onChange 能看到一次删除 → 发 0x7F；没有哨兵时系统
 * 键盘对空输入框的退格不产生任何回调，远端永远收不到退格。
 */
export const IME_SENTINEL: string = '\u200B';

/** 去掉哨兵（diff 前统一剥离，哨兵本身既不算输入也不算删除基线） */
export function stripImeSentinel(value: string): string {
  return value.split(IME_SENTINEL).join('');
}

/** 哨兵被删掉（value 不再以哨兵开头）= 用户在空缓冲上按了退格 */
export function sentinelDeleted(value: string): boolean {
  return !value.startsWith(IME_SENTINEL);
}

/**
 * IME 提交文本归一：换行统一成 CR（终端 Enter 语义）。
 * 部分输入法把回车当作 insertText('\n') 而非 sendFunctionKey 发来；
 * \r\n 先折叠，避免一次回车发两次。
 */
export function normalizeImeText(text: string): string {
  return text.replace(/\r\n/g, '\r').replace(/\n/g, '\r');
}

/** IME insertText → 字节（含换行归一与粘滞修饰；null = 不发送） */
export function imeInsertToBytes(text: string, sticky: StickySnapshot): Uint8Array | null {
  if (text.length === 0) {
    return null;
  }
  return committedDeltaToInputBytes({ text: normalizeImeText(text), backspaces: 0 }, sticky);
}

/** IME deleteLeft(n) → 0x7F×n（粘滞 Alt 时 ESC 前缀；n 非法按 0） */
export function imeDeleteLeftToBytes(length: number, sticky: StickySnapshot): Uint8Array | null {
  const n: number = Number.isFinite(length) ? Math.max(0, Math.min(Math.floor(length), 256)) : 0;
  if (n === 0) {
    return null;
  }
  return committedDeltaToInputBytes({ text: '', backspaces: n }, sticky);
}

/** IME deleteRight(n) → ESC[3~ × n（Delete 键；终端没有「光标右侧文本」概念） */
export function imeDeleteRightToBytes(length: number): Uint8Array | null {
  const n: number = Number.isFinite(length) ? Math.max(0, Math.min(Math.floor(length), 256)) : 0;
  if (n === 0) {
    return null;
  }
  const seq: number[] = [];
  for (let i = 0; i < n; i++) {
    seq.push(ESC, 0x5B, 0x33, 0x7E);
  }
  return new Uint8Array(seq);
}

/** IME 方向（inputMethod.Direction：UP=1 DOWN=2 LEFT=3 RIGHT=4）→ 方向键序列 */
export function imeMoveCursorToBytes(direction: number, applicationCursorKeys: boolean): Uint8Array | null {
  let final: number = 0;
  switch (direction) {
    case 1:
      final = 0x41; // A
      break;
    case 2:
      final = 0x42; // B
      break;
    case 3:
      final = 0x44; // D
      break;
    case 4:
      final = 0x43; // C
      break;
    default:
      return null;
  }
  return new Uint8Array([ESC, applicationCursorKeys ? 0x4F : 0x5B, final]);
}

/** 回车（sendFunctionKey 任意 enterKeyType 都按终端 Enter = CR） */
export function imeEnterBytes(): Uint8Array {
  return new Uint8Array([0x0D]);
}

/**
 * 本地回显上下文（供 IME getLeftTextOfCursor 联想用）：只记最近一行内已提交的字符，
 * 回车/控制字符清空。远端真实行内容不可得（shell 自己编辑），这里只求「不误导」：
 * 最多保留 maxLen 个 UTF-16 单元。
 */
export class ImeEchoContext {
  private text: string = '';
  private readonly maxLen: number;

  constructor(maxLen: number = 32) {
    this.maxLen = maxLen;
  }

  insert(text: string): void {
    const normalized: string = normalizeImeText(text);
    const cr: number = normalized.lastIndexOf('\r');
    const tail: string = cr >= 0 ? normalized.substring(cr + 1) : normalized;
    this.text = cr >= 0 ? tail : this.text + tail;
    if (this.text.length > this.maxLen) {
      this.text = this.text.substring(this.text.length - this.maxLen);
    }
  }

  deleteLeft(n: number): void {
    let remaining: number = Math.max(0, Math.floor(n));
    let s: string = this.text;
    while (remaining > 0 && s.length > 0) {
      const last: number = s.charCodeAt(s.length - 1);
      const cut: number = last >= 0xDC00 && last <= 0xDFFF && s.length >= 2 ? 2 : 1;
      s = s.substring(0, s.length - cut);
      remaining--;
    }
    this.text = s;
  }

  clear(): void {
    this.text = '';
  }

  leftText(length: number): string {
    if (length <= 0) {
      return '';
    }
    return this.text.length <= length ? this.text : this.text.substring(this.text.length - length);
  }

  get length(): number {
    return this.text.length;
  }
}

/**
 * 物理键是否在 IME 之前截获（onKeyPreIme 返回 true）：
 *   - 候选（composition）进行中：一律放行，方向/退格/回车属于输入法；
 *   - 带 Ctrl/Alt：截获（终端控制键，输入法不该吃掉 Ctrl+C）；
 *   - 自绘编辑器通路：其余键先交给输入法（它会 insertText/deleteLeft/sendFunctionKey），
 *     输入法不消费的键随后到达 onKeyEvent 再映射——物理键盘中文输入不被打断；
 *   - 隐藏 TextInput 兜底通路：非可打印键截获（否则 TextInput 自己用方向/退格编辑
 *     隐藏文本，远端收不到），可打印键放行走 onChange 增量。
 */
export function shouldInterceptBeforeIme(customEditor: boolean, composing: boolean,
  ctrl: boolean, alt: boolean, printable: boolean): boolean {
  if (composing) {
    return false;
  }
  if (ctrl || alt) {
    return true;
  }
  if (customEditor) {
    return false;
  }
  return !printable;
}
