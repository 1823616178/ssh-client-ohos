/**
 * 后台保活单元测试（任务 P1，DESIGN §7.5）。
 *
 * 三层各测各的：
 *   1. BackgroundPolicy —— 纯逻辑状态机，逐分支断言「什么时候申请长时任务、
 *      什么时候还电、被系统收走怎么降级、什么时候优雅断开」；
 *   2. isNetworkSwitch —— 切网判据（netId / 承载类型变化才算，capability 抖动不算）；
 *   3. BackgroundKeepAlive —— 外壳把动作翻译成网关调用（全部注入 fake，
 *      定时器手动触发，不真等分钟）；
 *   4. SettingsViewModel —— 设置页「息屏 N 分钟」的档位换算与副标题文案。
 *
 * 重点覆盖的是「dataTransfer 长时任务会被系统因低速挂起/取消」这条现实路径：
 * 挂起不断连接、低速取消先退避重申（最多 3 次）、重申耗尽才走宽限降级链、
 * 宽限到期优雅断开、回前台原地恢复；外加「息屏兜底申请长时任务」一路
 * （不能假定息屏一定伴随 onBackground，否则那些机型上就是零保活 + 静默失联）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  BackgroundPolicy,
  BackgroundSettings,
  BgAction,
  BgActionKind,
  CANCEL_REASON_DATA_TRANSFER_LOW_SPEED,
  TASK_RETRY_DELAYS_SEC,
  REASON_BACKGROUND_DISABLED,
  REASON_MEMORY_CRITICAL,
  REASON_SCREEN_OFF,
  REASON_TASK_LOST
} from '../main/ets/service/background/BackgroundPolicy';
import {
  BackgroundKeepAlive,
  ContinuousTaskGateway,
  PolicyScheduler,
  ScreenWatcherGateway,
  TransientTaskGateway
} from '../main/ets/service/background/BackgroundKeepAlive';
import { SessionControl, SessionCountListener } from '../main/ets/service/background/SessionControl';
import { isNetworkSwitch, NetSnapshot, UNKNOWN_NET } from '../main/ets/service/NetworkWatcher';
import {
  backgroundSummary,
  SCREEN_OFF_OPTIONS,
  screenOffLabels,
  screenOffMinutesOf,
  screenOffOptionIndex
} from '../main/ets/viewmodel/SettingsViewModel';

// ---------- 断言辅助 ----------

function kinds(actions: BgAction[]): string[] {
  const result: string[] = [];
  for (const item of actions) {
    result.push(item.kind as string);
  }
  return result;
}

function has(actions: BgAction[], kind: BgActionKind): boolean {
  for (const item of actions) {
    if (item.kind === kind) {
      return true;
    }
  }
  return false;
}

function find(actions: BgAction[], kind: BgActionKind): BgAction | null {
  for (const item of actions) {
    if (item.kind === kind) {
      return item;
    }
  }
  return null;
}

function settings(keepAlive: boolean, screenOffMinutes: number): BackgroundSettings {
  return { keepAliveInBackground: keepAlive, screenOffDisconnectMinutes: screenOffMinutes };
}

/** 造一个「后台 + 有会话 + 长时任务已生效」的策略机（多数用例的起点） */
function backgroundWithTask(screenOffMinutes: number = 0): BackgroundPolicy {
  const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, screenOffMinutes));
  policy.onSessionCountChanged(2);
  policy.onBackground();
  policy.onTaskGranted();
  return policy;
}

// ---------- fake 网关 ----------

class FakeContinuousTask implements ContinuousTaskGateway {
  startCount: number = 0;
  stopCount: number = 0;
  /** 申请是否成功（模拟权限缺失/系统拒绝） */
  grant: boolean = true;
  private onCancel: ((reason: number) => void) | null = null;
  private onSuspend: ((reason: number) => void) | null = null;
  private onActive: (() => void) | null = null;

