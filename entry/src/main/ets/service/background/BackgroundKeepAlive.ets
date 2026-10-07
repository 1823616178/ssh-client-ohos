/**
 * 后台保活外壳（任务 P1，DESIGN §7.5）—— 系统 API 的唯一落点。
 *
 * 分工：判断全在 BackgroundPolicy（纯逻辑、可单测），本文件只做两件事——
 * 把系统事件喂给策略机，把策略机吐出的动作翻译成系统调用。所有系统能力
 * 都经窄接口注入（生产实现在本文件下半部），单测可以整套换成 fake。
 *
 * 接的系统能力：
 *   - `@ohos.resourceschedule.backgroundTaskManager`：dataTransfer 长时任务
 *     （start/stop + continuousTaskCancel/Suspend/Active 三个回调）与
 *     requestSuspendDelay 短时任务宽限；
 *   - `@ohos.commonEventManager`：SCREEN_OFF / SCREEN_ON（息屏断开策略）；
 *   - NetworkWatcher：默认网变化（切网收敛）。
 *
 * 纪律：任一系统能力不可用（权限缺失、设备不支持、API 抛错）都只记日志并降级，
 * 绝不阻断应用启动；日志只记状态与计数，不记任何会话内容。
 */

import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, Callback, commonEventManager } from '@kit.BasicServicesKit';
import { Logger } from '../../common/utils/Logger';
import { SettingsRepository } from '../../repository/SettingsRepository';
import { SessionManager } from '../SessionManager';
import { NetworkWatcher, NetSnapshot } from '../NetworkWatcher';
import { BackgroundPolicy, BackgroundSettings, BgAction } from './BackgroundPolicy';
import { SessionControl } from './SessionControl';

const LOG_TAG: string = 'BackgroundKeepAlive';

/**
 * 短时任务宽限窗口的上限（秒）：优雅断开只需要发 SSH disconnect 并收尾，
 * 秒级足够。系统给的剩余时间可能长得多，但我们不该白占——取两者较小值。
 */
const GRACE_MAX_SEC: number = 8;

/** 长时任务网关（生产实现 ProductionContinuousTask，单测可注入 fake） */
export interface ContinuousTaskGateway {
  /** 申请 dataTransfer 长时任务；granted/failed 经回调回报（受理语义） */
  start(onGranted: () => void, onFailed: () => void): void;
  /** 释放长时任务（幂等） */
  stop(): void;
  /** 注册系统回调：取消 / 挂起 / 恢复 */
  observe(onCancel: (reason: number) => void, onSuspend: (reason: number) => void,
    onActive: () => void): void;
  /** 注销系统回调 */
  unobserve(): void;
}

/** 短时任务宽限网关 */
export interface TransientTaskGateway {
  /** 申请宽限；返回实际可用秒数（<= GRACE_MAX_SEC），0 = 未拿到 */
  request(reason: string): number;
  /** 撤销宽限（幂等） */
  cancel(): void;
}

/** 息屏/亮屏监听网关 */
export interface ScreenWatcherGateway {
  start(onScreenOff: () => void, onScreenOn: () => void): void;
  stop(): void;
}

/** 定时器抽象（生产 = setTimeout；单测手动触发，不真等分钟） */
export interface PolicyScheduler {
  schedule(delaySec: number, task: () => void): number;
  cancel(timerId: number): void;
}

/** 设置读取（生产 = SettingsRepository） */
export type SettingsReader = () => BackgroundSettings;

export interface BackgroundKeepAliveDeps {
  continuousTask?: ContinuousTaskGateway;
  transientTask?: TransientTaskGateway;
  screenWatcher?: ScreenWatcherGateway;
  sessions?: SessionControl;
  scheduler?: PolicyScheduler;
  readSettings?: SettingsReader;
}

