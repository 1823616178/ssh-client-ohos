/**
 * SessionManager —— 多会话生命周期与窗格绑定（任务 C4，DESIGN §2 服务层 / §4.3.1 / §7.1 / §7.5）。
 *
 * 设计依据：
 *   - §2：服务层为纯 ArkTS 逻辑（可单测），UI 经 @ObservedV2 / 事件监听器订阅状态。
 *     生产依赖（native 会话工厂 / 凭据库 / 系统定时器）全部经窄接口注入，单测以
 *     fake 覆盖（对齐 C1 的 InMemoryRdbGateway 模式）；
 *   - §4.3.1：窗格树 Leaf ↔ 一个 SSH 会话；bindPane/unbindPane 只提供绑定原语，
 *     树本身的兄弟上提等操作归 U4b；
 *   - §7.1：自动重连退避由 native 给建议秒数（默认 1/2/5/10/20/30，上限 6 次），
 *     倒计时与尝试次数在 ArkTS 侧编排（SessionInfo.reconnectCountdownSec /
 *     reconnectAttempt）；到期以同一主机配置**新建** native 会话——sessionId 面孔
 *     不变、native 句柄换新（terminal 重绑归 U4）；
 *   - §7.5：应用退出时 closeAll() 优雅关闭全部会话（EntryAbility.onDestroy 接线）。
 *
 * 线程与事件模型（N11 契约「方法同步受理、事件异步回报」）：
 *   - native onEvent 在 ArkTS 主线程触发，直接驱动 SessionInfo（@ObservedV2/@Trace）
 *     状态迁移，UI 可逐字段订阅；
 *   - connect()/close() 受理即返回，后续状态全部经 stateChange 事件推进；
 *   - 每次拨号创建独立事件闭包（绑定 sessionId + 本任句柄标记），重连换句柄后
 *     旧句柄的迟到事件按标记丢弃；
 *   - channelData / terminal* 事件除透传给事件监听器（U4 分发 terminal 事件）外，
 *     同步触发 dirty 监听器——U4 将其接到 TerminalCanvas.notifyContentDirty()
 *     唤醒帧调度（T4 登记的硬依赖，见 FrameSchedulerCore / TerminalCanvas 头注）。
 *
 * 主机密钥 TOFU（§7.1）：native 的 hostKey 事件（fingerprintSha256 / randomart）
 * 本类只做透传（事件监听器可收到），确认/拒绝交互与 known_hosts 入库归 U2/U4。
 *
 * 安全纪律（沿袭 C2）：凭据只在 connect/重连的调用栈内短暂持有（局部变量），
 * 不写入 SessionInfo、不缓存、不进日志；日志只记录 sessionId 与主机名。
 *
 * 用法：
 *   const info = await SessionManager.get().connect(host);  // HostProfile（C1 模型）
 *   info.state / info.reconnectCountdownSec ...             // UI 订阅 @Trace 字段
 *   SessionManager.get().bindPane(info.sessionId, paneId);  // 窗格绑定（一窗格一会话）
 *   SessionManager.get().unbindPane(paneId, true);          // 关窗格并释放会话
 *   SessionManager.get().closeAll();                        // 应用退出（幂等）
 *   // U4 附加口（additive）：nativeSessionOf(sessionId) 装配 SshTerminal；
 *   // reconnectNow(sessionId) 手动立即重连；cancelAutoReconnect(sessionId) 取消倒计时
 *   // P1 附加口（additive，供 BackgroundKeepAlive 调用，见 service/background/）：
 *   //   activeSessionCount() 决定要不要占长时任务；setQuiet(true) 后台抑制重绘唤醒；
 *   //   notifyNetworkChanged() 切网收敛；suspendAllForPolicy()/resumeAllSuspended()
 *   //   策略性断开与回前台原地恢复（断连接不销毁面孔，永不静默失联）
 */

import { util } from '@kit.ArkTS';
import { SshError, SshErrorCode } from '../common/SshError';
import { Logger } from '../common/utils/Logger';
import { HostProfile } from '../common/model/models';
import { recordHostLastUsed } from '../viewmodel/HostListViewModel';
import {
  SshEvent,
  SshEventListener,
  SshNativeSession,
  SshSessionStateName
} from '../napi/SshNative';
import { CredentialKind, CredentialStore } from '../repository/CredentialStore';
import { SessionControl, SessionCountListener } from './background/SessionControl';

const LOG_TAG: string = 'SessionManager';

/** 默认重连次数上限（§7.1：退避 1/2/5/10/20/30s，6 次后放弃） */
export const DEFAULT_RECONNECT_MAX_ATTEMPTS: number = 6;
/** keepalive 连续无入站活动判黑洞的周期数（native 默认 3，显式传入保证语义固定） */
const KEEPALIVE_MAX_MISSES: number = 3;
/**
 * 网络切换后主动探测的判定窗口秒数（P1）：与 TASKS.md「WiFi ⇄ 蜂窝切换 5 s 内
 * 触发重连」同口径。周期 keepalive 是 30 s × 3 = 90 s，切网场景太慢，故切网时
 * 对 established 会话强发一拍并只等这么久（native doProbeNow / KeepaliveProbe）。
 */
export const NETWORK_PROBE_TIMEOUT_SEC: number = 5;