  start(onGranted: () => void, onFailed: () => void): void {
    this.startCount++;
    if (this.grant) {
      onGranted();
    } else {
      onFailed();
    }
  }

  stop(): void {
    this.stopCount++;
  }

  observe(onCancel: (reason: number) => void, onSuspend: (reason: number) => void,
    onActive: () => void): void {
    this.onCancel = onCancel;
    this.onSuspend = onSuspend;
    this.onActive = onActive;
  }

  unobserve(): void {
    this.onCancel = null;
    this.onSuspend = null;
    this.onActive = null;
  }

  /** 测试脚本：模拟系统回调 */
  emitCancel(reason: number): void {
    this.onCancel?.(reason);
  }

  emitSuspend(reason: number): void {
    this.onSuspend?.(reason);
  }

  emitActive(): void {
    this.onActive?.();
  }
}

class FakeTransientTask implements TransientTaskGateway {
  requestCount: number = 0;
  cancelCount: number = 0;
  /** 系统给的宽限秒数；0 = 拿不到 */
  granted: number = 5;

  request(_reason: string): number {
    this.requestCount++;
    return this.granted;
  }

  cancel(): void {
    this.cancelCount++;
  }
}

class FakeScreenWatcher implements ScreenWatcherGateway {
  private offCb: (() => void) | null = null;
  private onCb: (() => void) | null = null;

  start(onScreenOff: () => void, onScreenOn: () => void): void {
    this.offCb = onScreenOff;
    this.onCb = onScreenOn;
  }

  stop(): void {
    this.offCb = null;
    this.onCb = null;
  }

  screenOff(): void {
    this.offCb?.();
  }

  screenOn(): void {
    this.onCb?.();
  }
}

class FakeSessions implements SessionControl {
  count: number = 1;
  quiet: boolean = false;
  probeCount: number = 0;
  suspendCount: number = 0;
  resumeCount: number = 0;
  lastReason: string = '';
  private listeners: SessionCountListener[] = [];

  activeSessionCount(): number {
    return this.count;
  }

  setQuiet(quiet: boolean): void {
    this.quiet = quiet;
  }

  notifyNetworkChanged(): number {
    this.probeCount++;
    return this.count;
  }

  suspendAllForPolicy(reason: string): number {
    this.suspendCount++;
    this.lastReason = reason;
    this.count = 0;
    return 1;
  }

  resumeAllSuspended(): number {
    this.resumeCount++;
    this.count = 1;
    return 1;
  }

  addSessionCountListener(listener: SessionCountListener): void {
    this.listeners.push(listener);
  }

  removeSessionCountListener(listener: SessionCountListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  /** 测试脚本：模拟会话增删触发通知 */
  emitChange(count: number): void {
    this.count = count;
    for (const listener of this.listeners) {
      listener();
    }
  }
}

interface FakeTimer {
  id: number;
  delaySec: number;
  task: () => void;
  cancelled: boolean;
  fired: boolean;
}

class ManualScheduler implements PolicyScheduler {
  private nextId: number = 1;
  readonly timers: FakeTimer[] = [];

  schedule(delaySec: number, task: () => void): number {
    const id: number = this.nextId++;
    this.timers.push({ id: id, delaySec: delaySec, task: task, cancelled: false, fired: false });
    return id;
  }

  cancel(timerId: number): void {
    for (const t of this.timers) {
      if (t.id === timerId) {
        t.cancelled = true;
      }
    }
  }

  get pendingCount(): number {
    let n: number = 0;
    for (const t of this.timers) {
      if (!t.cancelled && !t.fired) {
        n++;
      }
    }
    return n;
  }

  /** 触发最早的未决定时器；false = 没有可跑的 */
  fireNext(): boolean {
    for (const t of this.timers) {
      if (!t.cancelled && !t.fired) {
        t.fired = true;
        t.task();
        return true;
      }
    }
    return false;
  }

