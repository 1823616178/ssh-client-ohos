/**
 * Socks5 —— N15 动态转发（-D）的纯逻辑 SOCKS5 握手（DESIGN §7.3）。
 *
 * 只做字节级状态机，不碰 socket / native：
 *   1. greeting：VER=5, NMETHODS, METHODS… → 选 NO AUTH(0x00)，回 VER+METHOD
 *   2. request：VER=5, CMD, RSV, ATYP, ADDR, PORT
 *      CMD 仅支持 CONNECT(0x01)；BIND/UDP 关联回 REP=0x07
 *      ATYP: 0x01 IPv4 / 0x03 DOMAINNAME / 0x04 IPv6
 *   3. 解析出 connectHost/connectPort 后，外壳调 native openDirectTcpip，
 *      成功后回 success reply，失败回 REP=0x05
 *
 * 输入用 Uint8Array（ArkTS 无 Buffer）；返回 consumed 指示本批消费字节数，
 * 调用方保留未消费尾部。
 * 纯逻辑、可注入：hypium 全覆盖。
 */

export type Socks5Phase = 'greeting' | 'request' | 'connected' | 'error';

export type Socks5ReplyCode =
  | 0x00 // succeeded
  | 0x01 // general failure
  | 0x02 // not allowed
  | 0x03 // network unreachable
  | 0x04 // host unreachable
  | 0x05 // connection refused
  | 0x06 // TTL expired
  | 0x07 // command not supported
  | 0x08 // address type not supported
  ;

export interface Socks5Result {
  phase: Socks5Phase;
  /** 本批消费字节数（调用方丢弃前 consumed 字节） */
  consumed: number;
  /** 需要写回客户端的字节（greeting 选方法 / CONNECT 应答） */
  reply: number[];
  /** request 成功解析后的目标（仅 phase 仍为 request 且 connect 目标合法时） */
  connectHost: string;
  connectPort: number;
  /** 是否已解析出 CONNECT 目标（外壳据此开 direct-tcpip） */
  readyToConnect: boolean;
  errorMessage: string;
}

function emptyResult(): Socks5Result {
  return {
    phase: 'greeting',
    consumed: 0,
    reply: [],
    connectHost: '',
    connectPort: 0,
    readyToConnect: false,
    errorMessage: ''
  };
}

