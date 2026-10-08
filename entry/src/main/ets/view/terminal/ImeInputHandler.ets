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
import {
  CommittedDelta,
  IME_BUFFER_RESET_THRESHOLD,
  IME_SENTINEL,
  extractCommittedDelta,
  sentinelDeleted,
  stripImeSentinel
} from './ImeInputLogic';

export {
  CommittedDelta,
  IME_BUFFER_RESET_THRESHOLD,
  IME_SENTINEL,
  committedDeltaToInputBytes,
  extractCommittedDelta,
  imeDeleteLeftToBytes,
  imeDeleteRightToBytes,
  imeEnterBytes,
  imeInsertToBytes,
  imeMoveCursorToBytes,
  normalizeImeText,
  sentinelDeleted,
  stripImeSentinel,
  ImeEchoContext
} from './ImeInputLogic';

// ---------------------------------------------------------------- 组件粘合（兜底通路）

/**
 * 隐藏 IME 承接输入框（兜底通路：inputMethod 自绘编辑器 attach 失败时才挂载）。
 * 1vp×1vp、近全透明、不拦截触摸；每个终端窗格一个实例，点击窗格时 requestFocus。
 *
 * 相比旧实现补齐的体验缺口：
 *  - 零宽哨兵：缓冲恒以 IME_SENTINEL 开头，空缓冲上的退格也能识别并发 0x7F；
 *  - onSubmit：软键盘回车键发 CR，且 keepEditableState 保持键盘不收起；
 *  - 候选期保护：composition（previewText 非空）期间 onKeyPreIme 一律放行，
 *    物理键盘中文输入时不会把候选用的方向/退格键截给远端。
 */
@Component
export struct ImeInputSink {
  /** 全局唯一组件 id（focusControl.requestFocus 用）；由宿主注入保证多窗格唯一 */
  sinkId: string = '';
  /** true 时组件首次挂载即取得输入焦点并拉起软键盘。 */
  autoFocus: boolean = false;
  /** 提交增量回调（宿主负责：粘滞修饰 → 字节 → 按焦点路由写入通道） */
  onDelta: (delta: CommittedDelta) => void = () => {};
  /** 软键盘回车（onSubmit）回调：宿主发 CR */
  onEnter: () => void = () => {};
  /**
   * IME 前物理键拦截（API 12+ onKeyPreIme）：宿主实现「方向/功能/Ctrl 组合
   * 消费映射，可打印键放行」；返回 true 表示已消费不再进 IME
   */
  onInterceptKey: (event: KeyEvent) => boolean = () => false;
  /**
   * T10：外接键盘活跃时置 false——聚焦本承接框**不**拉起软键盘
   * （enableKeyboardOnFocus=false；物理键仍经 onKeyPreIme 进宿主）。
   */
  @Prop enableSoftKeyboardOnFocus: boolean = true;

  private controller: TextInputController = new TextInputController();
  /** 绑定到 TextInput 的值（恒含哨兵前缀；重置时整体回写） */
  @State private value: string = IME_SENTINEL;
  /** 上次已提交基线（已剥哨兵；候选期不更新，见头注） */
  private lastValue: string = '';
  /** 候选（composition）进行中 */
  private composing: boolean = false;

  /** 请求软键盘焦点（点击窗格时调用）；id 未配置时静默忽略 */
  requestFocus(): void {
    if (this.sinkId.length > 0) {
      focusControl.requestFocus(this.sinkId);
    }
  }

  private resetBuffer(): void {
    this.lastValue = '';
    this.value = IME_SENTINEL;
    this.controller.caretPosition(IME_SENTINEL.length);
  }

  private handleChange(raw: string, previewText?: PreviewText): void {
    const previewActive = previewText !== undefined && previewText.value.length > 0;
    this.composing = previewActive;
    if (previewActive) {
      return; // 候选期：不发送、不更新基线（中文上屏后整体 diff 一次）
    }
    const deletedSentinel: boolean = sentinelDeleted(raw);
    const curr: string = stripImeSentinel(raw);
    const delta = extractCommittedDelta(this.lastValue, curr, false);
    this.lastValue = curr;
    if (delta !== null) {
      this.onDelta(delta);
    } else if (deletedSentinel && curr.length === 0) {
      // 空缓冲上的退格：删的是哨兵本身
      this.onDelta({ text: '', backspaces: 1 });
    }
    if (deletedSentinel || curr.length >= IME_BUFFER_RESET_THRESHOLD) {
      // 只在候选提交结束后重置，绝不打断中文 composition
      this.resetBuffer();
    } else {
      this.value = raw;
    }
  }

  build() {
    TextInput({ text: this.value, controller: this.controller })
      .id(this.sinkId)
      .width(1) // 隐藏承接框：尺寸/透明约定见文件头注
      .height(1)
      .opacity(0.01) // 保持 focusable 的最小可见度（0 会被渲染管线裁掉）
      .showUnderline(false)
      .caretColor(Color.Transparent)
      .enterKeyType(EnterKeyType.Send)
      .enableAutoFill(false)
      .enableKeyboardOnFocus(this.enableSoftKeyboardOnFocus)
      .defaultFocus(this.autoFocus)
      .hitTestBehavior(HitTestMode.None) // 永不拦截触摸，点击全归终端画布
      .accessibilityText('终端输入')
      .onChange((value: string, previewText?: PreviewText) => {
        this.handleChange(value, previewText);
      })
      .onSubmit((_enterKey: EnterKeyType, event?: SubmitEvent) => {
        // 回车 = CR；keepEditableState 让软键盘保持弹出（连续敲命令不闪键盘）
        if (event !== undefined) {
          event.keepEditableState();
        }
        this.onEnter();
      })
      .onKeyPreIme((event: KeyEvent): boolean => {
        if (this.composing) {
          return false; // 候选中：方向/退格/回车都属于输入法
        }
        return this.onInterceptKey(event);
      })
  }
}
