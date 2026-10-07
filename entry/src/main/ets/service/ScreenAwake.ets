/**
 * 终端页屏幕常亮（DESIGN §7.5 的上游一环）。
 *
 * 为什么要有这个文件：§7.5 那条降级链处理的是「已经息屏/切后台之后怎么办」，
 * 但用户抱怨的「挂着看日志，走开一会儿回来连接断了」其实早一步就注定了——
 * 系统自动息屏 → 应用切后台 → dataTransfer 长时任务因空闲 SSH 低速被回收 → 优雅断开。
 * 最省事也最有效的一刀是**不让它息屏**：终端页在前台且有活跃会话时把窗口标记为常亮。
 * 这是终端类应用的通行做法（用户明确在等远端输出，屏幕灭掉毫无意义）。
 *
 * 分层同 §7.5 的纪律：判断是纯函数 `shouldKeepScreenOn`（可单测），
 * 系统 API 只在 `ProductionScreenAwakeGateway` 一处落地，单测整套换 fake。
 *
 * 状态来源三处，任一变化都重算一次：
 *   - 终端页可见性：TerminalPage 的 aboutToAppear / aboutToDisappear；
 *   - 应用前后台：EntryAbility 的 onForeground / onBackground；
 *   - 活跃会话数：SessionManager 的会话数监听（与 BackgroundKeepAlive 同一个口）。
 *
 * 常亮标记只是「阻止系统自动息屏」，用户按电源键照样能息屏，也不会阻止手动锁屏。
 */

import { window } from '@kit.ArkUI';
import { Logger } from '../common/utils/Logger';
import { KeepScreenOnMode, SettingsRepository } from '../repository/SettingsRepository';
import { SessionManager } from './SessionManager';
import { SessionControl, SessionCountListener } from './background/SessionControl';

const LOG_TAG: string = 'ScreenAwake';

/**
 * 是否该保持屏幕常亮（纯函数）。
 *
 * 只要不在终端页、或应用不在前台，一律不常亮：常亮是「用户正盯着这块终端」的表达，
 * 在主机列表页或后台占着它就是纯耗电。`session` 档再加一条「确实有会话在跑」。
 */
export function shouldKeepScreenOn(mode: KeepScreenOnMode, terminalVisible: boolean,
  foreground: boolean, activeSessions: number): boolean {
  if (!terminalVisible || !foreground) {
    return false;
  }
  if (mode === 'always') {
    return true;
  }
  if (mode === 'session') {
    return activeSessions > 0;
  }
  return false;
}

/** 常亮标记网关（生产实现走 window.setWindowKeepScreenOn，单测注入 fake） */
export interface ScreenAwakeGateway {
  apply(keepOn: boolean): void;
}

/** 设置读取（生产 = SettingsRepository） */
export type KeepScreenOnModeReader = () => KeepScreenOnMode;

export interface ScreenAwakeDeps {
  gateway?: ScreenAwakeGateway;
  sessions?: SessionControl;
  readMode?: KeepScreenOnModeReader;
}

export class ScreenAwake {
  private static instance: ScreenAwake | null = null;

  /** 生产单例（EntryAbility / TerminalPage 接线用）；单测请自行 new ScreenAwake(deps) */
  static get(): ScreenAwake {
    if (ScreenAwake.instance === null) {
      ScreenAwake.instance = new ScreenAwake();
    }
    return ScreenAwake.instance;
  }

  private readonly deps: ScreenAwakeDeps;
  private readonly readMode: KeepScreenOnModeReader;
  private gateway: ScreenAwakeGateway | null = null;
  private sessions: SessionControl | null = null;
  private started: boolean = false;
  private terminalVisible: boolean = false;
  private foreground: boolean = true;
  private mode: KeepScreenOnMode = 'session';
  private activeSessions: number = 0;
  /** 已下发给系统的状态（去重，避免每次会话事件都打一次窗口 API） */
  private applied: boolean = false;
  private readonly onSessionCountChanged: SessionCountListener = (): void => this.syncSessionCount();

  constructor(deps?: ScreenAwakeDeps) {
    this.deps = deps ?? {};
    this.readMode = this.deps.readMode ?? defaultModeReader;
  }

