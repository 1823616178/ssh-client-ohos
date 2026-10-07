/**
 * PortForwardRuntime —— N15/U9 端口转发运行时纯逻辑状态机（DESIGN §7.3）。
 *
 * 边界（本文件头注即 native 工作清单）：
 *   - 规则 CRUD 已在 HostEdit（C1/U2），本模块只负责「启停 + 连接计数 + 流量记账」；
 *   - 本地转发（-L）：ArkTS TCPSocketServer 监听见 LocalForwardSocket.ets；
 *     **N15：native `openDirectTcpip` 桥可用时**（PortForwardDeps.hasNativeChannel=true，
 *     生产由 SshNative.isNativeForwardAvailable() + 已 established 会话装配），
 *     start() 进 listening 且 nativeChannelRequired=false，入站连接走
 *     LocalForwardSocket → openDirectTcpip；桥不可用时保持 MVP：
 *     listening + nativeChannelRequired=true + logNativeMissing；
 *   - 远程转发（-R）：native remoteForwardListen（libssh2_channel_forward_listen_ex）；
 *     本 runtime 只记状态，监听受理经 forwardListen 事件由 ViewModel 更新；
 *   - 动态转发（-D）：SOCKS5 握手在 Socks5.ets，CONNECT 后复用 openDirectTcpip；
 *   - ProxyJump：规划见 ProxyJump.ets；会话级串联 native 未打通（缺口已文档化）；
 *   - 流量统计：bytesIn/bytesOut 由 LocalForwardSocket 读写回调喂入。
 *
 * 纯逻辑、可注入、无系统 API：hypium 全覆盖；外壳（真实 socket）单独测。
 */

import { PortForwardRule, PortForwardType } from '../../common/model/models';

export type ForwardRuntimeState =
  'idle' | 'starting' | 'listening' | 'error' | 'stopped';

export interface ForwardRuntimeStatus {
  ruleId: string;
  type: PortForwardType;
  state: ForwardRuntimeState;
  /** 当前活跃本地连接数 */
  connections: number;
  bytesIn: number;
  bytesOut: number;
  errorMessage: string;
  /** true = 需要 native direct-tcpip 通道但当前不可用 */
  nativeChannelRequired: boolean;
  /** 监听地址:端口（展示用） */
  listenLabel: string;
}

/** 运行时日志条目（UI 可展示；不含密钥） */
export interface ForwardRuntimeLog {
  ruleId: string;
  message: string;
}

/** 外壳动作（LocalForwardSocket / 日志） */
export type ForwardActionKind =
  | 'listenStart'
  | 'listenStop'
  | 'logNativeMissing'
  | 'logError';

export interface ForwardAction {
  kind: ForwardActionKind;
  ruleId: string;
  message: string;
}

function listenLabelOf(rule: PortForwardRule): string {
  if (rule.type === 'remote') {
    return `remote :${rule.localPort}`;
  }
  return `${rule.bindAddress}:${rule.localPort}`;
}

function emptyStatus(rule: PortForwardRule): ForwardRuntimeStatus {
  return {
    ruleId: rule.id,
    type: rule.type,
    state: 'idle',
    connections: 0,
    bytesIn: 0,
    bytesOut: 0,
    errorMessage: '',
    nativeChannelRequired: false,
    listenLabel: listenLabelOf(rule)
  };
}

export interface PortForwardDeps {
  /**
   * native direct-tcpip / remote listen 是否可用。
   * N15：生产装配 PortForwardViewModel 时传
   * isNativeForwardAvailable() && sessionHandle>0；默认 false（无桥 MVP）。
   */
  hasNativeChannel?: boolean;
  /** 日志收集（可选） */
  onLog?: (entry: ForwardRuntimeLog) => void;
}

/**
 * 规则启停状态机。
 * 同一 ruleId 重复 start：已 listening 返回已有状态（幂等）；
 * stop 幂等。
 */
export class PortForwardRuntime {
  private statuses: Map<string, ForwardRuntimeStatus> = new Map();
  private rules: Map<string, PortForwardRule> = new Map();
  private logs: ForwardRuntimeLog[] = [];
  private hasNativeChannel: boolean;
  private readonly onLog: ((entry: ForwardRuntimeLog) => void) | null;

  constructor(deps?: PortForwardDeps) {
    this.hasNativeChannel = deps?.hasNativeChannel ?? false;
    this.onLog = deps?.onLog ?? null;
  }

  /** 注册/更新规则元数据（不自动启停） */
  registerRule(rule: PortForwardRule): void {
    this.rules.set(rule.id, rule);
    if (!this.statuses.has(rule.id)) {
      this.statuses.set(rule.id, emptyStatus(rule));
    }
  }

  unregisterRule(ruleId: string): ForwardAction[] {
    const actions: ForwardAction[] = this.stop(ruleId);
    this.rules.delete(ruleId);
    this.statuses.delete(ruleId);
    return actions;
  }

  statusOf(ruleId: string): ForwardRuntimeStatus | null {
    return this.statuses.get(ruleId) ?? null;
  }

  listStatuses(): ForwardRuntimeStatus[] {
    const out: ForwardRuntimeStatus[] = [];
    this.statuses.forEach((st: ForwardRuntimeStatus) => {
      out.push({
        ruleId: st.ruleId,
        type: st.type,
        state: st.state,
        connections: st.connections,
        bytesIn: st.bytesIn,
        bytesOut: st.bytesOut,
        errorMessage: st.errorMessage,
        nativeChannelRequired: st.nativeChannelRequired,
        listenLabel: st.listenLabel
      });
    });
    return out;
  }

  recentLogs(): ForwardRuntimeLog[] {
    return this.logs.slice();
  }

