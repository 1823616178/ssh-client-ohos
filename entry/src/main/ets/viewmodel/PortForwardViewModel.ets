/**
 * PortForwardViewModel —— U9/N15 端口转发页面状态（规则 CRUD 已在 HostEdit，
 * 本 VM 负责列表 + 启停 + 运行时状态投影 + native 转发桥装配）。
 *
 * N15 装配：
 *   - deps.nativeForward / deps.sessionHandle 提供时，LocalForwardSocket 走
 *     openDirectTcpip；PortForwardRuntime.hasNativeChannel=true（nativeChannelRequired=false）；
 *   - 未提供时保持 MVP：监听骨架 + logNativeMissing。
 *   - deps.onNativeEvent 可订阅 native forwardOpen/Data/Close（生产由
 *     SessionManager 的 onEvent 路由；测试可空）。
 */

import {
  PortForwardRule,
  PortForwardType
} from '../common/model/models';
import {
  ForwardAction,
  ForwardRuntimeLog,
  ForwardRuntimeStatus,
  PortForwardRuntime,
  canStartForwardRule,
  forwardRuleLabel
} from '../service/portforward/PortForwardRuntime';
import {
  ListenGateway,
  LocalForwardSocket,
  NativeForwardPort
} from '../service/portforward/LocalForwardSocket';
import {
  DynamicForwardSession
} from '../service/portforward/DynamicForwardSession';
import { Logger } from '../common/utils/Logger';

const LOG_TAG: string = 'PortForwardViewModel';

/** NativeForwardPort 可选扩展（N15 remote listen）；forwardClose 已在基接口必选 */
export interface NativeForwardPortExt extends NativeForwardPort {
  remoteForwardListen?: (sessionHandle: number, bind: string, port: number) => number;
}

/** N15：具备 remoteForwardListen 的 native 端口（调用侧经实例方法，不拆函数） */
export interface NativeRemoteListenPort extends NativeForwardPort {
  remoteForwardListen(sessionHandle: number, bind: string, port: number): number;
}

function asNativeForwardExt(port: NativeForwardPort): NativeForwardPortExt {
  return port as NativeForwardPortExt;
}

/** 运行时探测：port 是否实现 remoteForwardListen（ArkTS 禁止 optional 直接调用） */
export function asNativeRemoteListenPort(port: NativeForwardPort): NativeRemoteListenPort | null {
  const candidate: NativeRemoteListenPort = port as NativeRemoteListenPort;
  if (typeof candidate.remoteForwardListen === 'function') {
    return candidate;
  }
  return null;
}

/** 规则 DAO 窄接口（生产 = AppDatabase.forwards()，测试 = fake） */
export interface ForwardRuleSource {
  listByHostId(hostId: string): PortForwardRule[];
  listAll(): PortForwardRule[];
  getById(id: string): PortForwardRule | null;
}

export interface PortForwardRow {
  rule: PortForwardRule;
  label: string;
  status: ForwardRuntimeStatus | null;
  canStart: boolean;
  running: boolean;
}

/** native 转发事件（与 SshEvent 对齐的窄子集） */
export interface ForwardNativeEvent {
  type: string;
  forward?: number;
  listen?: number;
  success?: boolean;
  error?: string;
  message?: string;
  reason?: string;
  data?: ArrayBuffer;
  boundPort?: number;
  origin?: string;
}

export interface PortForwardViewModelDeps {
  rules?: ForwardRuleSource;
  runtime?: PortForwardRuntime;
  /** 每条规则的本地监听网关工厂（测试注入 fake） */
  makeListenGateway?: (ruleId: string) => ListenGateway;
  /** N15：native 数据面（生产 = nativeCore() 窄口适配） */
  nativeForward?: NativeForwardPort | null;
  /** N15：已 established 的会话句柄；0/缺省 = 无桥 */
  sessionHandle?: number;
  /** N15：native 事件路由（forwardOpen/Data/Close/Listen/Accept） */
  onNativeEvent?: (event: ForwardNativeEvent) => void;
}

/** forward 句柄记账归属 */
export type ForwardHandleOwner = 'socket' | 'dynamic' | 'remote';

export class PortForwardViewModel {
  private readonly rules: ForwardRuleSource | null;
  readonly runtime: PortForwardRuntime;
  private readonly makeListenGateway: ((ruleId: string) => ListenGateway) | null;
  private nativeForward: NativeForwardPort | null;
  private sessionHandle: number;
  private readonly onNativeEvent: ((event: ForwardNativeEvent) => void) | null;
  private sockets: Map<string, LocalForwardSocket> = new Map();
  /** ruleId → 动态 -D 会话（SOCKS5 → openDirectTcpip） */
  private dynamicSessions: Map<string, DynamicForwardSession> = new Map();
  /** forwardHandle → ruleId（native 事件路由） */
  private handleToRule: Map<number, string> = new Map();
  /** listenHandle → ruleId（远程 -R） */
  private listenToRule: Map<number, string> = new Map();
  /** forwardHandle → 记账归属：socket / dynamic / remote（避免双重累计流量） */
  private handleOwner: Map<number, ForwardHandleOwner> = new Map();
  /** remote accept 通道的流量槽 handle → [bytesIn, bytesOut] */
  private remoteTraffic: Map<number, number[]> = new Map();

