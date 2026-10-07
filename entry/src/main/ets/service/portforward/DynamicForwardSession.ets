/**
 * DynamicForwardSession —— N15 动态转发（-D）外壳（DESIGN §7.3）。
 *
 * 每条本地连接：
 *   1. 跑 Socks5Handshake（greeting → CONNECT）；
 *   2. CONNECT 解析完成后 native openDirectTcpip(connectHost, connectPort)；
 *   3. 成功回 SOCKS5 success reply 并透传；失败回 REP=0x05/0x07/0x08 并关本地连接。
 *
 * 与 LocalForwardSocket 的差别：无固定 target，目标来自 SOCKS5 CONNECT。
 * 可注入：ListenGateway / NativeForwardPort / onClientReply，hypium 全覆盖。
 */

import { Logger } from '../../common/utils/Logger';
import {
  ListenGateway,
  NativeForwardPort,
  NullListenGateway
} from './LocalForwardSocket';
import { Socks5Handshake, Socks5Phase } from './Socks5';

const LOG_TAG: string = 'DynamicForwardSession';

/** 本地字节喂入后的动作结果（测试与生产网关共用） */
export interface DynamicLocalResult {
  /** 需写回本地客户端的握手/应答字节 */
  replies: number[];
  /** 本次 openDirectTcpip 受理句柄；0 = 未开或失败 */
  openedHandle: number;
  /** 本地连接是否应关闭（握手失败 / native 不可用） */
  closed: boolean;
  errorMessage: string;
  phase: Socks5Phase;
}

export interface DynamicForwardSessionDeps {
  gateway?: ListenGateway;
  onAccepted?: (ruleId: string) => void;
  onNativeMissing?: (ruleId: string, message: string) => void;
  onClosed?: (ruleId: string, bytesIn: number, bytesOut: number) => void;
  nativeForward?: NativeForwardPort | null;
  sessionHandle?: number;
  onChannelOpened?: (ruleId: string, remoteInfo: string, forwardHandle: number) => void;
  /** 握手应答写回本地客户端（生产 TCPSocket；测试收集） */
  onClientReply?: (remoteInfo: string, bytes: number[]) => void;
}

interface DynamicConn {
  handshake: Socks5Handshake;
  /** native forward 句柄；0 = 尚未受理 */
  forwardHandle: number;
  bytesIn: number;
  bytesOut: number;
}

function emptyLocalResult(phase: Socks5Phase): DynamicLocalResult {
  return {
    replies: [],
    openedHandle: 0,
    closed: false,
    errorMessage: '',
    phase: phase
  };
}

/** 单条 -D 规则：本地监听 + 每连接 SOCKS5 → openDirectTcpip */
export class DynamicForwardSession {
  private readonly ruleId: string;
  private readonly gateway: ListenGateway;
  private readonly onAccepted: ((ruleId: string) => void) | null;
  private readonly onNativeMissing: ((ruleId: string, message: string) => void) | null;
  private readonly onClosed: ((ruleId: string, bytesIn: number, bytesOut: number) => void) | null;
  private readonly nativeForward: NativeForwardPort | null;
  private readonly sessionHandle: number;
  private readonly onChannelOpened: ((ruleId: string, remoteInfo: string, forwardHandle: number) => void) | null;
  private readonly onClientReply: ((remoteInfo: string, bytes: number[]) => void) | null;
  private started: boolean = false;
  /** remoteInfo → 连接状态 */
  private conns: Map<string, DynamicConn> = new Map();
  /** forwardHandle → remoteInfo */
  private handleToConn: Map<number, string> = new Map();

  constructor(ruleId: string, deps?: DynamicForwardSessionDeps) {
    this.ruleId = ruleId;
    this.gateway = deps?.gateway ?? new NullListenGateway();
    this.onAccepted = deps?.onAccepted ?? null;
    this.onNativeMissing = deps?.onNativeMissing ?? null;
    this.onClosed = deps?.onClosed ?? null;
    this.nativeForward = deps?.nativeForward ?? null;
    this.sessionHandle = deps?.sessionHandle ?? 0;
    this.onChannelOpened = deps?.onChannelOpened ?? null;
    this.onClientReply = deps?.onClientReply ?? null;
    this.gateway.onConnection((info: string) => this.handleInbound(info));
  }

  get isStarted(): boolean {
    return this.started;
  }

