/**
 * LocalForwardSocket —— U9/N15 本地转发（-L）与动态转发（-D）的 TCPSocketServer 外壳。
 *
 * DESIGN §7.3：ArkTS `@ohos.net.socket` TCPSocketServer 监听，收到连接后
 * 交给 native 开 `direct-tcpip` 通道。
 *
 * N15 接入：
 *   - 注入 NativeForwardPort（openDirectTcpip / forwardWrite / forwardClose）
 *     与 sessionHandle + 目标（-L 的 remoteHost:remotePort）时，入站连接
 *     调 openDirectTcpip，成功则保持连接回调打开、把本地字节桥到
 *     forwardWrite，native forwardData 事件经 onRemoteData 回写本地 socket
 *     （真实 socket 桥由页面层 SystemListenGateway 完成；本类只驱动 native
 *     通道生命周期与流量记账）；
 *   - 无 native / 无会话：保持 MVP 行为——记 logNativeMissing 并关闭。
 *
 * 动态 -D：Socks5Handshake 在本外壳之外（DynamicForwardSession）跑完
 * CONNECT 解析后，同样走 openDirectTcpip；本文件不实现 SOCKS 字节。
 *
 * 可注入：ListenGateway 抽象系统 socket，单测用 fake。
 */

import { Logger } from '../../common/utils/Logger';

const LOG_TAG: string = 'LocalForwardSocket';

export interface ListenGateway {
  /** 开始监听；false = 端口占用/权限等 */
  listen(bindAddress: string, port: number): boolean;
  stop(): void;
  /** 注册连接回调（生产由系统事件驱动；fake 由测试手动触发） */
  onConnection(cb: (remoteInfo: string) => void): void;
  /** 可选：向某条本地连接写回字节（生产 TCPSocket 实现；fake 可空） */
  sendToConnection?(remoteInfo: string, data: ArrayBuffer): boolean;
}

/** 无系统 API 的空实现（单测默认） */
export class NullListenGateway implements ListenGateway {
  private cb: ((remoteInfo: string) => void) | null = null;
  listening: boolean = false;

  listen(_bindAddress: string, port: number): boolean {
    this.listening = port > 0;
    return this.listening;
  }

  stop(): void {
    this.listening = false;
  }

  onConnection(cb: (remoteInfo: string) => void): void {
    this.cb = cb;
  }

  sendToConnection(_remoteInfo: string, _data: ArrayBuffer): boolean {
    return false;
  }

  /** 测试驱动：模拟一个入站连接 */
  simulateConnection(remoteInfo: string): void {
    if (this.cb !== null) {
      this.cb(remoteInfo);
    }
  }
}

/** N15：native 转发数据面窄口（生产 = nativeCore()，测试 = fake） */
export interface NativeForwardPort {
  openDirectTcpip(sessionHandle: number, host: string, port: number): number;
  forwardWrite(forwardHandle: number, data: ArrayBuffer | string): boolean;
  forwardClose(forwardHandle: number): boolean;
}

export interface LocalForwardTarget {
  host: string;
  port: number;
}

export interface LocalForwardSocketDeps {
  gateway?: ListenGateway;
  /** 通知 runtime：接受连接 / 缺 native / 关闭 */
  onAccepted?: (ruleId: string) => void;
  onNativeMissing?: (ruleId: string, message: string) => void;
  onClosed?: (ruleId: string, bytesIn: number, bytesOut: number) => void;
  /** N15：native 数据面；未注入 = MVP 模式 */
  nativeForward?: NativeForwardPort | null;
  /** 已 established 的会话句柄；0 = 无会话 */
  sessionHandle?: number;
  /** -L 目标（remoteHost:remotePort）；空 = 不开通道（-D 由外部先解析） */
  target?: LocalForwardTarget | null;
  /** native forwardOpen 成功回调（句柄登记） */
  onChannelOpened?: (ruleId: string, remoteInfo: string, forwardHandle: number) => void;
}

/**
 * 单条 -L 规则的本地监听外壳。
 * start → gateway.listen；每个入站连接：
 *   - 有 native + session + target → openDirectTcpip，受理后保持连接；
 *   - 否则 onAccepted + onNativeMissing + 立即关闭。
 */
export class LocalForwardSocket {
  private readonly ruleId: string;
  private readonly gateway: ListenGateway;
  private readonly onAccepted: ((ruleId: string) => void) | null;
  private readonly onNativeMissing: ((ruleId: string, message: string) => void) | null;
  private readonly onClosed: ((ruleId: string, bytesIn: number, bytesOut: number) => void) | null;
  private readonly nativeForward: NativeForwardPort | null;
  private readonly sessionHandle: number;
  private readonly target: LocalForwardTarget | null;
  private readonly onChannelOpened: ((ruleId: string, remoteInfo: string, forwardHandle: number) => void) | null;
  private started: boolean = false;
  /** remoteInfo → native forward handle */
  private channels: Map<string, number> = new Map();
  /** remoteInfo → 累计流量 */
  private traffic: Map<string, number[]> = new Map();

  constructor(ruleId: string, deps?: LocalForwardSocketDeps) {
    this.ruleId = ruleId;
    this.gateway = deps?.gateway ?? new NullListenGateway();
    this.onAccepted = deps?.onAccepted ?? null;
    this.onNativeMissing = deps?.onNativeMissing ?? null;
    this.onClosed = deps?.onClosed ?? null;
    this.nativeForward = deps?.nativeForward ?? null;
    this.sessionHandle = deps?.sessionHandle ?? 0;
    this.target = deps?.target ?? null;
    this.onChannelOpened = deps?.onChannelOpened ?? null;
    this.gateway.onConnection((info: string) => this.handleInbound(info));
  }

