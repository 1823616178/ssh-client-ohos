/**
 * 后台保活策略机（任务 P1，DESIGN §7.5）—— 纯逻辑，零系统 API。
 *
 * 为什么单独成文件：后台保活的难点不在调 API，而在「什么时候申请、什么时候还电、
 * 被系统收走以后怎么收场」这套判断。把它做成输入事件 → 输出动作的纯状态机，
 * 宿主单测就能逐分支断言（对齐 C4 SessionManager / T4 FrameSchedulerCore 的分层纪律）；
 * 系统 API 全部留在外壳 BackgroundKeepAlive.ets 里。
 *
 * 关键事实（决定了本状态机的形状）：HarmonyOS 的 dataTransfer 长时任务**不是拿到就永久有效**。
 * SDK 明确给了 `SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED` / `SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED`
 * （`@ohos.resourceschedule.backgroundTaskManager`）——低速会被系统挂起甚至取消，
 * 而空闲的 SSH 会话正是「低速」。所以保活不能只有「申请长时任务」一条路，必须有降级链：
 *
 *   长时任务 →（被挂起）等它自己回来 →（被取消/申请失败）短时任务宽限窗口
 *          → 宽限到期前**优雅断开并写明原因** → 回前台原地重连
 *
 * 这条链保证了 DESIGN 的承诺：「关闭后按策略优雅断开而不是静默失联」。
 * 断开一律走 SessionManager.suspendAllForPolicy()（只断连接、不销毁会话面孔与窗格绑定），
 * 回前台 resumeAllSuspended() 原地重连，用户看到的是「重连中」而不是「会话没了」。
 *
 * 用法（外壳侧）：
 *   const actions: BgAction[] = policy.onBackground();
 *   for (const action of actions) { ...按 action.kind 执行... }
 * 每个输入方法都返回本次要执行的动作序列（可能为空数组），顺序即执行顺序。
 */

/** 策略机要求外壳执行的动作种类 */
export type BgActionKind =
  'startContinuousTask' |   // 申请 dataTransfer 长时任务
  'stopContinuousTask' |    // 释放长时任务（还电）
  'requestGrace' |          // 申请短时任务宽限窗口（降级链入口）
  'cancelGrace' |           // 撤销宽限窗口
  'armScreenOffTimer' |     // 起息屏断开倒计时（delaySec 秒）
  'cancelScreenOffTimer' |  // 撤销息屏倒计时
  'suspendSessions' |       // 优雅断开全部会话（reason 进 SessionInfo.errorMessage）
  'resumeSessions' |        // 恢复被策略挂起的会话（回前台/亮屏）
  'quietOn' |               // 抑制 dirty 唤醒（画面不可见，别再逐帧重绘）
  'quietOff' |              // 解除抑制
  'probeNetwork';           // 通知会话层做切网收敛（退避提前重连 + established 主动探测）

/** 一条动作。delaySec / reason 只对特定 kind 有意义，其余取 0 / 空串 */
export interface BgAction {
  kind: BgActionKind;
  delaySec: number;
  reason: string;
}

/** 长时任务的生命周期状态（对应 backgroundTaskManager 的三个回调） */
export type ContinuousTaskState = 'none' | 'requested' | 'active' | 'suspended';

/** 策略机读到的设置快照（来源：SettingsRepository 的两个键，DESIGN §7.5） */
export interface BackgroundSettings {
  /** 「后台保持连接」，默认开 */
  keepAliveInBackground: boolean;
  /** 「息屏 N 分钟后断开」，0 = 关（默认） */
  screenOffDisconnectMinutes: number;
}

// 断开原因文案（会写进 SessionInfo.errorMessage 给用户看，故都带「回到应用后自动重连」的出路）
export const REASON_BACKGROUND_DISABLED: string = '已按「后台保持连接」设置断开，回到应用后自动重连';
export const REASON_TASK_LOST: string = '系统已回收后台保活，会话已断开，回到应用后自动重连';
export const REASON_SCREEN_OFF: string = '已按息屏断开策略断开，回到应用后自动重连';
export const REASON_MEMORY_CRITICAL: string = '系统内存告急，已优雅断开会话，回到应用后自动重连';

