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
 */

import { util } from '@kit.ArkTS';
import { SshError, SshErrorCode } from '../common/SshError';
import { Logger } from '../common/utils/Logger';
import { HostProfile } from '../common/model/models';
import {
  SshEvent,
  SshEventListener,
  SshNativeSession,
  SshSessionStateName
} from '../napi/SshNative';
import { CredentialKind, CredentialStore } from '../repository/CredentialStore';

const LOG_TAG: string = 'SessionManager';

/** 默认重连次数上限（§7.1：退避 1/2/5/10/20/30s，6 次后放弃） */
export const DEFAULT_RECONNECT_MAX_ATTEMPTS: number = 6;
/** keepalive 连续无入站活动判黑洞的周期数（native 默认 3，显式传入保证语义固定） */
const KEEPALIVE_MAX_MISSES: number = 3;

/** 全部合法会话状态名（stateChange 事件的 to 字段校验用） */
const ALL_SESSION_STATE_NAMES: SshSessionStateName[] = [
  'idle', 'connecting', 'handshaking', 'authenticating', 'established',
  'closing', 'closed', 'disconnected', 'error'
];

/** 触发 dirty 唤醒的事件类型：远端输出可能到达（channelData / terminal*） */
const DIRTY_EVENT_TYPES: string[] = [
  'channelData', 'terminalOpen', 'terminalClose', 'terminalBell', 'terminalTitle', 'terminalMouseMode'
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

export class SessionManager {
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
    const auth: AuthMaterial = await this.prepareAuth(host);
    const info: SessionInfo = new SessionInfo(this.newSessionId(), host.id, host.name);
    const record: SessionRecord = {
      info: info,
      host: host,
      nativeSession: null,
      reconnectTimerId: -1,
      reconnectAttempt: 0
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
    return info;
  }

  /** 优雅关闭（幂等）：取消在途重连 → close native → 解绑窗格 → 摘表 */
  close(sessionId: string): void {
    const record: SessionRecord | undefined = this.sessions.get(sessionId);
    if (record === undefined) {
      return;
    }
    this.cancelReconnect(record);
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
    if (record.nativeSession !== null) {
      record.nativeSession.close();
      record.nativeSession = null;
    }
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
          throw new SshError(SshErrorCode.AUTH_PASSWORD_FAILED,
            '凭据库中没有该主机的登录密码，请先在主机配置中保存密码');
        }
        return { method: 'password', password: password, privateKey: '', passphrase: '' };
      }
      case 'key': {
        const privateKey: string | null = await this.getSecret(host.id, 'private_key');
        if (privateKey === null) {
          throw new SshError(SshErrorCode.AUTH_PUBLICKEY_FAILED,
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
   * keepalive/重连策略 → connect → authenticate*；未被受理即 close 抛错。
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
    try {
      session.setKeepalive(host.keepalive, KEEPALIVE_MAX_MISSES);
      session.setReconnectPolicy([], DEFAULT_RECONNECT_MAX_ATTEMPTS);
      if (!session.connect(host.host, host.port, host.username)) {
        throw new SshError(SshErrorCode.INTERNAL_ERROR, '连接请求未被受理');
      }
      record.info.state = 'connecting';
      if (auth.method === 'password') {
        if (!session.authenticatePassword(auth.password)) {
          throw new SshError(SshErrorCode.AUTH_PASSWORD_FAILED, '密码认证请求未被受理');
        }
      } else {
        if (!session.authenticatePublicKey(auth.privateKey, '', auth.passphrase)) {
          throw new SshError(SshErrorCode.AUTH_PUBLICKEY_FAILED, '公钥认证请求未被受理');
        }
      }
    } catch (err) {
      session.close();
      record.nativeSession = null;
      if (err instanceof Error) {
        throw err;
      }
      throw new SshError(SshErrorCode.INTERNAL_ERROR, '连接建立失败');
    }
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
    if (!isDirtyEvent(event.type)) {
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

  /** stateChange 驱动 SessionInfo 状态迁移；终态错误映射 + 重连 hint 编排 */
  private onStateChange(record: SessionRecord, event: SshEvent): void {
    const to: string | undefined = event.to;
    if (to === undefined || !isSessionStateName(to)) {
      return;
    }
    const info: SessionInfo = record.info;
    info.state = to as SshSessionStateName;
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

  private cancelReconnect(record: SessionRecord): void {
    if (record.reconnectTimerId !== -1) {
      this.scheduler.cancel(record.reconnectTimerId);
      record.reconnectTimerId = -1;
    }
  }
}
