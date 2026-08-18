/**
 * ImeInputHandler —— 隐藏 TextInput 承接 IME（任务 T6，DESIGN §4.4「输入法」：
 * 隐藏 TextInput 承接 IME，onChange 取增量提交给通道；中文候选期间不发送）。
 *
 * 纯逻辑（hypium 覆盖）：
 *   - extractCommittedDelta(prev, curr, previewActive)：由前后两个完整值 diff 出
 *     增量（新增串 + 退格数，退格按码点计）；候选期（previewActive）返回 null；
 *   - committedDeltaToInputBytes(delta, sticky)：增量 → VT 字节
 *     （退格 = 0x7F×n；单字符且粘滞 Ctrl/Alt 生效时走 mapPrintableChar，
 *     中文等多字符提交按整串 UTF-8 发送）。
 *
 * 组件粘合（ImeInputSink）：
 *   - 1vp × 1vp、opacity 0.01 的 TextInput（保持 focusable、不拦截触摸），
 *     承接软键盘；候选期判定用 API 12+ onChange 的 previewText 参数
 *     （previewText.value 非空 = 候选中）；
 *   - 候选期既不发送也不更新基线：候选提交时与候选前文本整体 diff，
 *     保证中文上屏只发一次且不把候选字母误发出去；
 *   - 物理键拦截出口 onKeyPreIme（IME 之前）：方向键/功能键/Ctrl 组合
 *     会被 TextInput 自身消费（光标移动/复制粘贴快捷键），必须在 IME 前
 *     拦截交给 mapKeyEvent；可打印键不拦截（放行给 IME 走增量路径）。
 *
 * 待真机验证项：
 *   - previewText 参数在不同中文输入法（小艺/搜狗等）下是否稳定上报；
 *     若不上报则退化为候选字母直发（可接受降级，不丢字不错字）；
 *   - onKeyPreIme 对 F1–F12/方向键的拦截率（不同外接键盘）。
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

/** 字符串码点数（退格按字符计，代理对如 emoji 只算 1 次） */
function codePointCount(s: string): number {
  return Array.from(s).length;
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

// ---------------------------------------------------------------- 组件粘合

/**
 * 隐藏 IME 承接输入框（1vp×1vp、近全透明、不拦截触摸）。
 * 每个终端窗格一个实例；点击窗格时 requestFocus() 弹起软键盘。
 */
@Component
export struct ImeInputSink {
  /** 全局唯一组件 id（focusControl.requestFocus 用）；由宿主注入保证多窗格唯一 */
  sinkId: string = '';
  /** true 时组件首次挂载即取得输入焦点并拉起软键盘。 */
  autoFocus: boolean = false;
  /** 提交增量回调（宿主负责：粘滞修饰 → 字节 → 按焦点路由写入通道） */
  onDelta: (delta: CommittedDelta) => void = () => {};
  /**
   * IME 前物理键拦截（API 12+ onKeyPreIme）：宿主实现「方向/功能/Ctrl 组合
   * 消费映射，可打印键放行」；返回 true 表示已消费不再进 IME
   */
  onInterceptKey: (event: KeyEvent) => boolean = () => false;

  private controller: TextInputController = new TextInputController();
  /** 上次已提交基线（候选期不更新，见头注） */
  private lastValue: string = '';
  /** controller.deleteText 产生的空值 onChange 只同步基线，不转成退格发送。 */
  private resettingBuffer: boolean = false;

  /** 请求软键盘焦点（点击窗格时调用）；id 未配置时静默忽略 */
  requestFocus(): void {
    if (this.sinkId.length > 0) {
      focusControl.requestFocus(this.sinkId);
    }
  }

  private handleChange(value: string, previewText?: PreviewText): void {
    if (this.resettingBuffer) {
      this.resettingBuffer = false;
      if (value.length === 0) {
        this.lastValue = '';
        return;
      }
      // 少数输入法不回调清空态而直接回调下一字符；从空基线继续正常处理。
    }
    const previewActive = previewText !== undefined && previewText.value.length > 0;
    const delta = extractCommittedDelta(this.lastValue, value, previewActive);
    if (!previewActive) {
      this.lastValue = value;
    }
    if (delta !== null) {
      this.onDelta(delta);
    }
    if (!previewActive && value.length >= IME_BUFFER_RESET_THRESHOLD) {
      // 只在候选提交结束后清理，绝不打断中文 composition。先清逻辑基线，再删
      // TextInput 内容；随后产生的 value='' 回调由 resettingBuffer 吞掉。
      this.lastValue = '';
      this.resettingBuffer = true;
      this.controller.deleteText({ start: 0, end: value.length });
    }
  }

  build() {
    TextInput({ controller: this.controller })
      .id(this.sinkId)
      .width(1) // 隐藏承接框：尺寸/透明约定见文件头注
      .height(1)
      .opacity(0.01) // 保持 focusable 的最小可见度（0 会被渲染管线裁掉）
      .showUnderline(false)
      .enableKeyboardOnFocus(true)
      .defaultFocus(this.autoFocus)
      .hitTestBehavior(HitTestMode.None) // 永不拦截触摸，点击全归终端画布
      .onChange((value: string, previewText?: PreviewText) => {
        this.handleChange(value, previewText);
      })
      .onKeyPreIme((event: KeyEvent): boolean => {
        return this.onInterceptKey(event);
      })
  }
}