function action(kind: BgActionKind): BgAction {
  return { kind: kind, delaySec: 0, reason: '' };
}

function timerAction(kind: BgActionKind, delaySec: number): BgAction {
  return { kind: kind, delaySec: delaySec, reason: '' };
}

function suspendAction(reason: string): BgAction {
  return { kind: 'suspendSessions', delaySec: 0, reason: reason };
}

export class BackgroundPolicy {
  private settings: BackgroundSettings;
  private foreground: boolean = true;
  private screenOn: boolean = true;
  /** 活跃会话数（SessionManager.activeSessionCount 喂进来） */
  private sessions: number = 0;
  private task: ContinuousTaskState = 'none';
  private graceActive: boolean = false;
  /** 宽限到期时要写给用户的原因（宽限是「为什么要断」的延迟执行） */
  private graceReason: string = REASON_TASK_LOST;
  private screenOffTimerArmed: boolean = false;
  /** 会话是否已被本策略挂起（挂起期间不再申请长时任务，也不重复断开） */
  private suspended: boolean = false;

  constructor(settings: BackgroundSettings) {
    this.settings = settings;
  }

  // ---------------------------------------------------------------- 只读观测（单测与诊断）

  get taskState(): ContinuousTaskState {
    return this.task;
  }

  get isForeground(): boolean {
    return this.foreground;
  }

  get isSuspended(): boolean {
    return this.suspended;
  }

  get isGraceActive(): boolean {
    return this.graceActive;
  }

  get isScreenOffTimerArmed(): boolean {
    return this.screenOffTimerArmed;
  }

  // ---------------------------------------------------------------- 前后台

  /**
   * 回前台：还电（长时任务只在后台有意义）+ 撤掉一切倒计时 + 解除静默；
   * 被挂起过就原地恢复，否则做一次切网收敛——后台冻结期间网络很可能已经变了，
   * 与其让用户对着一个已死的画面敲键盘，不如立刻验证链路。
   */
  onForeground(): BgAction[] {
    this.foreground = true;
    const actions: BgAction[] = [];
    if (this.graceActive) {
      this.graceActive = false;
      actions.push(action('cancelGrace'));
    }
    if (this.task !== 'none') {
      this.task = 'none';
      actions.push(action('stopContinuousTask'));
    }
    if (this.screenOffTimerArmed) {
      this.screenOffTimerArmed = false;
      actions.push(action('cancelScreenOffTimer'));
    }
    actions.push(action('quietOff'));
    if (this.suspended) {
      this.suspended = false;
      actions.push(action('resumeSessions'));
    } else if (this.sessions > 0) {
      actions.push(action('probeNetwork'));
    }
    return actions;
  }

  /**
   * 切后台：先静默（画面不可见，dirty 唤醒纯属浪费），再按设置分流——
   * 允许保活就申请长时任务；不允许就走宽限窗口优雅收场（而不是等系统冻结后静默失联）。
   * 没有活跃会话时什么都不申请：后台白占资源是被系统整治的头号原因。
   */
  onBackground(): BgAction[] {
    this.foreground = false;
    const actions: BgAction[] = [action('quietOn')];
    if (this.sessions === 0 || this.suspended) {
      return actions;
    }
    if (!this.settings.keepAliveInBackground) {
      actions.push(this.beginGrace(REASON_BACKGROUND_DISABLED));
      return actions;
    }
    if (this.task === 'none') {
      this.task = 'requested';
      actions.push(action('startContinuousTask'));
    }
    return actions;
  }

  // ---------------------------------------------------------------- 会话数变化