/** 全部合法会话状态名（stateChange 事件的 to 字段校验用） */
const ALL_SESSION_STATE_NAMES: SshSessionStateName[] = [
  'idle', 'connecting', 'handshaking', 'authenticating', 'established',
  'closing', 'closed', 'disconnected', 'error'
];

/** 触发 dirty 唤醒的事件类型：远端输出可能到达（channelData / terminal*） */
const DIRTY_EVENT_TYPES: string[] = [
  'channelData', 'terminalOpen', 'terminalData', 'terminalClose',
  'terminalBell', 'terminalTitle', 'terminalMouseMode'
];

/** stateChange 事件的 to 字段是否为合法状态名 */
export function isSessionStateName(value: string): boolean {
  for (const name of ALL_SESSION_STATE_NAMES) {
    if (name === value) {
      return true;
    }
  }
  return false;
}

/** 「活着的」会话状态：连接建立过程中或已建立（P1 活跃会话计数用） */
export function isLiveState(state: SshSessionStateName): boolean {
  return state === 'connecting' || state === 'handshaking' ||
    state === 'authenticating' || state === 'established';
}

function isDirtyEvent(type: string): boolean {
  for (const t of DIRTY_EVENT_TYPES) {
    if (t === type) {
      return true;
    }
  }
  return false;
}

/**
 * native 会话窄接口：SessionManager 用到的最小方法集。
 * 生产实现是 SshNativeSession（结构性满足），单测注入 FakeNativeSession。
 */
export interface NativeSessionLike {
  connect(host: string, port: number, username: string): boolean;
  authenticatePassword(password: string): boolean;
  authenticatePublicKey(privateKey: ArrayBuffer | string, publicKey: string, passphrase: string): boolean;
  setKeepalive(intervalSec: number, maxMisses: number): boolean;
  /** P1：网络切换后主动探测（仅 established 受理，false = 未受理） */
  probeNow(timeoutSec: number): boolean;
  setReconnectPolicy(delaysSec: number[], maxAttempts: number): boolean;
  nextReconnectDelaySec(attempt: number): number;
  close(): void;
  /** native 句柄（只读；U4 装配终端用，业务层不应直接触碰） */
  readonly nativeHandle: number;
}

/** native 会话工厂：生产 = SshNativeSession.create，测试 = fake 工厂 */
export type NativeSessionFactory = (onEvent: SshEventListener) => NativeSessionLike | null;

/** 凭据读取：生产 = CredentialStore.getSecret，测试 = 内存 fake */
export type SecretProvider = (hostId: string, kind: CredentialKind) => Promise<string | null>;

/**
 * 重连定时器抽象：生产 = setTimeout/clearTimeout，测试 = 手动触发（不真等秒）。
 * schedule 返回的 id 供 cancel 撤消（手动 close/解绑杀会话时取消在途重连）。
 */
export interface ReconnectScheduler {
  schedule(delaySec: number, task: () => void): number;
  cancel(timerId: number): void;
}

/** 生产定时器：系统 setTimeout（秒 → 毫秒） */
export class SystemReconnectScheduler implements ReconnectScheduler {
  schedule(delaySec: number, task: () => void): number {
    return setTimeout(task, Math.max(0, delaySec) * 1000);
  }

  cancel(timerId: number): void {
    clearTimeout(timerId);
  }
}

/** 可选依赖集：缺省项走生产实现；单测全部注入 fake */
export interface SessionManagerDeps {
  createNativeSession?: NativeSessionFactory;
  getSecret?: SecretProvider;
  scheduler?: ReconnectScheduler;
  newSessionId?: () => string;
}

/** 会话事件监听器（全量事件透传：stateChange / hostKey / channel 系 / terminal 系等） */
export type SessionEventListener = (session: SessionInfo, event: SshEvent) => void;

/** dirty 唤醒监听器：远端输出可能到达时触发（U4 接到 TerminalCanvas.notifyContentDirty） */
export type ContentDirtyListener = (sessionId: string) => void;

/**
 * 会话的 UI 面孔（@ObservedV2）：@Trace 字段可被组件逐字段订阅。
 * sessionId/hostId/hostName 创建后不变，无需 @Trace。
 */
@ObservedV2
export class SessionInfo {
  readonly sessionId: string;
  readonly hostId: string;
  readonly hostName: string;
  /** 会话状态（随 native stateChange 迁移；手动 close 后置 closed） */
  @Trace state: SshSessionStateName = 'idle';
  /** 当前 shell 通道 id（channelOpen/channelClose 事件维护；无通道为 null） */
  @Trace channelId: number | null = null;
  /** 面向用户的中文错误文案（经 SshError.fromNativeCode → toUserMessage 收口） */
  @Trace errorMessage: string = '';
  /** 错误码调试名（snake_case，诊断用） */
  @Trace errorCodeName: string = '';
  /** 当前重连尝试次数（established 后归零；§7.1 界面显示尝试次数） */
  @Trace reconnectAttempt: number = 0;
  /** 重连倒计时秒数（每秒递减，0 = 不在退避中；§7.1 界面显示倒计时） */
  @Trace reconnectCountdownSec: number = 0;
  /** 绑定的窗格 id（bindPane/unbindPane 维护；未绑定为 null） */
  @Trace paneId: string | null = null;