  /**
   * 启动一条规则。
   * 返回外壳要执行的动作序列；状态已更新。
   * native 通道缺失时仍进 listening（本地监听骨架可跑），但
   * nativeChannelRequired=true 且附加 logNativeMissing。
   */
  start(rule: PortForwardRule): ForwardAction[] {
    this.registerRule(rule);
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(rule.id);
    if (st === undefined) {
      return [];
    }
    if (st.state === 'listening') {
      return [];
    }
    st.state = 'starting';
    st.errorMessage = '';
    st.connections = 0;
    st.bytesIn = 0;
    st.bytesOut = 0;

    const actions: ForwardAction[] = [];
    if (rule.localPort <= 0) {
      st.state = 'error';
      st.errorMessage = '本地端口非法';
      actions.push({
        kind: 'logError',
        ruleId: rule.id,
        message: st.errorMessage
      });
      this.pushLog(rule.id, st.errorMessage);
      return actions;
    }

    // remote/dynamic 的完整实现依赖 native；N15 桥可用时 needsNative=false
    const needsNative: boolean = !this.hasNativeChannel;
    st.nativeChannelRequired = needsNative;
    st.state = 'listening';
    actions.push({
      kind: 'listenStart',
      ruleId: rule.id,
      message: listenLabelOf(rule)
    });
    if (needsNative) {
      const msg: string = '需已连接的 SSH 会话才能打开转发通道';
      actions.push({
        kind: 'logNativeMissing',
        ruleId: rule.id,
        message: msg
      });
      this.pushLog(rule.id, msg);
    }
    return actions;
  }

  /** N15：装配后切换 native 可用性（会话 established / 断开时由 ViewModel 调） */
  setNativeChannelAvailable(available: boolean): void {
    this.hasNativeChannel = available;
  }

  stop(ruleId: string): ForwardAction[] {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined) {
      return [];
    }
    if (st.state === 'idle' || st.state === 'stopped') {
      st.state = 'stopped';
      return [];
    }
    st.state = 'stopped';
    st.connections = 0;
    st.nativeChannelRequired = false;
    return [{
      kind: 'listenStop',
      ruleId: ruleId,
      message: st.listenLabel
    }];
  }

  /** 本地连接被接受（LocalForwardSocket 回调 / forwardAccept 事件） */
  onConnectionAccepted(ruleId: string): void {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined || st.state !== 'listening') {
      return;
    }
    st.connections++;
  }

  /**
   * 连接关闭且流量未知或仅事件路径（forwardClose）：只减连接数。
   * 已知流量请用 onConnectionClosed。
   */
  onConnectionEnded(ruleId: string): void {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined) {
      return;
    }
    if (st.connections > 0) {
      st.connections--;
    }
  }

  /** 连接关闭并上报流量 */
  onConnectionClosed(ruleId: string, bytesIn: number, bytesOut: number): void {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined) {
      return;
    }
    if (st.connections > 0) {
      st.connections--;
    }
    if (bytesIn > 0) {
      st.bytesIn += bytesIn;
    }
    if (bytesOut > 0) {
      st.bytesOut += bytesOut;
    }
  }

  /** 外壳报告监听失败 */
  onListenError(ruleId: string, message: string): void {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined) {
      return;
    }
    st.state = 'error';
    st.errorMessage = message;
    this.pushLog(ruleId, message);
  }

  /**
   * N15：运行时流量入账（forwardData 等 native 事件）。
   * 与 onConnectionClosed 的区别：不减连接数，供 UI 实时展示 bytesIn/out。
   */
  addTraffic(ruleId: string, bytesIn: number, bytesOut: number): void {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined) {
      return;
    }
    if (bytesIn > 0) {
      st.bytesIn += bytesIn;
    }
    if (bytesOut > 0) {
      st.bytesOut += bytesOut;
    }
  }

  /** N15 -R：远程监听受理成功（forwardListen 事件），更新展示用 boundPort */
  onListenReady(ruleId: string, boundPort: number): void {
    const st: ForwardRuntimeStatus | undefined = this.statuses.get(ruleId);
    if (st === undefined) {
      return;
    }
    if (boundPort > 0) {
      st.listenLabel = `remote :${boundPort}`;
    }
    if (st.state === 'starting' || st.state === 'idle') {
      st.state = 'listening';
    }
    st.errorMessage = '';
  }

  private pushLog(ruleId: string, message: string): void {
    const entry: ForwardRuntimeLog = { ruleId: ruleId, message: message };
    this.logs.push(entry);
    if (this.logs.length > 200) {
      this.logs.splice(0, this.logs.length - 200);
    }
    if (this.onLog !== null) {
      this.onLog(entry);
    }
  }
}

/** 纯函数：规则在当前 runtime 配置下能否 start（不修改状态） */
export function canStartForwardRule(rule: PortForwardRule): boolean {
  return rule.enabled && rule.localPort > 0;
}

/** 纯函数：展示标签 */
export function forwardRuleLabel(rule: PortForwardRule): string {
  const typeName: string = rule.type === 'local'
    ? '本地 -L'
    : rule.type === 'remote' ? '远程 -R' : '动态 -D';
  if (rule.type === 'local') {
    return `${typeName} ${rule.bindAddress}:${rule.localPort} → ` +
      `${rule.remoteHost}:${rule.remotePort}`;
  }
  if (rule.type === 'remote') {
    return `${typeName} 远端 :${rule.localPort} → ${rule.remoteHost}:${rule.remotePort}`;
  }
  return `${typeName} ${rule.bindAddress}:${rule.localPort} (SOCKS5)`;
}