/** 生产定时器：系统 setTimeout（秒 → 毫秒） */
export class SystemPolicyScheduler implements PolicyScheduler {
  schedule(delaySec: number, task: () => void): number {
    return setTimeout(task, Math.max(0, delaySec) * 1000);
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

export class BackgroundKeepAlive {
  private static instance: BackgroundKeepAlive | null = null;

  /** 生产单例（EntryAbility 接线用）；单测请自行 new BackgroundKeepAlive(deps) */
  static get(): BackgroundKeepAlive {
    if (BackgroundKeepAlive.instance === null) {
      BackgroundKeepAlive.instance = new BackgroundKeepAlive();
    }
    return BackgroundKeepAlive.instance;
  }

  private readonly deps: BackgroundKeepAliveDeps;
  private readonly scheduler: PolicyScheduler;
  private readonly readSettings: SettingsReader;
  private policy: BackgroundPolicy;
  private continuousTask: ContinuousTaskGateway | null = null;
  private transientTask: TransientTaskGateway | null = null;
  private screenWatcher: ScreenWatcherGateway | null = null;
  private sessions: SessionControl | null = null;
  private started: boolean = false;
  private screenOffTimerId: number = -1;
  private graceTimerId: number = -1;
  private taskRetryTimerId: number = -1;
  // 监听器保持同一函数对象，stop() 时才摘得掉（按引用比对）
  private readonly onNetworkChanged: (snapshot: NetSnapshot) => void =
    (_snapshot: NetSnapshot): void => this.run(this.policy.onNetworkChanged());
  private readonly onSessionCountChanged: () => void = (): void => this.syncSessionCount();

  constructor(deps?: BackgroundKeepAliveDeps) {
    this.deps = deps ?? {};
    this.scheduler = this.deps.scheduler ?? new SystemPolicyScheduler();
    this.readSettings = this.deps.readSettings ?? defaultSettingsReader;
    this.policy = new BackgroundPolicy(this.readSettings());
  }

  /**
   * 起服务（EntryAbility.onCreate）。context 只用于长时任务申请；
   * 注入了 fake 网关时可以不传（单测路径）。
   */
  start(context?: common.UIAbilityContext): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.policy = new BackgroundPolicy(this.readSettings());
    this.sessions = this.deps.sessions ?? SessionManager.get();
    this.continuousTask = this.deps.continuousTask ??
      (context !== undefined ? new ProductionContinuousTask(context) : null);
    this.transientTask = this.deps.transientTask ??
      (context !== undefined ? new ProductionTransientTask(context) : null);
    this.screenWatcher = this.deps.screenWatcher ?? new ProductionScreenWatcher();

    this.continuousTask?.observe(
      (reason: number): void => {
        // reason 原样喂给策略机：低速取消（4）走退避重申，其余直接进宽限降级
        Logger.info(`长时任务被取消（reason=${reason}）`, LOG_TAG);
        this.run(this.policy.onTaskCancelled(reason));
      },
      (reason: number): void => {
        // 典型 reason=4：dataTransfer 低速。挂起是可恢复的，不断连接
        Logger.info(`长时任务被挂起（reason=${reason}），保持连接等待恢复`, LOG_TAG);
        this.run(this.policy.onTaskSuspended());
      },
      (): void => {
        Logger.info('长时任务已恢复', LOG_TAG);
        this.run(this.policy.onTaskActive());
      });
    this.screenWatcher?.start(
      (): void => this.run(this.policy.onScreenOff()),
      (): void => this.run(this.policy.onScreenOn()));
    NetworkWatcher.get().start();
    NetworkWatcher.get().addChangeListener(this.onNetworkChanged);
    this.sessions?.addSessionCountListener(this.onSessionCountChanged);
    this.syncSessionCount();
    Logger.info('后台保活服务已启动', LOG_TAG);
  }

  /** 停服务（EntryAbility.onDestroy）：还电、摘监听、撤定时器（幂等） */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.cancelScreenOffTimer();
    this.cancelGraceTimer();
    this.cancelTaskRetryTimer();
    this.continuousTask?.unobserve();
    this.continuousTask?.stop();
    this.transientTask?.cancel();
    this.screenWatcher?.stop();
    NetworkWatcher.get().removeChangeListener(this.onNetworkChanged);
    this.sessions?.removeSessionCountListener(this.onSessionCountChanged);
    Logger.info('后台保活服务已停止', LOG_TAG);
  }

  // ---------------------------------------------------------------- 生命周期入口（EntryAbility 转发）

  notifyForeground(): void {
    this.refreshSettings();
    this.syncSessionCount();
    this.run(this.policy.onForeground());
  }

  notifyBackground(): void {
    this.refreshSettings();
    this.syncSessionCount();
    this.run(this.policy.onBackground());
  }