  lastPendingDelay(): number {
    for (let i: number = this.timers.length - 1; i >= 0; i--) {
      const t: FakeTimer = this.timers[i];
      if (!t.cancelled && !t.fired) {
        return t.delaySec;
      }
    }
    return -1;
  }
}

class ShellEnv {
  readonly task: FakeContinuousTask = new FakeContinuousTask();
  readonly transient: FakeTransientTask = new FakeTransientTask();
  readonly screen: FakeScreenWatcher = new FakeScreenWatcher();
  readonly sessions: FakeSessions = new FakeSessions();
  readonly scheduler: ManualScheduler = new ManualScheduler();
  readonly keepAlive: BackgroundKeepAlive;

  constructor(keepAliveInBackground: boolean = true, screenOffMinutes: number = 0) {
    this.keepAlive = new BackgroundKeepAlive({
      continuousTask: this.task,
      transientTask: this.transient,
      screenWatcher: this.screen,
      sessions: this.sessions,
      scheduler: this.scheduler,
      readSettings: (): BackgroundSettings => settings(keepAliveInBackground, screenOffMinutes)
    });
    this.keepAlive.start();
  }
}

export default function backgroundKeepAliveTest() {

  // ================================================================ 策略机：前后台

  describe('BackgroundPolicyLifecycleTest', () => {
    it('切后台有会话时申请长时任务并静默', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onSessionCountChanged(1);
      const actions: BgAction[] = policy.onBackground();
      expect(kinds(actions).join(',')).assertEqual('quietOn,startContinuousTask');
      expect(policy.taskState).assertEqual('requested');
      policy.onTaskGranted();
      expect(policy.taskState).assertEqual('active');
    });

    it('切后台无会话时只静默不申请', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      const actions: BgAction[] = policy.onBackground();
      expect(kinds(actions).join(',')).assertEqual('quietOn');
      expect(policy.taskState).assertEqual('none');
    });

    it('关掉后台保活时切后台走宽限而不是硬扛', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(false, 0));
      policy.onSessionCountChanged(1);
      const actions: BgAction[] = policy.onBackground();
      expect(kinds(actions).join(',')).assertEqual('quietOn,requestGrace');
      expect(policy.isGraceActive).assertTrue();
      expect(policy.taskState).assertEqual('none');

      const expired: BgAction[] = policy.onGraceExpired();
      expect(has(expired, 'suspendSessions')).assertTrue();
      expect(find(expired, 'suspendSessions')?.reason).assertEqual(REASON_BACKGROUND_DISABLED);
      expect(policy.isSuspended).assertTrue();
    });

    it('回前台还电解除静默并做一次切网收敛', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      const actions: BgAction[] = policy.onForeground();
      expect(kinds(actions).join(',')).assertEqual('stopContinuousTask,quietOff,probeNetwork');
      expect(policy.taskState).assertEqual('none');
      expect(policy.isForeground).assertTrue();
    });

    it('回前台恢复被挂起的会话而不是只探测', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(false, 0));
      policy.onSessionCountChanged(1);
      policy.onBackground();
      policy.onGraceExpired();
      expect(policy.isSuspended).assertTrue();

      const actions: BgAction[] = policy.onForeground();
      expect(has(actions, 'resumeSessions')).assertTrue();
      expect(has(actions, 'probeNetwork')).assertFalse(); // 恢复本身就会重连，不必再探
      expect(policy.isSuspended).assertFalse();
    });

    it('迟到的长时任务批复在前台立刻还电', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onSessionCountChanged(1);
      policy.onBackground();
      policy.onForeground(); // 系统还没批下来，用户已经回了前台
      const actions: BgAction[] = policy.onTaskGranted();
      expect(has(actions, 'stopContinuousTask')).assertTrue();
      expect(policy.taskState).assertEqual('none');
    });

    it('前台不申请长时任务', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      expect(policy.onSessionCountChanged(3).length).assertEqual(0);
      expect(policy.taskState).assertEqual('none');
    });
  });

  // ================================================================ 策略机：会话数

  describe('BackgroundPolicySessionCountTest', () => {
    it('后台最后一个会话关掉立刻还电', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      const actions: BgAction[] = policy.onSessionCountChanged(0);
      expect(kinds(actions).join(',')).assertEqual('stopContinuousTask');
      expect(policy.taskState).assertEqual('none');
    });

    it('后台从零变有会话时补申请', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onBackground();
      expect(policy.taskState).assertEqual('none');
      const actions: BgAction[] = policy.onSessionCountChanged(1);
      expect(kinds(actions).join(',')).assertEqual('startContinuousTask');
    });

    it('会话数不变不重复动作', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      expect(policy.onSessionCountChanged(2).length).assertEqual(0);
      expect(policy.taskState).assertEqual('active');
    });

    it('已挂起时不因会话数变化重新申请', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(false, 0));
      policy.onSessionCountChanged(1);
      policy.onBackground();
      policy.onGraceExpired();
      const actions: BgAction[] = policy.onSessionCountChanged(2);
      expect(actions.length).assertEqual(0);
      expect(policy.taskState).assertEqual('none');
    });
  });

  // ================================================================ 策略机：长时任务降级链

  describe('BackgroundPolicyDegradeTest', () => {
    it('低速挂起不断连接只等恢复', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      const actions: BgAction[] = policy.onTaskSuspended();
      expect(actions.length).assertEqual(0);
      expect(policy.taskState).assertEqual('suspended');
      expect(policy.isSuspended).assertFalse(); // 会话没被断
      expect(policy.onTaskActive().length).assertEqual(0);
      expect(policy.taskState).assertEqual('active');
    });

    it('长时任务被取消转宽限再优雅断开', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      const cancelled: BgAction[] = policy.onTaskCancelled();
      expect(kinds(cancelled).join(',')).assertEqual('requestGrace');
      expect(policy.taskState).assertEqual('none');

      const expired: BgAction[] = policy.onGraceExpired();
      expect(has(expired, 'suspendSessions')).assertTrue();
      expect(find(expired, 'suspendSessions')?.reason).assertEqual(REASON_TASK_LOST);
      expect(policy.isSuspended).assertTrue();
    });

    it('宽限期内长时任务回来则撤销宽限', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      policy.onTaskCancelled();
      expect(policy.isGraceActive).assertTrue();
      const actions: BgAction[] = policy.onTaskGranted();
      expect(kinds(actions).join(',')).assertEqual('cancelGrace');
      expect(policy.isGraceActive).assertFalse();
      expect(policy.isSuspended).assertFalse();
    });

    it('申请失败直接进降级链', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onSessionCountChanged(1);
      policy.onBackground();
      const actions: BgAction[] = policy.onTaskFailed();
      expect(kinds(actions).join(',')).assertEqual('requestGrace');
    });

    it('前台被取消不惊动会话', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onSessionCountChanged(1);
      expect(policy.onTaskCancelled().length).assertEqual(0);
      expect(policy.isGraceActive).assertFalse();
    });

    it('低速取消退避重申而不是立刻断开', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      const first: BgAction[] = policy.onTaskCancelled(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
      expect(kinds(first).join(',')).assertEqual('scheduleTaskRetry');
      expect(find(first, 'scheduleTaskRetry')?.delaySec).assertEqual(TASK_RETRY_DELAYS_SEC[0]);
      expect(policy.isTaskRetryPending).assertTrue();
      expect(policy.isGraceActive).assertFalse();
      expect(policy.isSuspended).assertFalse();

      const retry: BgAction[] = policy.onTaskRetryTimerExpired();
      expect(kinds(retry).join(',')).assertEqual('startContinuousTask');
      expect(policy.taskState).assertEqual('requested');
      expect(policy.isTaskRetryPending).assertFalse();
    });

    it('重申次数用尽后回到宽限降级链', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      for (let i: number = 0; i < TASK_RETRY_DELAYS_SEC.length; i++) {
        policy.onTaskCancelled(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
        policy.onTaskRetryTimerExpired();
        policy.onTaskGranted();
      }
      expect(policy.taskRetryCount).assertEqual(TASK_RETRY_DELAYS_SEC.length);
      const actions: BgAction[] = policy.onTaskCancelled(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
      expect(kinds(actions).join(',')).assertEqual('requestGrace');
    });

    it('非低速取消不重申直接降级', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      // 用户在通知栏手动取消（reason=1）：他表达的是「别占着」，重申等于跟用户对着干
      expect(kinds(policy.onTaskCancelled(1)).join(',')).assertEqual('requestGrace');
      expect(policy.isTaskRetryPending).assertFalse();
    });

    it('回前台撤销重申并清零次数', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      policy.onTaskCancelled(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
      const actions: BgAction[] = policy.onForeground();
      expect(has(actions, 'cancelTaskRetry')).assertTrue();
      expect(policy.isTaskRetryPending).assertFalse();
      expect(policy.taskRetryCount).assertEqual(0);
      expect(policy.isSuspended).assertFalse();
    });

    it('重申期间会话清零则撤销重申并还电', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      policy.onTaskCancelled(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
      const actions: BgAction[] = policy.onSessionCountChanged(0);
      expect(has(actions, 'cancelTaskRetry')).assertTrue();
      expect(policy.onTaskRetryTimerExpired().length).assertEqual(0);
    });

    it('宽限到期两次只断一次', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      policy.onTaskCancelled();
      expect(policy.onGraceExpired().length > 0).assertTrue();
      expect(policy.onGraceExpired().length).assertEqual(0);
    });
  });

  // ================================================================ 策略机：息屏与内存

  describe('BackgroundPolicyScreenTest', () => {
    it('息屏策略关闭时不起倒计时', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask(0);
      expect(policy.onScreenOff().length).assertEqual(0);
      expect(policy.isScreenOffTimerArmed).assertFalse();
    });

    it('息屏N分钟起倒计时到期优雅断开', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask(3);
      const armed: BgAction[] = policy.onScreenOff();
      expect(kinds(armed).join(',')).assertEqual('armScreenOffTimer');
      expect(find(armed, 'armScreenOffTimer')?.delaySec).assertEqual(180);

      const expired: BgAction[] = policy.onScreenOffTimerExpired();
      expect(find(expired, 'suspendSessions')?.reason).assertEqual(REASON_SCREEN_OFF);
      expect(has(expired, 'stopContinuousTask')).assertTrue();
    });

    it('亮屏撤销未到期的倒计时', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask(3);
      policy.onScreenOff();
      const actions: BgAction[] = policy.onScreenOn();
      expect(kinds(actions).join(',')).assertEqual('cancelScreenOffTimer');
      expect(policy.isScreenOffTimerArmed).assertFalse();
      // 撤销后再亮屏不重复动作
      expect(policy.onScreenOn().length).assertEqual(0);
    });

    it('内存告急优雅断开并还电', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask(3);
      policy.onScreenOff();
      const actions: BgAction[] = policy.onMemoryCritical();
      expect(has(actions, 'cancelScreenOffTimer')).assertTrue();
      expect(find(actions, 'suspendSessions')?.reason).assertEqual(REASON_MEMORY_CRITICAL);
      expect(has(actions, 'stopContinuousTask')).assertTrue();
      expect(policy.isSuspended).assertTrue();
    });

    it('息屏时即使还在前台也申请长时任务兜底', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onSessionCountChanged(1);
      // 没有 onBackground：模拟息屏但生命周期回调不来的机型
      const actions: BgAction[] = policy.onScreenOff();
      expect(kinds(actions).join(',')).assertEqual('startContinuousTask');
      expect(policy.taskState).assertEqual('requested');

      policy.onTaskGranted();
      expect(policy.taskState).assertEqual('active'); // 前台但息屏，不该被立刻还回去

      const lit: BgAction[] = policy.onScreenOn();
      expect(kinds(lit).join(',')).assertEqual('stopContinuousTask');
      expect(policy.taskState).assertEqual('none');
    });

    it('息屏兜底不与切后台重复申请', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(true, 0));
      policy.onSessionCountChanged(1);
      policy.onScreenOff();
      policy.onTaskGranted();
      const actions: BgAction[] = policy.onBackground();
      expect(kinds(actions).join(',')).assertEqual('quietOn');
      expect(policy.taskState).assertEqual('active');
    });

    it('关掉后台保活时息屏不申请长时任务', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(false, 0));
      policy.onSessionCountChanged(1);
      expect(policy.onScreenOff().length).assertEqual(0);
      expect(policy.taskState).assertEqual('none');
    });

    it('切网在有会话时才收敛', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      expect(kinds(policy.onNetworkChanged()).join(',')).assertEqual('probeNetwork');
      policy.onSessionCountChanged(0);
      expect(policy.onNetworkChanged().length).assertEqual(0);
    });
  });

  // ================================================================ 策略机：设置变更

  describe('BackgroundPolicySettingsTest', () => {
    it('后台关掉保活开关立即还电并走宽限', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask();
      const actions: BgAction[] = policy.onSettingsChanged(settings(false, 0));
      expect(kinds(actions).join(',')).assertEqual('stopContinuousTask,requestGrace');
    });

    it('宽限进行中打开保活开关不抢跑', 0, () => {
      const policy: BackgroundPolicy = new BackgroundPolicy(settings(false, 0));
      policy.onSessionCountChanged(1);
      policy.onBackground();
      policy.onTaskFailed(); // 宽限中
      const actions: BgAction[] = policy.onSettingsChanged(settings(true, 0));
      // 宽限还挂着时不抢跑，等宽限撤销后由前后台切换重新申请
      expect(has(actions, 'startContinuousTask')).assertFalse();
    });

    it('息屏中改分钟数按新值重新起算', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask(3);
      policy.onScreenOff();
      const actions: BgAction[] = policy.onSettingsChanged(settings(true, 10));
      expect(kinds(actions).join(',')).assertEqual('cancelScreenOffTimer,armScreenOffTimer');
      expect(find(actions, 'armScreenOffTimer')?.delaySec).assertEqual(600);
    });

    it('息屏中关掉息屏策略撤销倒计时', 0, () => {
      const policy: BackgroundPolicy = backgroundWithTask(3);
      policy.onScreenOff();
      const actions: BgAction[] = policy.onSettingsChanged(settings(true, 0));
      expect(kinds(actions).join(',')).assertEqual('cancelScreenOffTimer');
    });
  });

  // ================================================================ 切网判据

  describe('NetworkSwitchTest', () => {
    it('首次拿到默认网算切换', 0, () => {
      const next: NetSnapshot = { netId: 100, bearerType: 1 };
      expect(isNetworkSwitch(UNKNOWN_NET, next)).assertTrue();
    });

    it('netId或承载类型变化算切换', 0, () => {
      const wifi: NetSnapshot = { netId: 100, bearerType: 1 };
      const cellularSameId: NetSnapshot = { netId: 100, bearerType: 0 };
      const otherWifi: NetSnapshot = { netId: 101, bearerType: 1 };
      expect(isNetworkSwitch(wifi, cellularSameId)).assertTrue();
      expect(isNetworkSwitch(wifi, otherWifi)).assertTrue();
    });

    it('同一张网抖动不算切换', 0, () => {
      const wifi: NetSnapshot = { netId: 100, bearerType: 1 };
      expect(isNetworkSwitch(wifi, { netId: 100, bearerType: 1 })).assertFalse();
    });

    it('无效上报忽略', 0, () => {
      const wifi: NetSnapshot = { netId: 100, bearerType: 1 };
      expect(isNetworkSwitch(wifi, { netId: -1, bearerType: 1 })).assertFalse();
    });

    it('同一张网承载从未知补成已知不算切换', 0, () => {
      // 真机实测：启动时 netAvailable 先到（承载未知 -1），随后 netCapabilitiesChange
      // 才补上 bearer=WIFI，这一步不该被当成切网去踢会话
      const unknownBearer: NetSnapshot = { netId: 142, bearerType: -1 };
      expect(isNetworkSwitch(unknownBearer, { netId: 142, bearerType: 1 })).assertFalse();
      // 但换了 netId 仍然算切换，哪怕承载未知
      expect(isNetworkSwitch(unknownBearer, { netId: 143, bearerType: -1 })).assertTrue();
    });
  });

  // ================================================================ 设置页档位换算

  describe('SettingsScreenOffOptionTest', () => {
    it('关闭与非法值都归不断开档', 0, () => {
      expect(screenOffOptionIndex(0)).assertEqual(0);
      expect(screenOffOptionIndex(-5)).assertEqual(0);
      expect(screenOffMinutesOf(0)).assertEqual(0);
    });

    it('档位与分钟数往返一致', 0, () => {
      for (let i: number = 0; i < SCREEN_OFF_OPTIONS.length; i++) {
        expect(screenOffOptionIndex(screenOffMinutesOf(i))).assertEqual(i);
      }
      expect(screenOffLabels().length).assertEqual(SCREEN_OFF_OPTIONS.length);
    });

    it('非档位分钟数取最接近档', 0, () => {
      expect(screenOffMinutesOf(screenOffOptionIndex(7))).assertEqual(5);
      expect(screenOffMinutesOf(screenOffOptionIndex(20))).assertEqual(15);
      expect(screenOffMinutesOf(screenOffOptionIndex(999))).assertEqual(60);
    });

    it('越界下标按不断开处理', 0, () => {
      expect(screenOffMinutesOf(-1)).assertEqual(0);
      expect(screenOffMinutesOf(SCREEN_OFF_OPTIONS.length)).assertEqual(0);
    });

    it('副标题如实反映当前设置', 0, () => {
      expect(backgroundSummary(true, 0)).assertEqual('切到后台后继续保持连接');
      expect(backgroundSummary(false, 0)).assertEqual('切到后台即优雅断开，回到应用自动重连');
      expect(backgroundSummary(true, 15)).assertEqual('切到后台后继续保持连接；息屏满 15 分钟断开');
    });
  });

  // ================================================================ 外壳：动作 → 网关

  describe('BackgroundKeepAliveShellTest', () => {
    it('切后台申请长时任务回前台释放', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.keepAlive.notifyBackground();
      expect(env.task.startCount).assertEqual(1);
      expect(env.sessions.quiet).assertTrue();

      env.keepAlive.notifyForeground();
      expect(env.task.stopCount).assertEqual(1);
      expect(env.sessions.quiet).assertFalse();
      expect(env.sessions.probeCount).assertEqual(1); // 回前台做一次切网收敛
    });

    it('长时任务被低速取消先退避重申再走宽限窗口断开', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.keepAlive.notifyBackground();
      expect(env.task.startCount).assertEqual(1);

      // 低速取消 xN：每次都只起重申倒计时，连接一根没断
      for (let i: number = 0; i < TASK_RETRY_DELAYS_SEC.length; i++) {
        env.task.emitCancel(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
        expect(env.transient.requestCount).assertEqual(0);
        expect(env.scheduler.lastPendingDelay()).assertEqual(TASK_RETRY_DELAYS_SEC[i]);
        env.scheduler.fireNext();
        expect(env.task.startCount).assertEqual(i + 2); // 真的又申请了一次
        expect(env.sessions.suspendCount).assertEqual(0);
      }

      // 再一次低速取消：重申额度用尽，回到宽限降级链
      env.task.emitCancel(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
      expect(env.transient.requestCount).assertEqual(1);
      expect(env.sessions.suspendCount).assertEqual(0); // 还没到期，先不断

      env.scheduler.fireNext();
      expect(env.sessions.suspendCount).assertEqual(1);
      expect(env.sessions.lastReason).assertEqual(REASON_TASK_LOST);

      env.keepAlive.notifyForeground();
      expect(env.sessions.resumeCount).assertEqual(1);
    });

    it('重申倒计时在回前台时被撤销', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.keepAlive.notifyBackground();
      env.task.emitCancel(CANCEL_REASON_DATA_TRANSFER_LOW_SPEED);
      expect(env.scheduler.pendingCount).assertEqual(1);

      env.keepAlive.notifyForeground();
      expect(env.scheduler.pendingCount).assertEqual(0);
      expect(env.sessions.suspendCount).assertEqual(0);
    });

    it('息屏未走onBackground时也申请长时任务', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      // 注意：全程没调 notifyBackground，模拟「息屏但生命周期回调没来」的机型
      env.screen.screenOff();
      expect(env.task.startCount).assertEqual(1);

      env.screen.screenOn();
      expect(env.task.stopCount).assertEqual(1); // 前台且亮屏，立刻还电
      expect(env.sessions.suspendCount).assertEqual(0);
    });

    it('低速挂起不断连接', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.keepAlive.notifyBackground();
      env.task.emitSuspend(4);
      expect(env.sessions.suspendCount).assertEqual(0);
      expect(env.transient.requestCount).assertEqual(0);
      env.task.emitActive();
      expect(env.sessions.suspendCount).assertEqual(0);
    });

    it('拿不到宽限窗口就立刻优雅断开', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.transient.granted = 0; // 系统不给宽限
      env.keepAlive.notifyBackground();
      env.task.emitCancel(2);
      // 不拖延：进程随时会被冻结，拖延只会变成静默失联
      expect(env.sessions.suspendCount).assertEqual(1);
    });

    it('长时任务申请失败直接降级', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.task.grant = false;
      env.keepAlive.notifyBackground();
      expect(env.task.startCount).assertEqual(1);
      expect(env.transient.requestCount).assertEqual(1);
    });

    it('息屏倒计时到期断开亮屏则撤销', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 2);
      env.keepAlive.notifyBackground();
      env.screen.screenOff();
      expect(env.scheduler.lastPendingDelay()).assertEqual(120);

      env.screen.screenOn();
      expect(env.scheduler.pendingCount).assertEqual(0);
      expect(env.sessions.suspendCount).assertEqual(0);

      env.screen.screenOff();
      env.scheduler.fireNext();
      expect(env.sessions.suspendCount).assertEqual(1);
      expect(env.sessions.lastReason).assertEqual(REASON_SCREEN_OFF);
    });

    it('后台会话清零自动还电', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.keepAlive.notifyBackground();
      expect(env.task.startCount).assertEqual(1);
      env.sessions.emitChange(0); // 用户在后台关掉了最后一个会话
      expect(env.task.stopCount).assertEqual(1);
    });

    it('内存告急优雅断开', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 0);
      env.keepAlive.notifyBackground();
      env.keepAlive.notifyMemoryCritical();
      expect(env.sessions.suspendCount).assertEqual(1);
      expect(env.sessions.lastReason).assertEqual(REASON_MEMORY_CRITICAL);
      expect(env.task.stopCount).assertEqual(1);
    });

    it('stop幂等且释放全部占用', 0, () => {
      const env: ShellEnv = new ShellEnv(true, 2);
      env.keepAlive.notifyBackground();
      env.screen.screenOff();
      env.keepAlive.stop();
      expect(env.task.stopCount >= 1).assertTrue();
      expect(env.scheduler.pendingCount).assertEqual(0);
      env.keepAlive.stop(); // 幂等
    });
  });
}
