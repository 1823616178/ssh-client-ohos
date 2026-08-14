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
 *  - 键高 40vp、横向滑动，满足「单手可完成 Ctrl+C / Ctrl+Z / Esc / Tab 补全」：
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
import { StickyModifiers, StickyState } from './terminal/StickyModifiers';
import { vibrateLight } from '../common/utils/Haptics';
import { Logger } from '../common/utils/Logger';
import { Tokens } from '../theme/Tokens';

// ---------------------------------------------------------------- 键位模型与默认布局

/** 键位类别：char=直接字符 / keyCode=经 KeyMap 映射的功能键 / ctrl/alt=粘滞修饰 */
export type KeyBarKeyKind = 'char' | 'keyCode' | 'ctrl' | 'alt';

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
  makeCharKey('-'),
  makeCharKey('|'),
  makeCharKey('~'),
  makeCharKey('/')
];

/** 自定义布局里可按名引用的已知功能键（key 字段 → 规格；char 键走另一条路径） */
function knownKeySpec(name: string): KeyBarKeySpec | null {
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

// ---------------------------------------------------------------- 组件

/** 键高（vp）：单手拇指可达的紧凑尺寸（DESIGN §4.4 底栏） */
const KEY_HEIGHT_VP = 40;
/** 键最小宽度（vp） */
const KEY_MIN_WIDTH_VP = 44;
/** 键间距（vp） */
const KEY_SPACE_VP = 6;
/** 锁定态描边宽（vp）：与 pressed 态区分（pressed 无描边） */
const KEY_LOCKED_BORDER_VP = 2;

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

  @State private keys: KeyBarKeySpec[] = DEFAULT_KEY_BAR_LAYOUT;
  // StickyModifiers 非 @Observed：点击后手动读回状态驱动高亮刷新
  @State private ctrlState: StickyState = StickyState.IDLE;
  @State private altState: StickyState = StickyState.IDLE;

  aboutToAppear(): void {
    this.keys = parseKeyBarLayout(this.layoutJson);
    this.syncModifierStates();
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
    const snap = this.stickyModifiers.snapshot();
    const bytes = keyBarBytesForKey(spec, snap.ctrl, snap.alt, this.applicationCursorKeys);
    // 「下一个按键带修饰」以按键计：无论是否映射出字节都消费一次性粘滞
    this.stickyModifiers.consume();
    this.syncModifierStates();
    if (bytes !== null) {
      this.onSendBytes(bytes);
    }
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

  private isModifierLocked(spec: KeyBarKeySpec): boolean {
    if (spec.kind === 'ctrl') {
      return this.ctrlState === StickyState.LOCKED;
    }
    if (spec.kind === 'alt') {
      return this.altState === StickyState.LOCKED;
    }
    return false;
  }

  build() {
    Scroll() {
      Row({ space: KEY_SPACE_VP }) {
        ForEach(this.keys, (spec: KeyBarKeySpec) => {
          Text(spec.label)
            .height(KEY_HEIGHT_VP)
            .constraintSize({ minWidth: KEY_MIN_WIDTH_VP })
            .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
            .fontSize(Tokens.fontSize.body)
            .fontColor(this.isModifierActive(spec) ? Tokens.Color.appBg : Tokens.Color.text)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.isModifierActive(spec) ? Tokens.Color.accent : Tokens.Color.surface)
            .borderRadius(Tokens.radius.sm)
            .border({
              width: this.isModifierLocked(spec) ? KEY_LOCKED_BORDER_VP : 0,
              color: Tokens.Color.text
            })
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
        }, (spec: KeyBarKeySpec) => spec.id)
      }
      .padding({ left: Tokens.space.xs, right: Tokens.space.xs })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
    .width('100%')
  }
}