  /** AbilityStage.onMemoryLevel 的 CRITICAL 转发 */
  notifyMemoryCritical(): void {
    this.run(this.policy.onMemoryCritical());
  }

  /** 会话增删后由调用方触发（连接/关闭会话时），让策略机及时还电或补申请 */
  syncSessionCount(): void {
    const count: number = this.sessions?.activeSessionCount() ?? 0;
    this.run(this.policy.onSessionCountChanged(count));
  }

  /** 设置页改了开关后调用 */
  refreshSettings(): void {
    this.run(this.policy.onSettingsChanged(this.readSettings()));
  }

  /** 只读观测（诊断与单测） */
  get state(): BackgroundPolicy {
    return this.policy;
  }

  // ---------------------------------------------------------------- 动作执行

  private run(actions: BgAction[]): void {
    for (const item of actions) {
      switch (item.kind) {
        case 'startContinuousTask':
          this.continuousTask?.start(
            (): void => this.run(this.policy.onTaskGranted()),
            (): void => this.run(this.policy.onTaskFailed()));
          if (this.continuousTask === null) {
            this.run(this.policy.onTaskFailed()); // 无网关（能力缺失）= 申请失败，直接降级
          }
          break;
        case 'stopContinuousTask':
          this.continuousTask?.stop();
          break;
        case 'scheduleTaskRetry':
          this.armTaskRetryTimer(item.delaySec);
          break;
        case 'cancelTaskRetry':
          this.cancelTaskRetryTimer();
          break;
        case 'requestGrace':
          this.beginGrace();
          break;
        case 'cancelGrace':
          this.cancelGraceTimer();
          this.transientTask?.cancel();
          break;
        case 'armScreenOffTimer':
          this.armScreenOffTimer(item.delaySec);
          break;
        case 'cancelScreenOffTimer':
          this.cancelScreenOffTimer();
          break;
        case 'suspendSessions':
          this.sessions?.suspendAllForPolicy(item.reason);
          break;
        case 'resumeSessions':
          this.sessions?.resumeAllSuspended();
          break;
        case 'quietOn':
          this.sessions?.setQuiet(true);
          break;
        case 'quietOff':
          this.sessions?.setQuiet(false);
          break;
        case 'probeNetwork':
          this.sessions?.notifyNetworkChanged();
          break;
        default:
          break;
      }
    }
  }

  /**
   * 宽限窗口：拿到短时任务后按实际秒数起一个定时器，到期优雅断开。
   * 拿不到（能力缺失/被拒）就**立刻**执行断开——此时进程随时可能被冻结，
   * 拖延只会让会话静默失联。
   */
  private beginGrace(): void {
    this.cancelGraceTimer();
    const granted: number = this.transientTask?.request('SSH 会话优雅断开') ?? 0;
    if (granted <= 0) {
      Logger.warn('未拿到短时任务宽限，立即优雅断开', LOG_TAG);
      this.run(this.policy.onGraceExpired());
      return;
    }
    Logger.info(`宽限窗口 ${granted}s 起算`, LOG_TAG);
    this.graceTimerId = this.scheduler.schedule(granted, (): void => {
      this.graceTimerId = -1;
      this.transientTask?.cancel();
      this.run(this.policy.onGraceExpired());
    });
  }

  private cancelGraceTimer(): void {
    if (this.graceTimerId !== -1) {
      this.scheduler.cancel(this.graceTimerId);
      this.graceTimerId = -1;
    }
  }

  /** 低速取消后的重申倒计时：到期由策略机决定要不要真的再申请一次 */
  private armTaskRetryTimer(delaySec: number): void {
    this.cancelTaskRetryTimer();
    Logger.info(`长时任务将在 ${delaySec}s 后重申`, LOG_TAG);
    this.taskRetryTimerId = this.scheduler.schedule(delaySec, (): void => {
      this.taskRetryTimerId = -1;
      this.run(this.policy.onTaskRetryTimerExpired());
    });
  }

  private cancelTaskRetryTimer(): void {
    if (this.taskRetryTimerId !== -1) {
      this.scheduler.cancel(this.taskRetryTimerId);
      this.taskRetryTimerId = -1;
    }
  }