  get isStarted(): boolean {
    return this.started;
  }

  /** 当前是否具备 native 桥接条件（runtime 据此置 nativeChannelRequired=false） */
  get hasNativeBridge(): boolean {
    return this.nativeForward !== null && this.sessionHandle > 0 &&
      this.target !== null && this.target.host.length > 0 && this.target.port > 0;
  }

  get activeChannelCount(): number {
    return this.channels.size;
  }

  start(bindAddress: string, port: number): boolean {
    if (this.started) {
      return true;
    }
    const ok: boolean = this.gateway.listen(bindAddress, port);
    this.started = ok;
    if (!ok) {
      Logger.error(`本地转发监听失败 ${bindAddress}:${port}（rule=${this.ruleId}）`, LOG_TAG);
    }
    return ok;
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    if (this.nativeForward !== null) {
      this.channels.forEach((handle: number, remoteInfo: string) => {
        this.nativeForward?.forwardClose(handle);
        this.reportClosed(remoteInfo);
      });
    }
    this.channels.clear();
    this.traffic.clear();
    this.gateway.stop();
    this.started = false;
  }

  /** 本地 → 远端：外壳在收到本地 socket 字节时调用 */
  writeToRemote(remoteInfo: string, data: ArrayBuffer): boolean {
    const handle: number | undefined = this.channels.get(remoteInfo);
    if (handle === undefined || this.nativeForward === null) {
      return false;
    }
    const ok: boolean = this.nativeForward.forwardWrite(handle, data);
    if (ok) {
      const t: number[] = this.trafficOf(remoteInfo);
      t[1] += data.byteLength; // bytesOut
    }
    return ok;
  }

  /** 远端 → 本地：native forwardData 事件路由进来；经 gateway 写回 */
  onRemoteData(forwardHandle: number, data: ArrayBuffer): void {
    let remoteInfo: string = '';
    this.channels.forEach((handle: number, info: string) => {
      if (handle === forwardHandle) {
        remoteInfo = info;
      }
    });
    if (remoteInfo.length === 0) {
      return;
    }
    const t: number[] = this.trafficOf(remoteInfo);
    t[0] += data.byteLength; // bytesIn
    if (this.gateway.sendToConnection !== undefined) {
      this.gateway.sendToConnection(remoteInfo, data);
    }
  }

  /** native forwardClose / 通道终结 */
  onForwardClosed(forwardHandle: number): void {
    let remoteInfo: string = '';
    let found: boolean = false;
    this.channels.forEach((handle: number, info: string) => {
      if (handle === forwardHandle) {
        remoteInfo = info;
        found = true;
      }
    });
    if (!found) {
      return;
    }
    this.channels.delete(remoteInfo);
    this.reportClosed(remoteInfo);
  }

  private handleInbound(remoteInfo: string): void {
    if (this.onAccepted !== null) {
      this.onAccepted(this.ruleId);
    }
    if (!this.hasNativeBridge || this.nativeForward === null || this.target === null) {
      Logger.info(
        `本地转发入站 rule=${this.ruleId} from=${remoteInfo} — native channel open required`,
        LOG_TAG
      );
      if (this.onNativeMissing !== null) {
        this.onNativeMissing(this.ruleId, '需已连接的 SSH 会话才能打开转发通道');
      }
      if (this.onClosed !== null) {
        this.onClosed(this.ruleId, 0, 0);
      }
      return;
    }
    const handle: number = this.nativeForward.openDirectTcpip(
      this.sessionHandle,
      this.target.host,
      this.target.port
    );
    if (handle <= 0) {
      Logger.error(
        `direct-tcpip 未受理 rule=${this.ruleId} → ${this.target.host}:${this.target.port}`,
        LOG_TAG
      );
      if (this.onNativeMissing !== null) {
        this.onNativeMissing(this.ruleId, 'openDirectTcpip 未受理');
      }
      if (this.onClosed !== null) {
        this.onClosed(this.ruleId, 0, 0);
      }
      return;
    }
    this.channels.set(remoteInfo, handle);
    this.trafficOf(remoteInfo); // 初始化流量槽
    Logger.info(
      `direct-tcpip 已受理 rule=${this.ruleId} handle=${handle} ` +
        `from=${remoteInfo} → ${this.target.host}:${this.target.port}`,
      LOG_TAG
    );
    if (this.onChannelOpened !== null) {
      this.onChannelOpened(this.ruleId, remoteInfo, handle);
    }
  }

  private trafficOf(remoteInfo: string): number[] {
    let t: number[] | undefined = this.traffic.get(remoteInfo);
    if (t === undefined) {
      t = [0, 0];
      this.traffic.set(remoteInfo, t);
    }
    return t;
  }

  private reportClosed(remoteInfo: string): void {
    const t: number[] | undefined = this.traffic.get(remoteInfo);
    const bin: number = t !== undefined ? t[0] : 0;
    const bout: number = t !== undefined ? t[1] : 0;
    this.traffic.delete(remoteInfo);
    if (this.onClosed !== null) {
      this.onClosed(this.ruleId, bin, bout);
    }
  }
}