  /**
   * 活跃会话数变化：后台且清零就立刻还电（用户已经把最后一个会话关了，
   * 再占着长时任务既费电又容易被系统盯上）；后台从零变有则补申请。
   */
  onSessionCountChanged(count: number): BgAction[] {
    const previous: number = this.sessions;
    this.sessions = count < 0 ? 0 : count;
    if (this.foreground || this.sessions === previous) {
      return [];
    }
    const actions: BgAction[] = [];
    if (this.sessions === 0) {
      if (this.graceActive) {
        this.graceActive = false;
        actions.push(action('cancelGrace'));
      }
      if (this.task !== 'none') {
        this.task = 'none';
        actions.push(action('stopContinuousTask'));
      }
      return actions;
    }
    if (!this.suspended && this.settings.keepAliveInBackground && this.task === 'none' &&
      !this.graceActive) {
      this.task = 'requested';
      actions.push(action('startContinuousTask'));
    }
    return actions;
  }

  // ---------------------------------------------------------------- 长时任务生命周期

  /**
   * 申请成功。注意迟到的成功回调：申请是异步的，用户可能在系统批下来之前就回了前台
   * （此时 onForeground 已经发过一次 stopContinuousTask，但那时任务还没真拿到手）。
   * 这里补一次释放，否则长时任务会一直挂着白耗电。
   */
  onTaskGranted(): BgAction[] {
    this.task = 'active';
    const actions: BgAction[] = [];
    if (this.graceActive) {
      this.graceActive = false;
      actions.push(action('cancelGrace'));
    }
    if (this.foreground || this.sessions === 0 || this.suspended) {
      this.task = 'none';
      actions.push(action('stopContinuousTask'));
    }
    return actions;
  }

  /**
   * 申请失败（权限缺失 / 系统拒绝）：直接进降级链，别假装还活着。
   */
  onTaskFailed(): BgAction[] {
    this.task = 'none';
    if (this.foreground || this.sessions === 0 || this.suspended || this.graceActive) {
      return [];
    }
    return [this.beginGrace(REASON_TASK_LOST)];
  }

  /**
   * 被系统挂起（典型：dataTransfer 低速）。**不断连接**——挂起是可恢复的，
   * 系统认为条件恢复后会回 continuousTaskActive。真正要收场的是 cancel。
   */
  onTaskSuspended(): BgAction[] {
    if (this.task !== 'none') {
      this.task = 'suspended';
    }
    return [];
  }

  /** 挂起后恢复 */
  onTaskActive(): BgAction[] {
    this.task = 'active';
    if (!this.graceActive) {
      return [];
    }
    this.graceActive = false;
    return [action('cancelGrace')];
  }

  /**
   * 被取消（低速取消 / 用户在通知栏取消 / 系统回收）：长时任务没了，
   * 进程随时会被冻结 → 用短时任务换一个宽限窗口，在窗口内优雅断开并写明原因。
   */
  onTaskCancelled(): BgAction[] {
    this.task = 'none';
    if (this.foreground || this.sessions === 0 || this.suspended || this.graceActive) {
      return [];
    }
    return [this.beginGrace(REASON_TASK_LOST)];
  }

  /** 宽限窗口到期：这是降级链的终点，优雅断开并还电 */
  onGraceExpired(): BgAction[] {
    if (!this.graceActive) {
      return [];
    }
    this.graceActive = false;
    return this.suspendNow(this.graceReason);
  }

  // ---------------------------------------------------------------- 息屏策略

  /**
   * 息屏：只有用户开了「息屏 N 分钟后断开」才起倒计时（默认 0 = 关）。
   * 前后台都计——用户息屏时会话在不在前台并无区别，他要的是「别整夜挂着」。
   */
  onScreenOff(): BgAction[] {
    this.screenOn = false;
    const minutes: number = this.settings.screenOffDisconnectMinutes;
    if (minutes <= 0 || this.suspended || this.screenOffTimerArmed || this.sessions === 0) {
      return [];
    }
    this.screenOffTimerArmed = true;
    return [timerAction('armScreenOffTimer', minutes * 60)];
  }

