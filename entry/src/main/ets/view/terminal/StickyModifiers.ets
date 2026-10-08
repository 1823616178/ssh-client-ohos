/**
 * StickyModifiers —— 功能键条粘滞修饰键状态机（任务 T6，DESIGN §4.4
 * 「修饰键」：Ctrl/Alt 为粘滞——点一下高亮，下一个按键带该修饰，再点取消；
 * 长按锁定）。
 *
 * 每个修饰键（Ctrl / Alt）独立走一台三态状态机：
 *
 *   IDLE ──tap──▶ PRESSED ──tap──▶ IDLE        （再点取消）
 *     ▲             │  ▲
 *     │             │  └──lock()──▶ LOCKED ──tap──▶ IDLE
 *     │             │                 ▲
 *     └─consume()───┘                 │
 *     （按键消费后 PRESSED 自动复位）  └──────── lock()（任意态长按即锁定）
 *
 *   - consume() 在每次按键（物理键或 IME 字符提交）后调用：PRESSED → IDLE，
 *     LOCKED 保持（锁定后持续带修饰，直到再点取消）；
 *   - ctrlActive()/altActive() = 非 IDLE 即生效（PRESSED 与 LOCKED 都带修饰）；
 *   - 长按入口 lockCtrl()/lockAlt() 由 T7 功能键条的长按手势调用；
 *     轻震反馈（@ohos.vibrator）也归 T7，本类只管状态。
 *
 * 纯逻辑、不碰 UI；TerminalCanvas 持有实例并在按键出口消费，T7 键条读写状态。
 * 状态变化通过 addListener 广播：画布在软键盘/物理键出口 consume() 后，
 * 键条的 Ctrl/Alt 高亮能立即熄灭（旧实现只在键条自己被点时才读回状态，
 * 用软键盘敲完 Ctrl+C 后 Ctrl 仍显示高亮）。
 */

/** 状态变化监听器 */
export type StickyModifiersListener = () => void;

/** 粘滞态：idle 未激活 / pressed 下一键生效后复位 / locked 持续生效 */
export enum StickyState {
  IDLE = 0,
  PRESSED = 1,
  LOCKED = 2
}

/** 一次按键时粘滞修饰的快照（并入硬件修饰后的附加值） */
export interface StickySnapshot {
  ctrl: boolean;
  alt: boolean;
}

export class StickyModifiers {
  private ctrl: StickyState = StickyState.IDLE;
  private alt: StickyState = StickyState.IDLE;
  private readonly listeners: StickyModifiersListener[] = [];

  /** 订阅状态变化；返回取消订阅函数 */
  addListener(cb: StickyModifiersListener): () => void {
    this.listeners.push(cb);
    return (): void => {
      const i: number = this.listeners.indexOf(cb);
      if (i >= 0) {
        this.listeners.splice(i, 1);
      }
    };
  }

  private update(ctrl: StickyState, alt: StickyState): void {
    if (ctrl === this.ctrl && alt === this.alt) {
      return;
    }
    this.ctrl = ctrl;
    this.alt = alt;
    const snapshot: StickyModifiersListener[] = this.listeners.slice();
    for (const cb of snapshot) {
      cb();
    }
  }

  /** 点按 Ctrl：IDLE→PRESSED、PRESSED→IDLE、LOCKED→IDLE（取消锁定） */
  tapCtrl(): void {
    this.update(this.tapNext(this.ctrl), this.alt);
  }

  /** 点按 Alt：同 tapCtrl */
  tapAlt(): void {
    this.update(this.ctrl, this.tapNext(this.alt));
  }

  /** 长按 Ctrl（T7 键条入口）：任意态 → LOCKED */
  lockCtrl(): void {
    this.update(StickyState.LOCKED, this.alt);
  }

  /** 长按 Alt（T7 键条入口）：任意态 → LOCKED */
  lockAlt(): void {
    this.update(this.ctrl, StickyState.LOCKED);
  }

  get ctrlState(): StickyState {
    return this.ctrl;
  }

  get altState(): StickyState {
    return this.alt;
  }

  /** Ctrl 是否生效（PRESSED 或 LOCKED） */
  ctrlActive(): boolean {
    return this.ctrl !== StickyState.IDLE;
  }

  /** Alt 是否生效（PRESSED 或 LOCKED） */
  altActive(): boolean {
    return this.alt !== StickyState.IDLE;
  }

  /** 当前生效快照（按键映射前取一次，映射完调 consume()） */
  snapshot(): StickySnapshot {
    return { ctrl: this.ctrlActive(), alt: this.altActive() };
  }

  /**
   * 按键后消费：PRESSED → IDLE（一次性修饰用完即复位），LOCKED 保持。
   * 无论该键是否映射出字节序列都应调用（「下一个按键带修饰」以按键计）。
   */
  consume(): void {
    this.update(this.ctrl === StickyState.PRESSED ? StickyState.IDLE : this.ctrl,
      this.alt === StickyState.PRESSED ? StickyState.IDLE : this.alt);
  }

  /** 全部复位（会话切换/窗格关闭时调用） */
  reset(): void {
    this.update(StickyState.IDLE, StickyState.IDLE);
  }

  private tapNext(state: StickyState): StickyState {
    return state === StickyState.IDLE ? StickyState.PRESSED : StickyState.IDLE;
  }
}
