/**
 * KeyBar —— 移动端功能键条（任务 T7，DESIGN §4.4 版面图底栏与「修饰键」表：
 * Esc Tab Ctrl Alt ↑ ↓ ← → … 可横滑、Ctrl/Alt 粘滞、支持自定义）。
 *
 * 结构：
 *  - 纯逻辑（hypium 覆盖）：KeyBarKeySpec 键位模型、DEFAULT_KEY_BAR_LAYOUT
 *    默认布局、parseKeyBarLayout 自定义布局解析（C3 keyBarLayout JSON 串）、
 *    keyBarBytesForKey 键位→VT 字节（复用 KeyMap 的 mapKeyEvent/mapPrintableChar，
 *    粘滞 Ctrl/Alt 在出字节前并入）；
 *  - 组件 KeyBar：横向 Scroll + 等高等宽键位；Ctrl/Alt 键点击=tap、长按=lock
 *    （StickyModifiers 三态状态机），高亮态用 app_accent，切换时轻震
 *    （vibrateLight，设备不支持时静默降级）；
 *  - 键面 40vp 高（≥40vp 触摸目标）、横向滑动；方向键/退格长按自动连发；
 *    Ctrl/Alt 高亮跟随 StickyModifiers 监听实时刷新（软键盘消费后立即熄灭）：
 *    Ctrl+C 路径 = 点 Ctrl（高亮）→ 软键盘敲 C（T6 IME 出口消费粘滞 → 0x03）；
 *    也可在自定义布局里直接放字母键。
 *
 * 宿主接线（U4，本组件不感知会话）：
 *   KeyBar({
 *     stickyModifiers: canvas.stickyModifiers,   // 与所属 TerminalCanvas 同一实例
 *     layoutJson: SettingsRepository.getKeyBarLayout(),  // C3 自定义布局（空串=默认）
 *     applicationCursorKeys: 同 TerminalCanvas 的同名参数,
 *     hapticEnabled: SettingsRepository.isHapticEnabled(),
 *     onSendBytes: (bytes) => canvas.sendExternalInput(bytes)
 *   })
 * 聚焦窗格路由在 TerminalCanvas.sendExternalInput 内完成（FocusManager 判定，
 * 非聚焦窗格不投递）——键条自身不做焦点判断，多窗格下只投聚焦窗格。
 */

import { StickyModifiers, StickyState } from './terminal/StickyModifiers';
import { vibrateLight } from '../common/utils/Haptics';
import { Tokens } from '../theme/Tokens';
import { TerminalClipboardAction } from './terminal/TerminalActionHub';
import {
  TerminalAppearance,
  createDefaultTerminalAppearance
} from './terminal/TerminalAppearance';
import {
  DEFAULT_KEY_BAR_LAYOUT,
  KEY_REPEAT_DELAY_MS,
  KEY_REPEAT_INTERVAL_MS,
  KeyBarKeySpec,
  isRepeatableKey,
  keyBarBytesForKey,
  keyFaceOverlayForBackground,
  parseKeyBarLayout
} from './KeyBarLayout';

export {
  DEFAULT_KEY_BAR_LAYOUT,
  KEY_BAR_KNOWN_KEY_NAMES,
  KEY_BAR_SUGGESTED_CHARS,
  KEY_REPEAT_DELAY_MS,
  KEY_REPEAT_INTERVAL_MS,
  KeyBarKeyKind,
  KeyBarKeySpec,
  isDefaultKeyBarLayout,
  isRepeatableKey,
  keyBarBytesForKey,
  keyBarContains,
  keyBarEntryName,
  keyFaceOverlayForBackground,
  knownKeySpec,
  makeKeyBarCharKey,
  moveKeyBarKey,
  parseKeyBarLayout,
  serializeKeyBarLayout
} from './KeyBarLayout';

// ---------------------------------------------------------------- 组件

/** 键面高度（vp）：≥40vp 触摸目标 */
const KEY_HEIGHT_VP = 40;
/** 键最小宽度（vp） */
const KEY_MIN_WIDTH_VP = 44;
/** 键间距（vp） */
const KEY_SPACE_VP = 4;
/** 锁定态描边宽（vp）：与 pressed 态区分（pressed 无描边） */
const KEY_LOCKED_BORDER_VP = 2;