  hostId: string = '';
  /** 空串 = 全部主机 */
  filterHostId: string = '';
  rows: PortForwardRow[] = [];
  logs: ForwardRuntimeLog[] = [];
  error: string = '';

  constructor(deps?: PortForwardViewModelDeps) {
    this.rules = deps?.rules ?? null;
    const nativePort: NativeForwardPort | null = deps?.nativeForward ?? null;
    this.nativeForward = nativePort;
    this.sessionHandle = deps?.sessionHandle ?? 0;
    this.onNativeEvent = deps?.onNativeEvent ?? null;
    const hasNative: boolean = nativePort !== null && this.sessionHandle > 0;
    this.runtime = deps?.runtime ??
      new PortForwardRuntime({ hasNativeChannel: hasNative });
    if (deps?.runtime !== undefined && hasNative) {
      this.runtime.setNativeChannelAvailable(true);
    }
    this.makeListenGateway = deps?.makeListenGateway ?? null;
  }

  /** N15：会话 established 后注入句柄并打开 runtime 的 native 开关 */
  attachSession(sessionHandle: number, nativeForward?: NativeForwardPort | null): void {
    this.sessionHandle = sessionHandle;
    if (nativeForward !== undefined && nativeForward !== null) {
      this.nativeForward = nativeForward;
    }
    const available: boolean = sessionHandle > 0 && this.nativeForward !== null;
    this.runtime.setNativeChannelAvailable(available);
  }

  /** 会话断开：关闭 native 开关（已 listening 的规则保持 listening，新连接回落 MVP） */
  detachSession(): void {
    this.sessionHandle = 0;
    this.runtime.setNativeChannelAvailable(false);
  }

  get nativeBridgeReady(): boolean {
    return this.nativeForward !== null && this.sessionHandle > 0;
  }

  load(hostId: string): void {
    this.hostId = hostId;
    this.filterHostId = hostId;
    this.reloadRows();
  }

  loadAll(): void {
    this.filterHostId = '';
    this.reloadRows();
  }

  reloadRows(): void {
    this.rows = [];
    if (this.rules === null) {
      this.error = '规则数据源未注入';
      return;
    }
    const list: PortForwardRule[] = this.filterHostId.length > 0
      ? this.rules.listByHostId(this.filterHostId)
      : this.rules.listAll();
    for (const rule of list) {
      this.runtime.registerRule(rule);
      const status: ForwardRuntimeStatus | null = this.runtime.statusOf(rule.id);
      this.rows.push({
        rule: rule,
        label: forwardRuleLabel(rule),
        status: status,
        canStart: canStartForwardRule(rule),
        running: status !== null && status.state === 'listening'
      });
    }
    this.logs = this.runtime.recentLogs();
  }

  /** 启动规则：runtime 状态机 + local 监听外壳（有桥时接 native） */
  start(ruleId: string): ForwardAction[] {
    const rule: PortForwardRule | null = this.rules !== null
      ? this.rules.getById(ruleId)
      : null;
    if (rule === null) {
      this.error = `规则不存在（${ruleId}）`;
      return [];
    }
    if (!canStartForwardRule(rule)) {
      this.error = '规则未启用或端口非法';
      return [];
    }
    const actions: ForwardAction[] = this.runtime.start(rule);
    if (rule.type === 'local') {
      this.ensureSocket(rule).start(
        rule.bindAddress.length > 0 ? rule.bindAddress : '127.0.0.1',
        rule.localPort
      );
    } else if (rule.type === 'dynamic') {
      // N15 -D：本地 SOCKS5 监听；CONNECT 后 openDirectTcpip（DynamicForwardSession）
      this.ensureDynamicSession(rule).start(
        rule.bindAddress.length > 0 ? rule.bindAddress : '127.0.0.1',
        rule.localPort
      );
    } else if (rule.type === 'remote' && this.nativeBridgeReady && this.nativeForward !== null) {
      // N15 -R：调 native remoteForwardListen；受理句柄经事件回报
      const remotePort: NativeRemoteListenPort | null =
        asNativeRemoteListenPort(this.nativeForward);
      if (remotePort !== null) {
        const listenHandle: number = remotePort.remoteForwardListen(
          this.sessionHandle,
          rule.bindAddress,
          rule.localPort
        );
        if (listenHandle > 0) {
          this.listenToRule.set(listenHandle, rule.id);
        } else {
          this.runtime.onListenError(rule.id, 'remoteForwardListen 未受理');
        }
      } else {
        this.runtime.onListenError(rule.id, 'native remoteForwardListen 不可用');
      }
    }
    for (const action of actions) {
      if (action.kind === 'logNativeMissing') {
        Logger.info(`转发 ${ruleId}: ${action.message}`, LOG_TAG);
      }
    }
    this.reloadRows();
    return actions;
  }