/** 失败回复：VER=5, REP, RSV=0, ATYP=1, BND.ADDR=0.0.0.0, BND.PORT=0 */
export function socks5ErrorReply(code: Socks5ReplyCode): number[] {
  return [0x05, code, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
}

/** 成功回复：VER=5, REP=0, RSV=0, ATYP=1, BND=0.0.0.0:0（足够客户端继续） */
export function socks5SuccessReply(): number[] {
  return socks5ErrorReply(0x00);
}

/**
 * 处理 greeting（客户端 → 服务端）。
 * 字节不足时 consumed=0 且 phase 仍 greeting；非法版本/无可用方法 → error。
 * 仅接受 NO AUTH(0x00)；若未提供则回 0xFF 并 error。
 */
export function socks5ProcessGreeting(bytes: Uint8Array): Socks5Result {
  const r: Socks5Result = emptyResult();
  if (bytes.length < 2) {
    return r;
  }
  const ver: number = bytes[0];
  const nMethods: number = bytes[1];
  if (ver !== 0x05) {
    r.phase = 'error';
    r.consumed = bytes.length;
    r.errorMessage = '非法 SOCKS 版本';
    r.reply = [0x05, 0xFF];
    return r;
  }
  if (bytes.length < 2 + nMethods) {
    return r; // 等待更多字节
  }
  let noAuth: boolean = false;
  for (let i = 0; i < nMethods; i++) {
    if (bytes[2 + i] === 0x00) {
      noAuth = true;
      break;
    }
  }
  r.consumed = 2 + nMethods;
  if (!noAuth) {
    r.phase = 'error';
    r.errorMessage = '客户端未提供 NO AUTH 方法';
    r.reply = [0x05, 0xFF];
    return r;
  }
  r.phase = 'request'; // 下一阶段等 CONNECT
  r.reply = [0x05, 0x00]; // VER + METHOD=NO AUTH
  return r;
}

/**
 * 处理 CONNECT 请求。字节不足 consumed=0；解析成功后 readyToConnect=true，
 * connectHost/connectPort 填好，phase 仍为 'request'（外壳开通道后再
 * socks5SuccessReply / socks5ErrorReply 写回并进 connected/error）。
 */
export function socks5ProcessRequest(bytes: Uint8Array): Socks5Result {
  const r: Socks5Result = emptyResult();
  r.phase = 'request';
  if (bytes.length < 4) {
    return r;
  }
  const ver: number = bytes[0];
  const cmd: number = bytes[1];
  const atyp: number = bytes[3];
  if (ver !== 0x05) {
    r.phase = 'error';
    r.consumed = bytes.length;
    r.errorMessage = '非法 SOCKS 版本';
    r.reply = socks5ErrorReply(0x01);
    return r;
  }
  if (cmd !== 0x01) {
    r.phase = 'error';
    r.consumed = 4;
    r.errorMessage = '仅支持 CONNECT';
    r.reply = socks5ErrorReply(0x07);
    return r;
  }

  let host: string = '';
  let port: number = 0;
  let consumed: number = 0;

  if (atyp === 0x01) {
    // IPv4: 4 + 4 addr + 2 port
    if (bytes.length < 10) {
      return r;
    }
    host = `${bytes[4]}.${bytes[5]}.${bytes[6]}.${bytes[7]}`;
    port = (bytes[8] << 8) | bytes[9];
    consumed = 10;
  } else if (atyp === 0x03) {
    // DOMAINNAME: 4 + 1 len + name + 2 port
    if (bytes.length < 5) {
      return r;
    }
    const nameLen: number = bytes[4];
    if (nameLen === 0) {
      r.phase = 'error';
      r.consumed = 5;
      r.errorMessage = '空域名';
      r.reply = socks5ErrorReply(0x08);
      return r;
    }
    if (bytes.length < 5 + nameLen + 2) {
      return r;
    }
    host = '';
    for (let i = 0; i < nameLen; i++) {
      host += String.fromCharCode(bytes[5 + i]);
    }
    port = (bytes[5 + nameLen] << 8) | bytes[6 + nameLen];
    consumed = 5 + nameLen + 2;
  } else if (atyp === 0x04) {
    // IPv6: 4 + 16 addr + 2 port
    if (bytes.length < 22) {
      return r;
    }
    const parts: string[] = [];
    for (let i = 0; i < 8; i++) {
      const hi: number = bytes[4 + i * 2];
      const lo: number = bytes[5 + i * 2];
      const word: number = (hi << 8) | lo;
      parts.push(word.toString(16));
    }
    host = parts.join(':');
    port = (bytes[20] << 8) | bytes[21];
    consumed = 22;
  } else {
    r.phase = 'error';
    r.consumed = 4;
    r.errorMessage = '不支持的 ATYP';
    r.reply = socks5ErrorReply(0x08);
    return r;
  }

  if (host.length === 0 || port <= 0 || port > 65535) {
    r.phase = 'error';
    r.consumed = consumed;
    r.errorMessage = 'CONNECT 目标非法';
    r.reply = socks5ErrorReply(0x04);
    return r;
  }

  r.consumed = consumed;
  r.connectHost = host;
  r.connectPort = port;
  r.readyToConnect = true;
  r.phase = 'request';
  return r;
}

/** 外壳在 direct-tcpip 成功后调用：写回 success 并标记 connected */
export function socks5MarkConnected(): Socks5Result {
  const r: Socks5Result = emptyResult();
  r.phase = 'connected';
  r.reply = socks5SuccessReply();
  return r;
}

/** 外壳在 direct-tcpip 失败时调用 */
export function socks5MarkConnectFailed(code: Socks5ReplyCode, message: string): Socks5Result {
  const r: Socks5Result = emptyResult();
  r.phase = 'error';
  r.reply = socks5ErrorReply(code);
  r.errorMessage = message;
  return r;
}

/**
 * 每连接的握手状态机外壳（仍无系统 API：字节进、动作出）。
 * 外壳喂字节，按返回的 reply 写回、按 readyToConnect 开通道。
 */
export class Socks5Handshake {
  private phase: Socks5Phase = 'greeting';
  private buffer: number[] = [];
  connectHost: string = '';
  connectPort: number = 0;

  get currentPhase(): Socks5Phase {
    return this.phase;
  }

  get isComplete(): boolean {
    return this.phase === 'connected';
  }

  get hasError(): boolean {
    return this.phase === 'error';
  }

  /** 喂入客户端字节；返回应写回的字节与是否需要开通道 */
  feed(chunk: Uint8Array): Socks5FeedResult {
    if (this.phase === 'connected' || this.phase === 'error') {
      return { reply: [], readyToConnect: false, phase: this.phase, errorMessage: '' };
    }
    for (let i = 0; i < chunk.length; i++) {
      this.buffer.push(chunk[i]);
    }
    const bytes: Uint8Array = new Uint8Array(this.buffer);
    if (this.phase === 'greeting') {
      const g: Socks5Result = socks5ProcessGreeting(bytes);
      if (g.consumed === 0) {
        return { reply: [], readyToConnect: false, phase: this.phase, errorMessage: '' };
      }
      this.buffer = this.buffer.slice(g.consumed);
      if (g.phase === 'error') {
        this.phase = 'error';
        return { reply: g.reply, readyToConnect: false, phase: this.phase,
          errorMessage: g.errorMessage };
      }
      this.phase = 'request';
      // greeting 回复后若有剩余字节，继续当 request 处理
      return this.feedRest(g.reply);
    }
    return this.feedRest([]);
  }

  private feedRest(pendingReply: number[]): Socks5FeedResult {
    const bytes: Uint8Array = new Uint8Array(this.buffer);
    const req: Socks5Result = socks5ProcessRequest(bytes);
    if (req.phase === 'error') {
      this.buffer = this.buffer.slice(req.consumed > 0 ? req.consumed : this.buffer.length);
      this.phase = 'error';
      return {
        reply: pendingReply.concat(req.reply),
        readyToConnect: false,
        phase: this.phase,
        errorMessage: req.errorMessage
      };
    }
    if (!req.readyToConnect) {
      return {
        reply: pendingReply,
        readyToConnect: false,
        phase: this.phase,
        errorMessage: ''
      };
    }
    this.buffer = this.buffer.slice(req.consumed);
    this.connectHost = req.connectHost;
    this.connectPort = req.connectPort;
    return {
      reply: pendingReply,
      readyToConnect: true,
      phase: this.phase,
      errorMessage: ''
    };
  }

  /** 外壳：direct-tcpip 成功 */
  completeConnect(): number[] {
    this.phase = 'connected';
    return socks5SuccessReply();
  }

  /** 外壳：direct-tcpip 失败 */
  failConnect(code: Socks5ReplyCode, message: string): number[] {
    this.phase = 'error';
    return socks5ErrorReply(code);
  }

  /** connected 后的透传数据：原样返回（外壳桥到 native forwardWrite） */
  payloadAfterConnect(chunk: Uint8Array): Uint8Array {
    return chunk;
  }
}

export interface Socks5FeedResult {
  reply: number[];
  readyToConnect: boolean;
  phase: Socks5Phase;
  errorMessage: string;
}