  constructor(sessionId: string, hostId: string, hostName: string) {
    this.sessionId = sessionId;
    this.hostId = hostId;
    this.hostName = hostName;
  }
}

/** 内部会话记录：SessionInfo（UI 面孔）+ 当前 native 句柄 + 重连编排状态 */
interface SessionRecord {
  info: SessionInfo;
  /** 主机配置快照（重连时按原配置重新拨号） */
  host: HostProfile;
  /** 当前 native 会话；退避等待期（旧句柄已关、新句柄未建）为 null */
  nativeSession: NativeSessionLike | null;
  /** 在途重连定时器 id；-1 = 无 */
  reconnectTimerId: number;
  /** 已发起的重连次数（established 归零；nextReconnectDelaySec 的 attempt 依据） */
  reconnectAttempt: number;
  /**
   * 待提交的认证材料。connect() 是受理语义，返回时会话还在 connecting，
   * 而 native 只在 authenticating 态受理认证请求（见 cpp/ssh/auth.cpp）——
   * 故材料先暂存，等 stateChange → authenticating 再提交，提交即置 null。
   * 安全：只在「拨号 → 进入 authenticating」这一窗口内存在，绝不进 SessionInfo/日志。
   */
  pendingAuth: AuthMaterial | null;
  /**
   * P1：因后台保活策略被断开（不是用户关的、也不是链路失败）。
   * 记录与窗格绑定都保留，回前台由 resumeAllSuspended() 原地重连；
   * 期间不计入 activeSessionCount（长时任务据此还电）。
   */
  policySuspended: boolean;
}

/** 认证材料（只在拨号调用栈内短暂存在，绝不入 SessionInfo/日志） */
interface AuthMaterial {
  method: 'password' | 'key';
  password: string;
  privateKey: string;
  passphrase: string;
}

/** 每次拨号的事件源标记：记录本任句柄，用于丢弃上一任句柄的迟到事件 */
interface NativeSessionHolder {
  current: NativeSessionLike | null;
}

export class SessionManager implements SessionControl {
  private static instance: SessionManager | null = null;

  /** 生产单例（EntryAbility / UI 层使用）；单测请自行 new SessionManager(deps) */
  static get(): SessionManager {
    if (SessionManager.instance === null) {
      SessionManager.instance = new SessionManager();
    }
    return SessionManager.instance;
  }

  private readonly createNativeSession: NativeSessionFactory;
  private readonly getSecret: SecretProvider;
  private readonly scheduler: ReconnectScheduler;
  private readonly newSessionId: () => string;
  /** sessionId ↔ 会话记录（与 native 句柄一一对应，绝不复用句柄） */
  private readonly sessions: Map<string, SessionRecord> = new Map();
  /** paneId → sessionId（反向经 SessionInfo.paneId；一个窗格最多绑一个会话） */
  private readonly paneToSession: Map<string, string> = new Map();
  private readonly eventListeners: SessionEventListener[] = [];
  private readonly dirtyListeners: ContentDirtyListener[] = [];
  /** P1 静默模式：切后台时抑制 dirty 唤醒（事件仍透传），见 setQuiet */
  private quiet: boolean = false;
  private readonly countListeners: SessionCountListener[] = [];
  /** 会话数通知的重入闸：监听器里若又改动了会话，不再递归回来（一次通知足够） */
  private notifyingCount: boolean = false;

  constructor(deps?: SessionManagerDeps) {
    this.createNativeSession = deps?.createNativeSession ??
      ((onEvent: SshEventListener): NativeSessionLike | null => SshNativeSession.create(onEvent));
    this.getSecret = deps?.getSecret ??
      ((hostId: string, kind: CredentialKind): Promise<string | null> =>
        CredentialStore.getSecret(hostId, kind));
    this.scheduler = deps?.scheduler ?? new SystemReconnectScheduler();
    this.newSessionId = deps?.newSessionId ?? ((): string => util.generateRandomUUID());
  }

  /**
   * 建立会话（受理语义）：取凭据 → 创建 native 会话 → keepalive/重连策略 →
   * connect → authenticate*；任一环节未被受理即抛 SshError 且不留资源。
   * 后续状态迁移（handshaking/authenticating/established…）经事件异步推进，
   * 返回的 SessionInfo 即 UI 订阅入口。
   */
  async connect(host: HostProfile): Promise<SessionInfo> {
    // 取凭据要走 ASSET 系统服务（异步）；这两条日志把「卡在取凭据」和
    // 「卡在拨号」区分开——只记方法名与主机名，不碰凭据本体
    Logger.info(`读取凭据（主机=${host.name}, authType=${host.authType}）`, LOG_TAG);
    const auth: AuthMaterial = await this.prepareAuth(host);
    Logger.info(`凭据就绪（method=${auth.method}），开始拨号`, LOG_TAG);
    const info: SessionInfo = new SessionInfo(this.newSessionId(), host.id, host.name);
    const record: SessionRecord = {
      info: info,
      host: host,
      nativeSession: null,
      reconnectTimerId: -1,
      reconnectAttempt: 0,
      pendingAuth: null,
      policySuspended: false
    };
    // 先入表再拨号：事件（理论上）最早可在 connect 受理后到达
    this.sessions.set(info.sessionId, record);
    try {
      this.dialNative(record, auth);
    } catch (err) {
      this.sessions.delete(info.sessionId);
      if (err instanceof Error) {
        throw err;
      }
      throw new SshError(SshErrorCode.INTERNAL_ERROR, '连接建立失败');
    }
    Logger.info(`会话已受理：${info.sessionId}（主机=${host.name}）`, LOG_TAG);
    recordHostLastUsed(host.id);
    this.notifySessionCount();
    return info;
  }