/** 键位无障碍朗读名 */
function accessibilityNameOf(spec: KeyBarKeySpec): string {
  switch (spec.id) {
    case 'up':
      return '上方向键';
    case 'down':
      return '下方向键';
    case 'left':
      return '左方向键';
    case 'right':
      return '右方向键';
    case 'enter':
      return '回车';
    case 'backspace':
      return '退格';
    case 'ctrl':
      return 'Ctrl 修饰键，点按一次生效，长按锁定';
    case 'alt':
      return 'Alt 修饰键，点按一次生效，长按锁定';
    default:
      return spec.label;
  }
}

@Component
export struct KeyBar {
  /** 自定义布局 JSON（C3 keyBarLayout；空串/非法 = 内置默认布局） */
  @Prop @Watch('onLayoutChanged') layoutJson: string = '';
  /** 触感总开关（C3 hapticEnabled） */
  @Prop hapticEnabled: boolean = true;
  /** 终端应用光标模式（DECCKM）：与所属 TerminalCanvas 保持一致，由宿主透传 */
  @Prop applicationCursorKeys: boolean = false;
  /**
   * 粘滞修饰键状态机：必须与所属 TerminalCanvas 是同一实例（宿主注入），
   * 组件在每次点击后读回状态刷新高亮
   */
  stickyModifiers: StickyModifiers = new StickyModifiers();
  /** 字节发送出口：宿主路由到聚焦窗格（TerminalCanvas.sendExternalInput） */
  onSendBytes: (bytes: Uint8Array) => void = () => {};
  /**
   * 剪贴板动作出口（复制/粘贴不产字节）：宿主按聚焦 paneId 经
   * TerminalActionHub 转给对应画布执行
   */
  onClipboardAction: (action: TerminalClipboardAction) => void = () => {};
  /**
   * 终端外观：键条紧贴终端画布，配色必须取终端外观而非跟随系统色彩模式的
   * Design Token——浅色模式下 Token 会把键面画成白底黑字，与深色终端割裂。
   */
  @Prop appearance: TerminalAppearance = createDefaultTerminalAppearance();

  @State private keys: KeyBarKeySpec[] = DEFAULT_KEY_BAR_LAYOUT;
  // StickyModifiers 非 @Observed：订阅其监听器，任何出口 consume 后都刷新高亮
  @State private ctrlState: StickyState = StickyState.IDLE;
  @State private altState: StickyState = StickyState.IDLE;
  /** 正在按住的连发键 id（按下态高亮） */
  @State private pressedKeyId: string = '';
  private unsubscribeSticky: () => void = () => {};
  private repeatDelayTimer: number = -1;
  private repeatTimer: number = -1;

  aboutToAppear(): void {
    this.keys = parseKeyBarLayout(this.layoutJson);
    this.syncModifierStates();
    this.unsubscribeSticky = this.stickyModifiers.addListener((): void => {
      this.syncModifierStates();
    });
  }

  aboutToDisappear(): void {
    this.unsubscribeSticky();
    this.stopRepeat();
  }

  /** 连发键按下：立即发一次，按住 KEY_REPEAT_DELAY_MS 后按 KEY_REPEAT_INTERVAL_MS 连发 */
  private startRepeat(spec: KeyBarKeySpec): void {
    this.stopRepeat();
    this.pressedKeyId = spec.id;
    this.sendKey(spec);
    vibrateLight(this.hapticEnabled);
    this.repeatDelayTimer = setTimeout((): void => {
      this.repeatDelayTimer = -1;
      this.repeatTimer = setInterval((): void => {
        this.sendKey(spec);
      }, KEY_REPEAT_INTERVAL_MS);
    }, KEY_REPEAT_DELAY_MS);
  }

  private stopRepeat(): void {
    if (this.repeatDelayTimer >= 0) {
      clearTimeout(this.repeatDelayTimer);
      this.repeatDelayTimer = -1;
    }
    if (this.repeatTimer >= 0) {
      clearInterval(this.repeatTimer);
      this.repeatTimer = -1;
    }
    this.pressedKeyId = '';
  }

  /** 非修饰键出字节（并入粘滞修饰并消费一次性粘滞） */
  private sendKey(spec: KeyBarKeySpec): void {
    const snap = this.stickyModifiers.snapshot();
    const bytes = keyBarBytesForKey(spec, snap.ctrl, snap.alt, this.applicationCursorKeys);
    // 「下一个按键带修饰」以按键计：无论是否映射出字节都消费一次性粘滞
    this.stickyModifiers.consume();
    if (bytes !== null) {
      this.onSendBytes(bytes);
    }
  }

  private onLayoutChanged(): void {
    this.keys = parseKeyBarLayout(this.layoutJson);
  }