  private armScreenOffTimer(delaySec: number): void {
    this.cancelScreenOffTimer();
    this.screenOffTimerId = this.scheduler.schedule(delaySec, (): void => {
      this.screenOffTimerId = -1;
      this.run(this.policy.onScreenOffTimerExpired());
    });
  }

  private cancelScreenOffTimer(): void {
    if (this.screenOffTimerId !== -1) {
      this.scheduler.cancel(this.screenOffTimerId);
      this.screenOffTimerId = -1;
    }
  }
}

// ------------------------------------------------------------------ 生产网关实现

function defaultSettingsReader(): BackgroundSettings {
  return {
    keepAliveInBackground: SettingsRepository.isKeepAliveInBackground(),
    screenOffDisconnectMinutes: SettingsRepository.getScreenOffDisconnectMinutes()
  };
}

/**
 * dataTransfer 长时任务。注意 DESIGN §7.5 原文只写了「申请长时任务」，
 * 但系统会因低速把它挂起/取消（ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED），
 * 所以三个回调必须全接——策略机的降级链正是靠它们驱动的。
 */
class ProductionContinuousTask implements ContinuousTaskGateway {
  private readonly context: common.UIAbilityContext;
  private running: boolean = false;
  /** 申请在途期间收到过 stop()：批下来的那一刻立刻还回去（回前台快过系统审批的情形） */
  private pendingStop: boolean = false;
  private cancelCb: Callback<backgroundTaskManager.ContinuousTaskCancelInfo> | null = null;
  private suspendCb: Callback<backgroundTaskManager.ContinuousTaskSuspendInfo> | null = null;
  private activeCb: Callback<backgroundTaskManager.ContinuousTaskActiveInfo> | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  start(onGranted: () => void, onFailed: () => void): void {
    this.pendingStop = false;
    if (this.running) {
      onGranted();
      return;
    }
    try {
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      wantAgent.getWantAgent(agentInfo).then((agent: WantAgent) => {
        backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent)
          .then(() => {
            this.running = true;
            Logger.info('长时任务已申请（dataTransfer）', LOG_TAG);
            if (this.pendingStop) {
              // 审批期间已经回了前台：立刻还回去，不让它白挂着
              this.pendingStop = false;
              this.stop();
              return;
            }
            onGranted();
          })
          .catch((err: BusinessError) => {
            Logger.warn(`长时任务申请失败: code=${err.code}`, LOG_TAG);
            onFailed();
          });
      }).catch((err: BusinessError) => {
        Logger.warn(`WantAgent 创建失败: code=${err.code}`, LOG_TAG);
        onFailed();
      });
    } catch (err) {
      Logger.warn(`长时任务能力不可用: ${JSON.stringify(err)}`, LOG_TAG);
      onFailed();
    }
  }

  stop(): void {
    if (!this.running) {
      this.pendingStop = true; // 申请可能还在途，等它落地后立刻释放
      return;
    }
    this.running = false;
    try {
      backgroundTaskManager.stopBackgroundRunning(this.context)
        .then(() => Logger.info('长时任务已释放', LOG_TAG))
        .catch((err: BusinessError) => Logger.warn(`长时任务释放失败: code=${err.code}`, LOG_TAG));
    } catch (err) {
      Logger.warn(`长时任务释放异常: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  observe(onCancel: (reason: number) => void, onSuspend: (reason: number) => void,
    onActive: () => void): void {
    this.cancelCb = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      this.running = false;
      onCancel(info.reason as number);
    };
    this.suspendCb = (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      onSuspend(info.suspendReason as number);
    };
    this.activeCb = (_info: backgroundTaskManager.ContinuousTaskActiveInfo): void => {
      onActive();
    };
    this.tryOn('continuousTaskCancel');
    this.tryOn('continuousTaskSuspend');
    this.tryOn('continuousTaskActive');
  }

  unobserve(): void {
    this.tryOff('continuousTaskCancel');
    this.tryOff('continuousTaskSuspend');
    this.tryOff('continuousTaskActive');
    this.cancelCb = null;
    this.suspendCb = null;
    this.activeCb = null;
  }

  // 三个事件的注册/注销签名各不相同（回调载荷不同），这里逐个 try：
  // 老设备上 suspend/active 事件可能不支持（API 20 起），失败只降级不报错
  private tryOn(type: string): void {
    try {
      if (type === 'continuousTaskCancel' && this.cancelCb !== null) {
        backgroundTaskManager.on('continuousTaskCancel', this.cancelCb);
      } else if (type === 'continuousTaskSuspend' && this.suspendCb !== null) {
        backgroundTaskManager.on('continuousTaskSuspend', this.suspendCb);
      } else if (type === 'continuousTaskActive' && this.activeCb !== null) {
        backgroundTaskManager.on('continuousTaskActive', this.activeCb);
      }
    } catch (err) {
      Logger.warn(`长时任务事件 ${type} 注册失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  private tryOff(type: string): void {
    try {
      if (type === 'continuousTaskCancel' && this.cancelCb !== null) {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelCb);
      } else if (type === 'continuousTaskSuspend' && this.suspendCb !== null) {
        backgroundTaskManager.off('continuousTaskSuspend', this.suspendCb);
      } else if (type === 'continuousTaskActive' && this.activeCb !== null) {
        backgroundTaskManager.off('continuousTaskActive', this.activeCb);
      }
    } catch (_err) {
    }
  }
}

/** 短时任务宽限：拿一个「进入冻结前的缓冲窗口」，够我们发完 SSH disconnect */
class ProductionTransientTask implements TransientTaskGateway {
  private requestId: number = -1;

  constructor(_context: common.Context) {
  }

  request(reason: string): number {
    this.cancel();
    try {
      const info: backgroundTaskManager.DelaySuspendInfo =
        backgroundTaskManager.requestSuspendDelay(reason, (): void => {
          // 系统提前收回宽限：句柄作废，剩下的收尾由到期回调那条路兜
          this.requestId = -1;
        });
      this.requestId = info.requestId;
      const remainingSec: number = Math.floor(info.actualDelayTime / 1000);
      return Math.max(1, Math.min(GRACE_MAX_SEC, remainingSec));
    } catch (err) {
      Logger.warn(`短时任务申请失败: ${JSON.stringify(err)}`, LOG_TAG);
      return 0;
    }
  }

  cancel(): void {
    if (this.requestId === -1) {
      return;
    }
    try {
      backgroundTaskManager.cancelSuspendDelay(this.requestId);
    } catch (_err) {
    }
    this.requestId = -1;
  }
}

/** 息屏/亮屏：系统公共事件，无需额外权限 */
class ProductionScreenWatcher implements ScreenWatcherGateway {
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;

  start(onScreenOff: () => void, onScreenOn: () => void): void {
    if (this.subscriber !== null) {
      return;
    }
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [
        commonEventManager.Support.COMMON_EVENT_SCREEN_OFF,
        commonEventManager.Support.COMMON_EVENT_SCREEN_ON
      ]
    };
    try {
      commonEventManager.createSubscriber(info,
        (err: BusinessError, subscriber: commonEventManager.CommonEventSubscriber) => {
          if (err !== undefined && err !== null) {
            Logger.warn(`息屏事件订阅创建失败: code=${err.code}`, LOG_TAG);
            return;
          }
          this.subscriber = subscriber;
          commonEventManager.subscribe(subscriber,
            (subErr: BusinessError, data: commonEventManager.CommonEventData) => {
              if (subErr !== undefined && subErr !== null) {
                Logger.warn(`息屏事件订阅失败: code=${subErr.code}`, LOG_TAG);
                return;
              }
              if (data.event === commonEventManager.Support.COMMON_EVENT_SCREEN_OFF) {
                onScreenOff();
              } else if (data.event === commonEventManager.Support.COMMON_EVENT_SCREEN_ON) {
                onScreenOn();
              }
            });
        });
    } catch (err) {
      Logger.warn(`息屏事件能力不可用: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  stop(): void {
    const subscriber: commonEventManager.CommonEventSubscriber | null = this.subscriber;
    if (subscriber === null) {
      return;
    }
    this.subscriber = null;
    try {
      commonEventManager.unsubscribe(subscriber, (err: BusinessError) => {
        if (err !== undefined && err !== null) {
          Logger.warn(`息屏事件退订失败: code=${err.code}`, LOG_TAG);
        }
      });
    } catch (_err) {
    }
  }
}