  /** 优雅关闭（幂等）：取消在途重连 → close native → 解绑窗格 → 摘表 */
  close(sessionId: string): void {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined) {
      return;
    }
    this.cancelReconnect(record);
    // 未及提交的认证材料随会话一起丢弃，不留在内存里
    record.pendingAuth = null;
    if (record.nativeSession !== null) {
      record.nativeSession.close();
      record.nativeSession = null;
    }
    const paneId: string | null = record.info.paneId;
    if (paneId !== null) {
      this.paneToSession.delete(paneId);
      record.info.paneId = null;
    }
    this.sessions.delete(sessionId);
    record.info.state = 'closed';
    record.info.reconnectCountdownSec = 0;
    Logger.info(`会话已关闭：${sessionId}`, LOG_TAG);
    this.notifySessionCount();
  }

  /** 应用退出入口（§7.5，幂等）：优雅关闭全部会话 */
  closeAll(): void {
    const ids: string[] = [];
    this.sessions.forEach((record: SessionRecord, sessionId: string) => {
      ids.push(sessionId);
    });
    for (const sessionId of ids) {
      this.close(sessionId);
    }
  }

  /** 只读会话列表快照（元素为 @ObservedV2，可逐字段订阅；增删经事件感知） */
  listSessions(): SessionInfo[] {
    const result: SessionInfo[] = [];
    this.sessions.forEach((record: SessionRecord) => {
      result.push(record.info);
    });
    return result;
  }

  getSession(sessionId: string): SessionInfo | null {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    return record === undefined ? null : record.info;
  }

  /**
   * 会话的主机配置快照（U4b 分屏/新标签复用；含快速连接临时主机，DAO 里可能没有）。
   * 返回内部引用，调用方不得改字段。
   */
  hostOf(sessionId: string): HostProfile | null {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    return record === undefined ? null : record.host;
  }

  /** 当前 native 句柄（退避期/已关闭返回 null）；供 U4 装配终端，业务层勿直接使用 */
  getNativeHandle(sessionId: string): number | null {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined || record.nativeSession === null) {
      return null;
    }
    return record.nativeSession.nativeHandle;
  }

  /**
   * 当前 native 会话实例（只读窄口，U4 装配 SshTerminal 用；退避期/已关闭返回 null）。
   * 单测注入的 fake 不是 SshNativeSession（attach 仅生产路径可达），此时返回 null。
   */
  nativeSessionOf(sessionId: string): SshNativeSession | null {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined || record.nativeSession === null) {
      return null;
    }
    return record.nativeSession instanceof SshNativeSession ? record.nativeSession : null;
  }

  // ---------------------------------------------------------------- 手动重连控制（U4，additive）

  /**
   * 手动立即重连（U4 错误蒙层「立即重连」，§7.1）：取消在途退避定时器、关闭残留
   * 旧句柄（error 终态保留的那只），随后按原主机配置立即重新拨号（sessionId 不变、
   * native 句柄换新，与自动重连同通路）。仅 disconnected / error 态受理，其余返回 false。
   */
  reconnectNow(sessionId: string): boolean {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined) {
      return false;
    }
    const state: SshSessionStateName = record.info.state;
    if (state !== 'disconnected' && state !== 'error') {
      return false;
    }
    this.cancelReconnect(record);
    record.pendingAuth = null;
    if (record.nativeSession !== null) {
      record.nativeSession.close();
      record.nativeSession = null;
    }
    // 用户手动重连即解除策略挂起（P1）：他明确要现在连，回前台的批量恢复不必再管它
    record.policySuspended = false;
    record.info.reconnectCountdownSec = 0;
    Logger.info(`会话 ${sessionId} 手动重连受理`, LOG_TAG);
    this.startReconnect(record);
    return true;
  }

  /**
   * 取消自动重连倒计时（U4 重连蒙层「取消」）：撤掉在途定时器并清零倒计时，
   * 会话保持 disconnected 待用户抉择（立即重连 / 关闭）；无在途定时器返回 false。
   */
  cancelAutoReconnect(sessionId: string): boolean {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined || record.reconnectTimerId === -1) {
      return false;
    }
    this.cancelReconnect(record);
    record.info.reconnectCountdownSec = 0;
    Logger.info(`会话 ${sessionId} 自动重连已由用户取消`, LOG_TAG);
    return true;
  }

  // ---------------------------------------------------------------- P1 后台保活支撑（additive）

  /**
   * 「活着的会话」条数（P1 策略机据此决定要不要占长时任务）：
   * 连接中/握手/认证/已建立，或正在退避重连倒计时的会话都算活；
   * 已按策略挂起（policySuspended）的不算——它就是为了还电才断的。
   */
  activeSessionCount(): number {
    let count: number = 0;
    this.sessions.forEach((record: SessionRecord) => {
      if (this.isRecordActive(record)) {
        count++;
      }
    });
    return count;
  }

  /**
   * 静默模式（P1，切后台开、回前台关）：抑制 dirty 唤醒，避免画面不可见时
   * 还按远端输出逐帧唤醒渲染。**事件照常透传**（终端 native 侧继续收数据入
   * 回滚缓冲，一个字节都不丢），回前台关掉静默后由画布整帧重画补上。
   */
  setQuiet(quiet: boolean): void {
    if (this.quiet === quiet) {
      return;
    }
    this.quiet = quiet;
    Logger.info(`会话静默模式=${quiet}`, LOG_TAG);
  }

  isQuiet(): boolean {
    return this.quiet;
  }

  /**
   * 默认网变化（P1，WiFi ⇄ 蜂窝等）：不干等超时，主动收敛每条会话——
   *   - 退避倒计时中的：撤掉倒计时立刻重连（新网络多半已经可用）；
   *   - established 的：向 native 要一次 5 s 短窗口探测，黑洞即断线走既有重连链。
   * 返回被处理的会话数（策略挂起中的会话不动，回前台再统一恢复）。
   */
  notifyNetworkChanged(): number {
    let affected: number = 0;
    this.sessions.forEach((record: SessionRecord) => {
      if (record.policySuspended) {
        return;
      }
      if (record.reconnectTimerId !== -1) {
        this.cancelReconnect(record);
        record.info.reconnectCountdownSec = 0;
        Logger.info(`网络已切换，会话 ${record.info.sessionId} 提前发起重连`, LOG_TAG);
        this.startReconnect(record);
        affected++;
        return;
      }
      const session: NativeSessionLike | null = record.nativeSession;
      if (session !== null && record.info.state === 'established' &&
        session.probeNow(NETWORK_PROBE_TIMEOUT_SEC)) {
        affected++;
      }
    });
    if (affected > 0) {
      Logger.info(`网络切换已通知 ${affected} 个会话`, LOG_TAG);
    }
    return affected;
  }

  /**
   * 按策略挂起全部会话（P1：后台保活关闭 / 长时任务被系统取消 / 息屏到期 /
   * 内存告急）。与 close() 的区别是**只断连接、不销毁面孔**：SessionInfo 与
   * 窗格绑定原样保留，状态置 disconnected 并写入中文原因，回前台
   * resumeAllSuspended() 原地重连（sessionId 不变、句柄换新）。
   * 幂等，返回被挂起的会话数。
   */
  suspendAllForPolicy(reason: string): number {
    let count: number = 0;
    this.sessions.forEach((record: SessionRecord) => {
      if (record.policySuspended) {
        return;
      }
      if (record.nativeSession === null && record.reconnectTimerId === -1) {
        return; // 已经不是活的（用户关掉的 / 重连超限的），不必也不该改它的终态文案
      }
      this.cancelReconnect(record);
      record.pendingAuth = null;
      if (record.nativeSession !== null) {
        record.nativeSession.close();
        record.nativeSession = null;
      }
      record.policySuspended = true;
      record.info.state = 'disconnected';
      record.info.channelId = null;
      record.info.errorMessage = reason;
      record.info.errorCodeName = '';
      record.info.reconnectCountdownSec = 0;
      count++;
    });
    if (count > 0) {
      Logger.info(`按后台策略挂起 ${count} 个会话：${reason}`, LOG_TAG);
      this.notifySessionCount();
    }
    return count;
  }

  /**
   * 恢复被策略挂起的会话（P1，回前台/亮屏）：逐条按原主机配置重新拨号。
   * 重连计数从零起算——策略性断开不是链路失败，不该消耗用户的重试预算。
   * 幂等，返回被恢复的会话数。
   */
  resumeAllSuspended(): number {
    const pending: SessionRecord[] = [];
    this.sessions.forEach((record: SessionRecord) => {
      if (record.policySuspended) {
        pending.push(record);
      }
    });
    for (const record of pending) {
      record.policySuspended = false;
      record.reconnectAttempt = 0;
      record.info.reconnectAttempt = 0;
      record.info.errorMessage = '';
      record.info.errorCodeName = '';
      Logger.info(`恢复策略挂起的会话 ${record.info.sessionId}`, LOG_TAG);
      this.startReconnect(record);
    }
    if (pending.length > 0) {
      this.notifySessionCount();
    }
    return pending.length;
  }

  /**
   * 会话数/状态变化监听（P1）：后台策略机据此及时申请或释放长时任务，
   * 不必等到下一次前后台切换才发现「最后一个会话已经关了」。
   */
  addSessionCountListener(listener: SessionCountListener): void {
    this.countListeners.push(listener);
  }

  removeSessionCountListener(listener: SessionCountListener): void {
    const index: number = this.countListeners.indexOf(listener);
    if (index >= 0) {
      this.countListeners.splice(index, 1);
    }
  }

  /** 当前处于策略挂起态的会话数（P1 状态机与 UI 提示用） */
  suspendedCount(): number {
    let count: number = 0;
    this.sessions.forEach((record: SessionRecord) => {
      if (record.policySuspended) {
        count++;
      }
    });
    return count;
  }

  // ---------------------------------------------------------------- 会话 ↔ 窗格绑定（§4.3.1）

  /**
   * 绑定窗格：一个窗格同时最多绑一个会话，一个会话同时最多绑一个窗格；
   * 重复绑定同一对（sessionId, paneId）幂等；冲突抛 Error（调用方编程错误）。
   */
  bindPane(sessionId: string, paneId: string): void {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined) {
      throw new Error(`bindPane: 会话不存在（${sessionId}）`);
    }
    const boundSession: string | undefined = this.paneToSession.get(paneId);
    if (boundSession === sessionId) {
      return;
    }
    if (boundSession !== undefined) {
      throw new Error(`bindPane: 窗格 ${paneId} 已绑定其他会话（${boundSession}）`);
    }
    if (record.info.paneId !== null) {
      throw new Error(`bindPane: 会话 ${sessionId} 已绑定窗格（${record.info.paneId}）`);
    }
    this.paneToSession.set(paneId, sessionId);
    record.info.paneId = paneId;
  }

  /**
   * 解绑窗格（幂等，未知窗格直接返回）：
   * closeSession=true 时级联释放对应会话（关窗格场景）；false 仅摘绑定。
   */
  unbindPane(paneId: string, closeSession: boolean): void {
    const sessionId: string | undefined = this.paneToSession.get(paneId);
    if (sessionId === undefined) {
      return;
    }
    this.paneToSession.delete(paneId);
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record !== undefined) {
      record.info.paneId = null;
    }
    if (closeSession) {
      this.close(sessionId);
    }
  }

  sessionIdOfPane(paneId: string): string | null {
    const sessionId: string | undefined = this.paneToSession.get(paneId);
    return sessionId === undefined ? null : sessionId;
  }

  paneIdOfSession(sessionId: string): string | null {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined) {
      return null;
    }
    return record.info.paneId;
  }

  // ---------------------------------------------------------------- 监听器注册口（U4 分发用）

  addEventListener(listener: SessionEventListener): void {
    this.eventListeners.push(listener);
  }

  removeEventListener(listener: SessionEventListener): void {
    const index: number = this.eventListeners.indexOf(listener);
    if (index >= 0) {
      this.eventListeners.splice(index, 1);
    }
  }

  addDirtyListener(listener: ContentDirtyListener): void {
    this.dirtyListeners.push(listener);
  }

  removeDirtyListener(listener: ContentDirtyListener): void {
    const index: number = this.dirtyListeners.indexOf(listener);
    if (index >= 0) {
      this.dirtyListeners.splice(index, 1);
    }
  }

  // ---------------------------------------------------------------- 内部：拨号与认证

  /** 按 authType 取凭据（agent 暂未实现，显式报错）；凭据缺失抛 SshError，不建任何资源 */
  private async prepareAuth(host: HostProfile): Promise<AuthMaterial> {
    switch (host.authType) {
      case 'password': {
        const password: string | null = await this.getSecret(host.id, 'password');
        if (password === null) {
          // CREDENTIAL_MISSING 而非 AUTH_PASSWORD_FAILED：上层据此弹框补录密码，
          // 而不是把它当成「服务器拒绝了密码」的终态失败
          throw new SshError(SshErrorCode.CREDENTIAL_MISSING,
            '凭据库中没有该主机的登录密码，请先在主机配置中保存密码');
        }
        return { method: 'password', password: password, privateKey: '', passphrase: '' };
      }
      case 'key': {
        const privateKey: string | null = await this.getSecret(host.id, 'private_key');
        if (privateKey === null) {
          throw new SshError(SshErrorCode.CREDENTIAL_MISSING,
            '凭据库中没有该主机的私钥，请先导入私钥');
        }
        const passphrase: string | null = await this.getSecret(host.id, 'passphrase');
        return { method: 'key', password: '', privateKey: privateKey, passphrase: passphrase ?? '' };
      }
      default:
        throw new SshError(SshErrorCode.INTERNAL_ERROR, 'agent 认证暂未实现，请改用密码或密钥认证');
    }
  }

  /**
   * 一次拨号（同步受理）：创建 native 会话（事件闭包绑定本任句柄标记）→
   * keepalive/重连策略 → connect；未被受理即 close 抛错。
   *
   * 认证**不在这里同步发起**：connect() 是受理语义，返回时 TCP 与 SSH 握手都还没做完，
   * 会话仍是 connecting，而 native 只在 authenticating 态受理认证请求
   * （cpp/ssh/auth.cpp「密码认证拒绝受理：状态 %s（仅 authenticating 可发起）」）。
   * 早期版本在此同步调 authenticate*，必然被拒并抛「密码认证请求未被受理」，
   * 结果是任何主机都连不上。材料改为暂存，由 onStateChange 在进入 authenticating 时提交。
   */
  private dialNative(record: SessionRecord, auth: AuthMaterial): void {
    const host: HostProfile = record.host;
    const sessionId: string = record.info.sessionId;
    const holder: NativeSessionHolder = { current: null };
    const session: NativeSessionLike | null = this.createNativeSession(
      (event: SshEvent) => this.onNativeEvent(sessionId, holder.current, event));
    if (session === null) {
      throw new SshError(SshErrorCode.INTERNAL_ERROR, '创建 native 会话失败');
    }
    holder.current = session;
    record.nativeSession = session;
    // connect 之前就位：握手快时 authenticating 事件可能在 connect() 返回前就投递上来
    record.pendingAuth = auth;
    try {
      session.setKeepalive(host.keepalive, KEEPALIVE_MAX_MISSES);
      session.setReconnectPolicy([], DEFAULT_RECONNECT_MAX_ATTEMPTS);
      if (!session.connect(host.host, host.port, host.username)) {
        throw new SshError(SshErrorCode.INTERNAL_ERROR, '连接请求未被受理');
      }
      if (record.info.state === 'idle') {
        // 事件已把状态推得更靠前时不要倒退回 connecting
        record.info.state = 'connecting';
      }
    } catch (err) {
      record.pendingAuth = null;
      session.close();
      record.nativeSession = null;
      if (err instanceof Error) {
        throw err;
      }
      throw new SshError(SshErrorCode.INTERNAL_ERROR, '连接建立失败');
    }
  }

  /**
   * native 进入 authenticating：提交暂存的认证材料（提交即清空，幂等——
   * 重复进入 authenticating 时 pendingAuth 已为 null，不会重复发起）。
   * 未被受理落 error 终态；材料本身不记日志。
   */
  private submitPendingAuth(record: SessionRecord): void {
    const auth: AuthMaterial | null = record.pendingAuth;
    record.pendingAuth = null;
    const session: NativeSessionLike | null = record.nativeSession;
    if (auth === null || session === null) {
      return;
    }
    const accepted: boolean = auth.method === 'password'
      ? session.authenticatePassword(auth.password)
      : session.authenticatePublicKey(auth.privateKey, '', auth.passphrase);
    if (accepted) {
      Logger.info(`会话 ${record.info.sessionId} 认证请求已受理（method=${auth.method}）`, LOG_TAG);
      return;
    }
    const code: SshErrorCode = auth.method === 'password'
      ? SshErrorCode.AUTH_PASSWORD_FAILED : SshErrorCode.AUTH_PUBLICKEY_FAILED;
    record.info.state = 'error';
    record.info.errorMessage = SshError.toUserMessage(code);
    Logger.error(`会话 ${record.info.sessionId} 认证请求未被受理（method=${auth.method}）`, LOG_TAG);
  }

  // ---------------------------------------------------------------- 内部：事件路由

  /**
   * native 事件入口（主线程）。丢弃两类事件：会话已摘表；来自上一任句柄
   * （重连换句柄后旧会话的迟到事件，holder 标记与当前句柄不一致）。
   */
  private onNativeEvent(sessionId: string, source: NativeSessionLike | null, event: SshEvent): void {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined || record.nativeSession === null || record.nativeSession !== source) {
      return;
    }
    this.forwardEvent(record, event);
    switch (event.type) {
      case 'stateChange':
        this.onStateChange(record, event);
        break;
      case 'channelOpen':
        record.info.channelId = event.channelId ?? null;
        break;
      case 'channelClose':
        if (record.info.channelId !== null && record.info.channelId === event.channelId) {
          record.info.channelId = null;
        }
        break;
      default:
        // hostKey / authResult / channelData / terminal* 等仅透传（TOFU 交互归 U2/U4）
        break;
    }
  }

  /** 全量事件透传给事件监听器；输出类事件同步触发 dirty 唤醒（T4 硬依赖通路） */
  private forwardEvent(record: SessionRecord, event: SshEvent): void {
    for (const listener of this.eventListeners) {
      try {
        listener(record.info, event);
      } catch (err) {
        Logger.error(`会话事件监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
      }
    }
    // 静默模式（后台）只跳过 dirty 唤醒，不跳过上面的事件透传：数据照收，只是不重绘
    if (this.quiet || !isDirtyEvent(event.type)) {
      return;
    }
    for (const listener of this.dirtyListeners) {
      try {
        listener(record.info.sessionId);
      } catch (err) {
        Logger.error(`dirty 监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
      }
    }
  }

  /**
   * stateChange 驱动 SessionInfo 状态迁移（下面的 applyStateChange），外加一层
   * 「活跃与否是否翻转」的判断：只有翻转才通知会话数监听器（P1 策略机据此申请/还电），
   * 逐拍的 connecting → handshaking → … 流转不必惊动它。判断放在编排**之后**——
   * 断线进 disconnected 时若随即排上了退避重连，这条会话仍然算活的。
   */
  private onStateChange(record: SessionRecord, event: SshEvent): void {
    const wasActive: boolean = this.isRecordActive(record);
    this.applyStateChange(record, event);
    if (wasActive !== this.isRecordActive(record)) {
      this.notifySessionCount();
    }
  }

  /** 状态迁移本体：终态错误映射 + 重连 hint 编排 */
  private applyStateChange(record: SessionRecord, event: SshEvent): void {
    const to: string | undefined = event.to;
    if (to === undefined || !isSessionStateName(to)) {
      return;
    }
    const info: SessionInfo = record.info;
    info.state = to as SshSessionStateName;
    if (to === 'authenticating') {
      // 握手完成，native 现在才会受理认证请求（见 dialNative 头注）
      this.submitPendingAuth(record);
      return;
    }
    if (to === 'established') {
      // （重）连成功：重连计数/倒计时/错误信息全部复位
      record.reconnectAttempt = 0;
      info.reconnectAttempt = 0;
      info.reconnectCountdownSec = 0;
      info.errorMessage = '';
      info.errorCodeName = '';
      return;
    }
    if (to !== 'disconnected' && to !== 'error') {
      return;
    }
    if (event.errorCode !== undefined && event.errorCode > 0) {
      const code: SshErrorCode = SshError.fromNativeCode(event.errorCode);
      info.errorMessage = SshError.toUserMessage(code);
      info.errorCodeName = event.errorCodeName ?? '';
      if (event.errorMessage !== undefined) {
        Logger.info(`会话终态诊断（${info.sessionId}）: ${event.errorMessage}`, LOG_TAG);
      }
    }
    if (event.reconnectHint === true) {
      this.scheduleReconnect(record);
    }
  }

  // ---------------------------------------------------------------- 内部：重连编排（§7.1）

  /**
   * 断线 hint → 退避重连：向旧句柄取建议秒数（-1 = 超上限，进 error 终态），
   * 然后关闭旧句柄（sessionId 面孔保持），按秒倒计时到期后新建 native 会话重连。
   */
  private scheduleReconnect(record: SessionRecord): void {
    if (record.reconnectTimerId !== -1 || record.nativeSession === null) {
      return; // 已在退避中（重复 hint 忽略）
    }
    const attempt: number = record.reconnectAttempt + 1;
    const delaySec: number = record.nativeSession.nextReconnectDelaySec(attempt);
    if (delaySec < 0) {
      record.info.state = 'error';
      record.info.errorMessage = record.info.errorMessage.length > 0
        ? `${record.info.errorMessage}；自动重连已达上限`
        : '连接已断开，自动重连已达上限';
      record.info.reconnectCountdownSec = 0;
      Logger.info(`会话 ${record.info.sessionId} 重连次数已达上限，停止重连`, LOG_TAG);
      return;
    }
    record.reconnectAttempt = attempt;
    record.info.reconnectAttempt = attempt;
    // 旧句柄作废：其未提交的材料一并丢弃，重连时由 reconnectAsync 重新取凭据
    record.pendingAuth = null;
    record.nativeSession.close();
    record.nativeSession = null;
    Logger.info(`会话 ${record.info.sessionId} 断线，${delaySec}s 后发起第 ${attempt} 次重连`, LOG_TAG);
    this.scheduleReconnectTick(record, delaySec);
  }

  /** 每秒一格的倒计时 tick（倒计时字段供 UI 显示）；归零即发起重连 */
  private scheduleReconnectTick(record: SessionRecord, remainingSec: number): void {
    record.info.reconnectCountdownSec = remainingSec;
    if (remainingSec <= 0) {
      this.startReconnect(record);
      return;
    }
    const sessionId: string = record.info.sessionId;
    record.reconnectTimerId = this.scheduler.schedule(1, () => {
      record.reconnectTimerId = -1;
      if (this.sessions.get(sessionId) !== record) {
        return; // 会话已被 close 摘除（定时器已 cancel，此处为双保险）
      }
      this.scheduleReconnectTick(record, remainingSec - 1);
    });
  }

  /** 发起重连：同主机配置新建 native 会话（sessionId 保持、句柄换新） */
  private startReconnect(record: SessionRecord): void {
    record.info.state = 'connecting';
    record.info.reconnectCountdownSec = 0;
    this.reconnectAsync(record).then(() => {
      Logger.info(`会话 ${record.info.sessionId} 重连已受理`, LOG_TAG);
    }).catch((err: Object) => {
      if (this.sessions.get(record.info.sessionId) !== record) {
        return;
      }
      record.info.state = 'error';
      record.info.errorMessage =
        err instanceof SshError ? err.message : SshError.toUserMessage(SshErrorCode.INTERNAL_ERROR);
      Logger.error(`会话 ${record.info.sessionId} 重连受理失败: ${JSON.stringify(err)}`, LOG_TAG);
    });
  }

  private async reconnectAsync(record: SessionRecord): Promise<void> {
    const auth: AuthMaterial = await this.prepareAuth(record.host);
    if (this.sessions.get(record.info.sessionId) !== record) {
      return; // 等待凭据期间会话已被关闭
    }
    this.dialNative(record, auth);
  }

  /** 单条会话是否「活着」：连接中/已建立，或正在退避倒计时；策略挂起的不算 */
  private isRecordActive(record: SessionRecord): boolean {
    if (record.policySuspended) {
      return false;
    }
    return isLiveState(record.info.state) || record.reconnectTimerId !== -1;
  }

  /** 通知会话数监听器（P1）；重入期间的二次通知直接丢弃 */
  private notifySessionCount(): void {
    if (this.notifyingCount) {
      return;
    }
    this.notifyingCount = true;
    try {
      for (const listener of this.countListeners) {
        try {
          listener();
        } catch (err) {
          Logger.error(`会话数监听器异常: ${JSON.stringify(err)}`, LOG_TAG);
        }
      }
    } finally {
      this.notifyingCount = false;
    }
  }

  private cancelReconnect(record: SessionRecord): void {
    if (record.reconnectTimerId !== -1) {
      this.scheduler.cancel(record.reconnectTimerId);
      record.reconnectTimerId = -1;
    }
  }
}