  stop(ruleId: string): ForwardAction[] {
    const actions: ForwardAction[] = this.runtime.stop(ruleId);
    const socket: LocalForwardSocket | undefined = this.sockets.get(ruleId);
    if (socket !== undefined) {
      socket.stop();
    }
    const dyn: DynamicForwardSession | undefined = this.dynamicSessions.get(ruleId);
    if (dyn !== undefined) {
      dyn.stop();
    }
    // 取消该规则的远程监听
    this.listenToRule.forEach((rid: string, handle: number) => {
      if (rid === ruleId && this.nativeForward !== null) {
        this.nativeForward.forwardClose(handle);
        this.listenToRule.delete(handle);
      }
    });
    this.reloadRows();
    return actions;
  }

  toggle(ruleId: string): ForwardAction[] {
    const st: ForwardRuntimeStatus | null = this.runtime.statusOf(ruleId);
    if (st !== null && st.state === 'listening') {
      return this.stop(ruleId);
    }
    return this.start(ruleId);
  }

  /**
   * N15：把 SessionManager 路由来的 native 转发事件分发到 runtime/socket。
   * 生产在 SessionManager.forwardEvent / PortForwardPage 订阅处调用。
   */
  handleNativeEvent(event: ForwardNativeEvent): void {
    if (this.onNativeEvent !== null) {
      this.onNativeEvent(event);
    }
    const fwd: number = event.forward ?? 0;
    if (event.type === 'forwardOpen' && event.success === true && fwd > 0) {
      // LocalForwardSocket / DynamicForwardSession 已在 openDirectTcpip 受理时登记；
      // 这里补 owner（若外壳未登记则按 remote 兜底不入账）
      Logger.info(`forwardOpen handle=${fwd}`, LOG_TAG);
    } else if (event.type === 'forwardData' && fwd > 0 && event.data !== undefined) {
      const data: ArrayBuffer = event.data;
      const owner: ForwardHandleOwner | undefined = this.handleOwner.get(fwd);
      if (owner === 'socket') {
        this.sockets.forEach((sock: LocalForwardSocket) => {
          sock.onRemoteData(fwd, data);
        });
      } else if (owner === 'dynamic') {
        this.dynamicSessions.forEach((dyn: DynamicForwardSession) => {
          if (dyn.ownsHandle(fwd)) {
            dyn.onRemoteData(fwd, data);
          }
        });
      } else if (owner === 'remote') {
        const ruleId: string | undefined = this.handleToRule.get(fwd);
        const t: number[] = this.remoteTrafficOf(fwd);
        t[0] += data.byteLength;
        if (ruleId !== undefined) {
          this.runtime.addTraffic(ruleId, data.byteLength, 0);
        }
      }
    } else if (event.type === 'forwardClose' && fwd > 0) {
      const owner: ForwardHandleOwner | undefined = this.handleOwner.get(fwd);
      const ruleId: string | undefined = this.handleToRule.get(fwd);
      const t: number[] = this.remoteTrafficOf(fwd);
      if (owner === 'socket') {
        this.sockets.forEach((sock: LocalForwardSocket) => {
          sock.onForwardClosed(fwd);
        });
      } else if (owner === 'dynamic') {
        this.dynamicSessions.forEach((dyn: DynamicForwardSession) => {
          if (dyn.ownsHandle(fwd)) {
            dyn.onForwardClosed(fwd);
          }
        });
      } else if (owner === 'remote' && ruleId !== undefined) {
        // 流量已在 forwardData 经 addTraffic 入账；close 只减连接数，避免双计
        this.runtime.onConnectionEnded(ruleId);
      }
      this.handleToRule.delete(fwd);
      this.handleOwner.delete(fwd);
      this.remoteTraffic.delete(fwd);
    } else if (event.type === 'forwardListen' && fwd > 0) {
      const ruleId: string | undefined = this.listenToRule.get(fwd);
      if (ruleId !== undefined && event.success === true) {
        const bound: number = event.boundPort ?? 0;
        this.runtime.onListenReady(ruleId, bound);
        Logger.info(`远程监听就绪 rule=${ruleId} boundPort=${bound}`, LOG_TAG);
      } else if (ruleId !== undefined && event.success === false) {
        this.runtime.onListenError(ruleId, event.message ?? '远程监听失败');
      }
    } else if (event.type === 'forwardAccept' && fwd > 0 && event.listen !== undefined) {
      const ruleId: string | undefined = this.listenToRule.get(event.listen);
      if (ruleId !== undefined) {
        this.runtime.onConnectionAccepted(ruleId);
        this.handleToRule.set(fwd, ruleId);
        this.handleOwner.set(fwd, 'remote');
        this.remoteTrafficOf(fwd);
        Logger.info(`远程入站 accept rule=${ruleId} handle=${fwd} origin=${event.origin ?? ''}`, LOG_TAG);
      }
    }
    this.logs = this.runtime.recentLogs();
    this.reloadRows();
  }