  get hasNativeBridge(): boolean {
    return this.nativeForward !== null && this.sessionHandle > 0;
  }

  get activeChannelCount(): number {
    let n: number = 0;
    this.conns.forEach((conn: DynamicConn) => {
      if (conn.forwardHandle > 0) {
        n++;
      }
    });
    return n;
  }

  get activeConnCount(): number {
    return this.conns.size;
  }

  start(bindAddress: string, port: number): boolean {
    if (this.started) {
      return true;
    }
    const ok: boolean = this.gateway.listen(bindAddress, port);
    this.started = ok;
    if (!ok) {
      Logger.error(`动态转发监听失败 ${bindAddress}:${port}（rule=${this.ruleId}）`, LOG_TAG);
    }
    return ok;
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    const infos: string[] = [];
    if (this.nativeForward !== null) {
      this.handleToConn.forEach((remoteInfo: string, handle: number) => {
        this.nativeForward?.forwardClose(handle);
        infos.push(remoteInfo);
      });
    }
    for (const info of infos) {
      this.dropConn(info);
    }
    this.conns.clear();
    this.handleToConn.clear();
    this.gateway.stop();
    this.started = false;
  }

  /**
   * 本地 → 本会话：握手阶段喂 Socks5Handshake；connected 后桥到 forwardWrite。
   * 返回应写回本地的字节与是否开/关通道。
   */
  onLocalData(remoteInfo: string, data: Uint8Array): DynamicLocalResult {
    const conn: DynamicConn | undefined = this.conns.get(remoteInfo);
    if (conn === undefined) {
      return emptyLocalResult('error');
    }
    if (conn.handshake.isComplete) {
      // CONNECT 已成功：透传 payload 到 native
      if (conn.forwardHandle > 0 && this.nativeForward !== null && data.length > 0) {
        const buf: ArrayBuffer = uint8ToArrayBuffer(data);
        const ok: boolean = this.nativeForward.forwardWrite(conn.forwardHandle, buf);
        if (ok) {
          conn.bytesOut += data.byteLength;
        }
      }
      return emptyLocalResult('connected');
    }
    if (conn.handshake.hasError) {
      return emptyLocalResult('error');
    }

    const feed = conn.handshake.feed(data);
    const result: DynamicLocalResult = emptyLocalResult(feed.phase);
    result.replies = feed.reply.slice();
    result.phase = feed.phase;

    if (feed.readyToConnect) {
      const host: string = conn.handshake.connectHost;
      const port: number = conn.handshake.connectPort;
      if (!this.hasNativeBridge || this.nativeForward === null) {
        const msg: string = '需已连接的 SSH 会话才能打开转发通道';
        result.replies.push(...conn.handshake.failConnect(0x05, msg));
        result.closed = true;
        result.errorMessage = msg;
        result.phase = conn.handshake.currentPhase;
        this.emitReply(remoteInfo, result.replies);
        if (this.onNativeMissing !== null) {
          this.onNativeMissing(this.ruleId, msg);
        }
        this.dropConn(remoteInfo);
        return result;
      }
      const handle: number = this.nativeForward.openDirectTcpip(
        this.sessionHandle,
        host,
        port
      );
      if (handle > 0) {
        conn.forwardHandle = handle;
        this.handleToConn.set(handle, remoteInfo);
        result.replies.push(...conn.handshake.completeConnect());
        result.openedHandle = handle;
        result.phase = conn.handshake.currentPhase;
        Logger.info(
          `动态转发 CONNECT 受理 rule=${this.ruleId} handle=${handle} → ${host}:${port}`,
          LOG_TAG
        );
        if (this.onChannelOpened !== null) {
          this.onChannelOpened(this.ruleId, remoteInfo, handle);
        }
      } else {
        const msg: string = `openDirectTcpip 未受理 → ${host}:${port}`;
        result.replies.push(...conn.handshake.failConnect(0x05, msg));
        result.closed = true;
        result.errorMessage = msg;
        result.phase = conn.handshake.currentPhase;
        Logger.error(`动态转发 CONNECT 失败 rule=${this.ruleId} ${msg}`, LOG_TAG);
        if (this.onNativeMissing !== null) {
          this.onNativeMissing(this.ruleId, msg);
        }
        this.dropConn(remoteInfo);
      }
    } else if (feed.errorMessage.length > 0 || feed.phase === 'error') {
      // BIND / 非法 ATYP 等已在 handshake 内写好 error reply
      result.closed = true;
      result.errorMessage = feed.errorMessage;
      result.phase = 'error';
      this.dropConn(remoteInfo);
    }

    if (result.replies.length > 0) {
      this.emitReply(remoteInfo, result.replies);
    }
    return result;
  }