  /** 亮屏：倒计时未到就作废（用户回来了，就不该断他的会话） */
  onScreenOn(): BgAction[] {
    this.screenOn = true;
    if (!this.screenOffTimerArmed) {
      return [];
    }
    this.screenOffTimerArmed = false;
    return [action('cancelScreenOffTimer')];
  }

  /** 息屏倒计时到期：优雅断开并还电 */
  onScreenOffTimerExpired(): BgAction[] {
    if (!this.screenOffTimerArmed) {
      return [];
    }
    this.screenOffTimerArmed = false;
    return this.suspendNow(REASON_SCREEN_OFF);
  }

  // ---------------------------------------------------------------- 其他外部事件

  /**
   * 系统内存告急（AbilityStage.onMemoryLevel 的 CRITICAL）：与其等系统把进程杀了、
   * 留下一堆没发 disconnect 的半死连接，不如自己优雅收场并留下可重连的面孔。
   */
  onMemoryCritical(): BgAction[] {
    const actions: BgAction[] = [];
    if (this.graceActive) {
      this.graceActive = false;
      actions.push(action('cancelGrace'));
    }
    if (this.screenOffTimerArmed) {
      this.screenOffTimerArmed = false;
      actions.push(action('cancelScreenOffTimer'));
    }
    for (const item of this.suspendNow(REASON_MEMORY_CRITICAL)) {
      actions.push(item);
    }
    return actions;
  }

  /** 默认网变化：交给会话层做切网收敛（挂起中/无会话时无事可做） */
  onNetworkChanged(): BgAction[] {
    if (this.suspended || this.sessions === 0) {
      return [];
    }
    return [action('probeNetwork')];
  }

  /**
   * 设置变更（用户在设置页改了开关）：立刻按新设置纠正当前姿态，
   * 不必等下一次前后台切换。
   */
  onSettingsChanged(settings: BackgroundSettings): BgAction[] {
    const previous: BackgroundSettings = this.settings;
    this.settings = settings;
    const actions: BgAction[] = [];

    // 息屏倒计时：关掉就撤销；开着且此刻正息屏则补起一个
    if (settings.screenOffDisconnectMinutes <= 0 && this.screenOffTimerArmed) {
      this.screenOffTimerArmed = false;
      actions.push(action('cancelScreenOffTimer'));
    } else if (settings.screenOffDisconnectMinutes > 0 && !this.screenOn && !this.suspended &&
      this.sessions > 0 &&
      (!this.screenOffTimerArmed ||
        settings.screenOffDisconnectMinutes !== previous.screenOffDisconnectMinutes)) {
      // 改了分钟数就以新值重新起算（旧倒计时按新设置作废）
      if (this.screenOffTimerArmed) {
        actions.push(action('cancelScreenOffTimer'));
      }
      this.screenOffTimerArmed = true;
      actions.push(timerAction('armScreenOffTimer', settings.screenOffDisconnectMinutes * 60));
    }

    if (this.foreground || this.suspended || this.sessions === 0) {
      return actions;
    }
    if (!settings.keepAliveInBackground) {
      if (this.task !== 'none') {
        this.task = 'none';
        actions.push(action('stopContinuousTask'));
      }
      if (!this.graceActive) {
        actions.push(this.beginGrace(REASON_BACKGROUND_DISABLED));
      }
      return actions;
    }
    if (this.task === 'none' && !this.graceActive) {
      this.task = 'requested';
      actions.push(action('startContinuousTask'));
    }
    return actions;
  }

  // ---------------------------------------------------------------- 内部

  private beginGrace(reason: string): BgAction {
    this.graceActive = true;
    this.graceReason = reason;
    return action('requestGrace');
  }

  /** 优雅断开 + 还电（幂等：已挂起就什么都不做） */
  private suspendNow(reason: string): BgAction[] {
    if (this.suspended) {
      return [];
    }
    this.suspended = true;
    const actions: BgAction[] = [suspendAction(reason)];
    if (this.task !== 'none') {
      this.task = 'none';
      actions.push(action('stopContinuousTask'));
    }
    return actions;
  }
}