  private syncModifierStates(): void {
    this.ctrlState = this.stickyModifiers.ctrlState;
    this.altState = this.stickyModifiers.altState;
  }

  private onKeyTap(spec: KeyBarKeySpec): void {
    if (spec.kind === 'ctrl') {
      this.stickyModifiers.tapCtrl();
      this.syncModifierStates();
      vibrateLight(this.hapticEnabled);
      return;
    }
    if (spec.kind === 'alt') {
      this.stickyModifiers.tapAlt();
      this.syncModifierStates();
      vibrateLight(this.hapticEnabled);
      return;
    }
    if (spec.kind === 'copy' || spec.kind === 'paste') {
      this.onClipboardAction(spec.kind);
      vibrateLight(this.hapticEnabled);
      return;
    }
    this.sendKey(spec);
    vibrateLight(this.hapticEnabled);
  }

  private onKeyLongPress(spec: KeyBarKeySpec): void {
    // 长按 = 锁定粘滞修饰（仅 Ctrl/Alt；其余键长按无操作）
    if (spec.kind === 'ctrl') {
      this.stickyModifiers.lockCtrl();
      this.syncModifierStates();
      vibrateLight(this.hapticEnabled);
    } else if (spec.kind === 'alt') {
      this.stickyModifiers.lockAlt();
      this.syncModifierStates();
      vibrateLight(this.hapticEnabled);
    }
  }

  private isModifierActive(spec: KeyBarKeySpec): boolean {
    if (spec.kind === 'ctrl') {
      return this.ctrlState !== StickyState.IDLE;
    }
    if (spec.kind === 'alt') {
      return this.altState !== StickyState.IDLE;
    }
    return false;
  }

  /**
   * 键面底色：终端背景之上抬一档亮度的半透明白，深浅色终端外观下都自洽，
   * 不引入新的 Design Token 也不跟随系统色彩模式。
   */
  private keyFaceColor(): string {
    return keyFaceOverlayForBackground(this.appearance.background);
  }

  private isModifierLocked(spec: KeyBarKeySpec): boolean {
    if (spec.kind === 'ctrl') {
      return this.ctrlState === StickyState.LOCKED;
    }
    if (spec.kind === 'alt') {
      return this.altState === StickyState.LOCKED;
    }
    return false;
  }

  @Builder
  KeyFace(spec: KeyBarKeySpec) {
    Text(spec.label)
      .height(KEY_HEIGHT_VP)
      .constraintSize({ minWidth: KEY_MIN_WIDTH_VP })
      .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
      .fontSize(Tokens.fontSize.body)
      .fontColor(this.isModifierActive(spec) ? Tokens.Color.onAccent : this.appearance.foreground)
      .textAlign(TextAlign.Center)
      .backgroundColor(this.isModifierActive(spec) || this.pressedKeyId === spec.id
        ? Tokens.Color.accent : this.keyFaceColor())
      .borderRadius(Tokens.radius.sm)
      .border({
        width: this.isModifierLocked(spec) ? KEY_LOCKED_BORDER_VP : 0,
        color: this.appearance.foreground
      })
      .accessibilityText(accessibilityNameOf(spec))
  }

  build() {
    Scroll() {
      Row({ space: KEY_SPACE_VP }) {
        ForEach(this.keys, (spec: KeyBarKeySpec) => {
          if (isRepeatableKey(spec)) {
            // 连发键：按下即发、按住连发；用 onTouch 而不是手势，避免与横滑抢识别
            // 时出现「按下不发、抬手才发」的迟滞。横滑时系统发 Cancel，连发随之停止。
            Column() {
              this.KeyFace(spec)
            }
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.startRepeat(spec);
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.stopRepeat();
              }
            })
          } else {
            Column() {
              this.KeyFace(spec)
            }
            .gesture(
              // 互斥识别：快速点按 = tap，按住超阈值 = lock（长按仅修饰键响应）
              GestureGroup(GestureMode.Exclusive,
                LongPressGesture()
                  .onAction(() => {
                    this.onKeyLongPress(spec);
                  }),
                TapGesture()
                  .onAction(() => {
                    this.onKeyTap(spec);
                  })
              )
            )
          }
        }, (spec: KeyBarKeySpec) => spec.id)
      }
      .padding({ left: Tokens.space.xs, right: Tokens.space.xs, top: 2, bottom: 2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
    .width('100%')
    .backgroundColor(this.appearance.background)
    .onScrollStart(() => {
      this.stopRepeat();
    })
  }
}
