/**
 * WindowRegistry —— 进程内多窗口登记处（多窗口改造）。
 *
 * 背景：同一应用进程里的多个 UIAbility 实例共用一个 ArkTS 运行时，SessionManager 等
 * 单例天然被所有窗口共享——共享会话池正是想要的，但生命周期必须按「窗口」记账：
 *   - 引用计数：只有最后一个窗口销毁才算应用真正退出（closeAll 收口，见 AppBootstrap）；
 *   - 应用级前后台：任一窗口在前台即应用在前台。单窗口时窗口前后台与应用前后台
 *     逐拍一致（立即通知，行为与改造前完全相同）；多窗口时窗口切换会出现
 *     「A 先进后台、B 后进前台」的瞬时空档，故转后台延迟 APP_BACKGROUND_SETTLE_MS
 *     再确认，避免后台保活策略被一次窗口切换误触发；
 *   - 窗口对象：Ability 在 onWindowStageCreate 取到主窗口后登记，页面按 windowKey 取用
 *     （替代 window.getLastWindow——多窗口/子窗口下「最后一个窗口」不可靠）；
 *   - 窗口获焦（windowStageEvent ACTIVE）广播：输入法控制器进程内只有一个，
 *     窗口切换后由该窗口的聚焦画布重新 attach；
 *   - 打开请求：specified 实例被再次拉起（onNewWant）时把参数投递给该窗口的终端页。
 *
 * 纯逻辑（定时器可注入），系统类型只作类型引用，可在 Node 单测中加载。
 */

import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../../common/utils/Logger';

const LOG_TAG: string = 'WindowRegistry';

/** 多窗口下转后台的确认延迟（毫秒）：覆盖窗口切换时 onBackground/onForeground 的先后空档 */
export const APP_BACKGROUND_SETTLE_MS: number = 400;

/** 应用级前后台监听：true = 应用转前台 */
export type AppVisibilityListener = (foreground: boolean) => void;
/** 窗口获焦监听 */
export type WindowActiveListener = () => void;

/** 终端窗口的打开请求（onNewWant 转发） */
export interface TerminalOpenRequest {
  readonly hostId: string;
  readonly sessionIds: string[];
}

export type OpenRequestListener = (request: TerminalOpenRequest) => void;

/** 延时器抽象（生产 = setTimeout；单测手动触发） */
export interface SettleScheduler {
  schedule(delayMs: number, task: () => void): number;
  cancel(timerId: number): void;
}