  /** 远端 → 本地：native forwardData 事件 */
  onRemoteData(forwardHandle: number, data: ArrayBuffer): void {
    const remoteInfo: string | undefined = this.handleToConn.get(forwardHandle);
    if (remoteInfo === undefined) {
      return;
    }
    const conn: DynamicConn | undefined = this.conns.get(remoteInfo);
    if (conn === undefined) {
      return;
    }
    conn.bytesIn += data.byteLength;
    if (this.gateway.sendToConnection !== undefined) {
      this.gateway.sendToConnection(remoteInfo, data);
    }
  }

  /** native forwardClose / 通道终结 */
  onForwardClosed(forwardHandle: number): void {
    const remoteInfo: string | undefined = this.handleToConn.get(forwardHandle);
    if (remoteInfo === undefined) {
      return;
    }
    this.handleToConn.delete(forwardHandle);
    this.dropConn(remoteInfo);
  }

  /** 测试/诊断：某连接当前握手状态 */
  connDebug(remoteInfo: string): DynamicConnDebug | null {
    const conn: DynamicConn | undefined = this.conns.get(remoteInfo);
    if (conn === undefined) {
      return null;
    }
    return {
      phase: conn.handshake.currentPhase,
      host: conn.handshake.connectHost,
      port: conn.handshake.connectPort,
      handle: conn.forwardHandle,
      bytesIn: conn.bytesIn,
      bytesOut: conn.bytesOut
    };
  }

  /** 本会话是否拥有该 native 句柄 */
  ownsHandle(forwardHandle: number): boolean {
    return this.handleToConn.has(forwardHandle);
  }

  private handleInbound(remoteInfo: string): void {
    if (this.onAccepted !== null) {
      this.onAccepted(this.ruleId);
    }
    if (this.conns.has(remoteInfo)) {
      return;
    }
    this.conns.set(remoteInfo, {
      handshake: new Socks5Handshake(),
      forwardHandle: 0,
      bytesIn: 0,
      bytesOut: 0
    });
  }

  private dropConn(remoteInfo: string): void {
    const conn: DynamicConn | undefined = this.conns.get(remoteInfo);
    if (conn === undefined) {
      return;
    }
    if (conn.forwardHandle > 0) {
      this.handleToConn.delete(conn.forwardHandle);
    }
    this.conns.delete(remoteInfo);
    if (this.onClosed !== null) {
      this.onClosed(this.ruleId, conn.bytesIn, conn.bytesOut);
    }
  }

  private emitReply(remoteInfo: string, bytes: number[]): void {
    if (bytes.length === 0) {
      return;
    }
    if (this.onClientReply !== null) {
      this.onClientReply(remoteInfo, bytes.slice());
    }
  }
}

export interface DynamicConnDebug {
  phase: Socks5Phase;
  host: string;
  port: number;
  handle: number;
  bytesIn: number;
  bytesOut: number;
}

function uint8ToArrayBuffer(data: Uint8Array): ArrayBuffer {
  const out: ArrayBuffer = new ArrayBuffer(data.length);
  const view: Uint8Array = new Uint8Array(out);
  for (let i = 0; i < data.length; i++) {
    view[i] = data[i];
  }
  return out;
}

/**
 * 纯编排助手：把 Socks5 握手 feed + openDirectTcpip 结果合成写回字节。
 * DynamicForwardSession 内部已实现；此处导出便于单测直接断言 CONNECT IPv4/域名/错误回复。
 */
export function socks5ApplyConnectResult(
  handshake: Socks5Handshake,
  openedHandle: number
): DynamicLocalResult {
  const r: DynamicLocalResult = emptyLocalResult(handshake.currentPhase);
  if (openedHandle > 0) {
    r.replies = handshake.completeConnect();
    r.openedHandle = openedHandle;
  } else {
    r.replies = handshake.failConnect(0x05, 'openDirectTcpip 未受理');
    r.closed = true;
    r.errorMessage = 'openDirectTcpip 未受理';
  }
  r.phase = handshake.currentPhase;
  return r;
}