  /**
   * 起服务（EntryAbility.onWindowStageCreate）。windowStage 只用于取主窗口；
   * 注入了 fake 网关时可以不传（单测路径）。
   */
  start(windowStage?: window.WindowStage): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.gateway = this.deps.gateway ??
      (windowStage !== undefined ? new ProductionScreenAwakeGateway(windowStage) : null);
    this.sessions = this.deps.sessions ?? SessionManager.get();
    this.sessions?.addSessionCountListener(this.onSessionCountChanged);
    this.mode = this.readMode();
    this.syncSessionCount();
  }

  /** 停服务（EntryAbility.onWindowStageDestroy / onDestroy）：还回常亮标记并摘监听（幂等） */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.sessions?.removeSessionCountListener(this.onSessionCountChanged);
    this.terminalVisible = false;
    this.apply();
  }

  /** 终端页进入/离开（TerminalPage aboutToAppear / aboutToDisappear） */
  setTerminalVisible(visible: boolean): void {
    if (this.terminalVisible === visible) {
      return;
    }
    this.terminalVisible = visible;
    if (visible) {
      this.mode = this.readMode(); // 用户可能刚在设置页改过档
    }
    this.syncSessionCount();
  }

  /** 应用前后台（EntryAbility onForeground / onBackground） */
  setForeground(foreground: boolean): void {
    if (this.foreground === foreground) {
      return;
    }
    this.foreground = foreground;
    this.apply();
  }

  /** 设置页改了档位后调用 */
  refreshSettings(): void {
    this.mode = this.readMode();
    this.apply();
  }

  /** 只读观测（诊断与单测） */
  get isKeepingScreenOn(): boolean {
    return this.applied;
  }

  private syncSessionCount(): void {
    this.activeSessions = this.sessions?.activeSessionCount() ?? 0;
    this.apply();
  }

  private apply(): void {
    const desired: boolean =
      shouldKeepScreenOn(this.mode, this.terminalVisible, this.foreground, this.activeSessions);
    if (desired === this.applied) {
      return;
    }
    this.applied = desired;
    this.gateway?.apply(desired);
  }
}

// ------------------------------------------------------------------ 生产网关实现

function defaultModeReader(): KeepScreenOnMode {
  return SettingsRepository.getKeepScreenOnMode();
}

/**
 * 主窗口常亮标记。窗口句柄惰性取一次并缓存：`getMainWindow` 是异步的，
 * 而常亮的开关会随会话增删频繁翻转，每次都重新取窗口既慢又可能乱序。
 */
class ProductionScreenAwakeGateway implements ScreenAwakeGateway {
  private readonly stage: window.WindowStage;
  private mainWindow: window.Window | null = null;
  /** 最近一次期望值：句柄还没取到时先记下来，取到后按最新值补一次 */
  private desired: boolean = false;
  private resolving: boolean = false;

  constructor(stage: window.WindowStage) {
    this.stage = stage;
  }

  apply(keepOn: boolean): void {
    this.desired = keepOn;
    const win: window.Window | null = this.mainWindow;
    if (win !== null) {
      this.push(win, keepOn);
      return;
    }
    if (this.resolving) {
      return;
    }
    this.resolving = true;
    try {
      this.stage.getMainWindow().then((resolved: window.Window) => {
        this.resolving = false;
        this.mainWindow = resolved;
        this.push(resolved, this.desired); // 期间可能又翻转过，按最新值下发
      }).catch((err: Object) => {
        this.resolving = false;
        Logger.warn(`主窗口获取失败，屏幕常亮降级为不生效：${JSON.stringify(err)}`, LOG_TAG);
      });
    } catch (err) {
      this.resolving = false;
      Logger.warn(`窗口能力不可用：${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  private push(win: window.Window, keepOn: boolean): void {
    try {
      win.setWindowKeepScreenOn(keepOn).then(() => {
        Logger.info(`屏幕常亮=${keepOn}`, LOG_TAG);
      }).catch((err: Object) => {
        Logger.warn(`屏幕常亮设置失败：${JSON.stringify(err)}`, LOG_TAG);
      });
    } catch (err) {
      Logger.warn(`屏幕常亮能力不可用：${JSON.stringify(err)}`, LOG_TAG);
    }
  }
}