  /** 测试/诊断：forwardHandle 记账归属 */
  ownerOfHandle(forwardHandle: number): ForwardHandleOwner | null {
    return this.handleOwner.get(forwardHandle) ?? null;
  }

  private remoteTrafficOf(handle: number): number[] {
    let t: number[] | undefined = this.remoteTraffic.get(handle);
    if (t === undefined) {
      t = [0, 0];
      this.remoteTraffic.set(handle, t);
    }
    return t;
  }

  /** 测试/诊断：forwardHandle → ruleId */
  ruleOfHandle(forwardHandle: number): string | null {
    return this.handleToRule.get(forwardHandle) ?? null;
  }

  private ensureSocket(rule: PortForwardRule): LocalForwardSocket {
    const existing: LocalForwardSocket | undefined = this.sockets.get(rule.id);
    if (existing !== undefined) {
      return existing;
    }
    const gateway: ListenGateway | undefined = this.makeListenGateway !== null
      ? this.makeListenGateway(rule.id)
      : undefined;
    const socket: LocalForwardSocket = new LocalForwardSocket(rule.id, {
      gateway: gateway,
      onAccepted: (id: string) => this.runtime.onConnectionAccepted(id),
      onNativeMissing: (id: string, message: string) => {
        this.runtime.onListenError(id, message);
      },
      onClosed: (id: string, bin: number, bout: number) => {
        this.runtime.onConnectionClosed(id, bin, bout);
      },
      nativeForward: this.nativeForward,
      sessionHandle: this.sessionHandle,
      target: rule.type === 'local'
        ? { host: rule.remoteHost, port: rule.remotePort }
        : null,
      onChannelOpened: (id: string, _remoteInfo: string, handle: number) => {
        this.handleToRule.set(handle, id);
        this.handleOwner.set(handle, 'socket');
      }
    });
    this.sockets.set(rule.id, socket);
    return socket;
  }

  private ensureDynamicSession(rule: PortForwardRule): DynamicForwardSession {
    const existing: DynamicForwardSession | undefined = this.dynamicSessions.get(rule.id);
    if (existing !== undefined) {
      return existing;
    }
    const gateway: ListenGateway | undefined = this.makeListenGateway !== null
      ? this.makeListenGateway(rule.id)
      : undefined;
    const session: DynamicForwardSession = new DynamicForwardSession(rule.id, {
      gateway: gateway,
      onAccepted: (id: string) => this.runtime.onConnectionAccepted(id),
      onNativeMissing: (id: string, message: string) => {
        this.runtime.onListenError(id, message);
      },
      onClosed: (id: string, bin: number, bout: number) => {
        this.runtime.onConnectionClosed(id, bin, bout);
      },
      nativeForward: this.nativeForward,
      sessionHandle: this.sessionHandle,
      onChannelOpened: (id: string, _remoteInfo: string, handle: number) => {
        this.handleToRule.set(handle, id);
        this.handleOwner.set(handle, 'dynamic');
      }
    });
    this.dynamicSessions.set(rule.id, session);
    return session;
  }

  /** 测试/诊断：取动态会话（未启动过返回 null） */
  dynamicSessionOf(ruleId: string): DynamicForwardSession | null {
    return this.dynamicSessions.get(ruleId) ?? null;
  }

  /** 测试/诊断：取本地监听外壳 */
  socketOf(ruleId: string): LocalForwardSocket | null {
    return this.sockets.get(ruleId) ?? null;
  }
}

/**
 * N15 装配助手：生产由页面/SessionManager 探测
 * `isNativeForwardAvailable()`（napi/SshNative）后经 deps.nativeForward +
 * deps.sessionHandle 注入；本 VM 不直接 import .so，保持单测无系统依赖。
 */
export function defaultNativeForwardAvailable(): boolean {
  return false;
}

/** 类型别名导出：页面绑定用 */
export type PortForwardTypeName = PortForwardType;