class SystemSettleScheduler implements SettleScheduler {
  schedule(delayMs: number, task: () => void): number {
    return setTimeout(task, delayMs);
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

/** 单个窗口的登记项 */
interface WindowEntry {
  readonly windowKey: string;
  readonly context: common.UIAbilityContext | null;
  win: window.Window | null;
}

export class WindowRegistry {
  private static instance: WindowRegistry | null = null;

  /** 生产单例；单测请自行 new WindowRegistry(scheduler) */
  static get(): WindowRegistry {
    if (WindowRegistry.instance === null) {
      WindowRegistry.instance = new WindowRegistry();
    }
    return WindowRegistry.instance;
  }

  private readonly scheduler: SettleScheduler;
  /** 登记序即 Map 插入序（保活长时任务移交时取最早的存活窗口） */
  private readonly entries: Map<string, WindowEntry> = new Map();
  private readonly foregroundKeys: string[] = [];
  private appForeground: boolean = false;
  private backgroundTimerId: number = -1;
  private readonly visibilityListeners: AppVisibilityListener[] = [];
  private readonly activeListeners: Map<string, WindowActiveListener[]> = new Map();
  private readonly openListeners: Map<string, OpenRequestListener> = new Map();
  private readonly pendingOpen: Map<string, TerminalOpenRequest[]> = new Map();

  constructor(scheduler?: SettleScheduler) {
    this.scheduler = scheduler ?? new SystemSettleScheduler();
  }

  // ---------------------------------------------------------------- 引用计数

  /** 登记窗口（Ability.onCreate）；重复登记幂等。返回当前窗口数 */
  register(windowKey: string, context: common.UIAbilityContext | null): number {
    if (!this.entries.has(windowKey)) {
      const entry: WindowEntry = { windowKey: windowKey, context: context, win: null };
      this.entries.set(windowKey, entry);
      Logger.info(`窗口登记 ${windowKey}（共 ${this.entries.size} 个）`, LOG_TAG);
    }
    return this.entries.size;
  }

  /**
   * 注销窗口（Ability.onDestroy）；未知 key 幂等。返回剩余窗口数——0 即应用真正退出。
   * 顺带清掉该窗口的前台标记与监听，避免已销毁窗口把应用永远钉在前台。
   */
  unregister(windowKey: string): number {
    if (this.entries.delete(windowKey)) {
      Logger.info(`窗口注销 ${windowKey}（剩 ${this.entries.size} 个）`, LOG_TAG);
    }
    this.activeListeners.delete(windowKey);
    this.openListeners.delete(windowKey);
    this.pendingOpen.delete(windowKey);
    const index: number = this.foregroundKeys.indexOf(windowKey);
    if (index >= 0) {
      this.foregroundKeys.splice(index, 1);
      this.onForegroundCountChanged();
    }
    return this.entries.size;
  }

  count(): number {
    return this.entries.size;
  }

  has(windowKey: string): boolean {
    return this.entries.has(windowKey);
  }

  /** 全部窗口 key（登记序） */
  keys(): string[] {
    const result: string[] = [];
    this.entries.forEach((_entry: WindowEntry, key: string) => {
      result.push(key);
    });
    return result;
  }

  contextOf(windowKey: string): common.UIAbilityContext | null {
    const entry: WindowEntry | undefined = this.entries.get(windowKey);
    return entry === undefined ? null : entry.context;
  }

  /** 除 exceptKey 外最早登记、且带 context 的窗口 key（'' = 没有） */
  firstOtherKey(exceptKey: string): string {
    let found: string = '';
    this.entries.forEach((entry: WindowEntry, key: string) => {
      if (found.length === 0 && key !== exceptKey && entry.context !== null) {
        found = key;
      }
    });
    return found;
  }

  // ---------------------------------------------------------------- 窗口对象

  setWindow(windowKey: string, win: window.Window | null): void {
    const entry: WindowEntry | undefined = this.entries.get(windowKey);
    if (entry !== undefined) {
      entry.win = win;
    }
  }

  /** 该窗口的主窗口对象（未登记 / 尚未取到为 null，调用方自行降级） */
  windowOf(windowKey: string): window.Window | null {
    const entry: WindowEntry | undefined = this.entries.get(windowKey);
    return entry === undefined ? null : entry.win;
  }

  // ---------------------------------------------------------------- 应用级前后台

  /** 窗口前后台（Ability.onForeground / onBackground 转发） */
  notifyWindowForeground(windowKey: string, foreground: boolean): void {
    const index: number = this.foregroundKeys.indexOf(windowKey);
    if (foreground && index < 0) {
      this.foregroundKeys.push(windowKey);
    } else if (!foreground && index >= 0) {
      this.foregroundKeys.splice(index, 1);
    } else {
      return;
    }
    this.onForegroundCountChanged();
  }

  isAppForeground(): boolean {
    return this.appForeground;
  }

  addAppVisibilityListener(listener: AppVisibilityListener): void {
    if (this.visibilityListeners.indexOf(listener) < 0) {
      this.visibilityListeners.push(listener);
    }
  }

  removeAppVisibilityListener(listener: AppVisibilityListener): void {
    const index: number = this.visibilityListeners.indexOf(listener);
    if (index >= 0) {
      this.visibilityListeners.splice(index, 1);
    }
  }

  private onForegroundCountChanged(): void {
    if (this.foregroundKeys.length > 0) {
      this.cancelBackgroundTimer();
      if (!this.appForeground) {
        this.setAppForeground(true);
      }
      return;
    }
    if (!this.appForeground || this.backgroundTimerId !== -1) {
      return;
    }
    if (this.entries.size <= 1) {
      // 单窗口：与改造前逐拍一致，立即转后台
      this.setAppForeground(false);
      return;
    }
    this.backgroundTimerId = this.scheduler.schedule(APP_BACKGROUND_SETTLE_MS, () => {
      this.backgroundTimerId = -1;
      if (this.foregroundKeys.length === 0 && this.appForeground) {
        this.setAppForeground(false);
      }
    });
  }

  private cancelBackgroundTimer(): void {
    if (this.backgroundTimerId !== -1) {
      this.scheduler.cancel(this.backgroundTimerId);
      this.backgroundTimerId = -1;
    }
  }

  private setAppForeground(foreground: boolean): void {
    this.appForeground = foreground;
    Logger.info(`应用${foreground ? '转前台' : '转后台'}（前台窗口 ${this.foregroundKeys.length} 个）`, LOG_TAG);
    const listeners: AppVisibilityListener[] = this.visibilityListeners.slice();
    for (const listener of listeners) {
      try {
        listener(foreground);
      } catch (err) {
        Logger.error(`前后台监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
      }
    }
  }

  // ---------------------------------------------------------------- 窗口获焦

  /** 订阅某窗口获焦；返回注销函数 */
  addWindowActiveListener(windowKey: string, listener: WindowActiveListener): () => void {
    let list: WindowActiveListener[] | undefined = this.activeListeners.get(windowKey);
    if (list === undefined) {
      list = [];
      this.activeListeners.set(windowKey, list);
    }
    list.push(listener);
    return (): void => {
      const current: WindowActiveListener[] | undefined = this.activeListeners.get(windowKey);
      if (current === undefined) {
        return;
      }
      const index: number = current.indexOf(listener);
      if (index >= 0) {
        current.splice(index, 1);
      }
    };
  }

  /** 窗口获焦（windowStageEvent ACTIVE 转发） */
  notifyWindowActive(windowKey: string): void {
    const list: WindowActiveListener[] | undefined = this.activeListeners.get(windowKey);
    if (list === undefined) {
      return;
    }
    for (const listener of list.slice()) {
      try {
        listener();
      } catch (err) {
        Logger.error(`窗口获焦监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
      }
    }
  }

  // ---------------------------------------------------------------- 打开请求（onNewWant）

  /**
   * 订阅某窗口的打开请求（每窗口一个终端页订阅者，后订阅顶替）。
   * 订阅时补投先前积压的请求（onNewWant 早于页面就绪的情形）。返回注销函数。
   */
  setOpenRequestListener(windowKey: string, listener: OpenRequestListener): () => void {
    this.openListeners.set(windowKey, listener);
    const pending: TerminalOpenRequest[] | undefined = this.pendingOpen.get(windowKey);
    if (pending !== undefined) {
      this.pendingOpen.delete(windowKey);
      for (const request of pending) {
        listener(request);
      }
    }
    return (): void => {
      if (this.openListeners.get(windowKey) === listener) {
        this.openListeners.delete(windowKey);
      }
    };
  }

  postOpenRequest(windowKey: string, request: TerminalOpenRequest): void {
    const listener: OpenRequestListener | undefined = this.openListeners.get(windowKey);
    if (listener !== undefined) {
      listener(request);
      return;
    }
    let pending: TerminalOpenRequest[] | undefined = this.pendingOpen.get(windowKey);
    if (pending === undefined) {
      pending = [];
      this.pendingOpen.set(windowKey, pending);
    }
    pending.push(request);
  }
}
