/**
 * libssh_core.so 的类型安全薄封装 —— 任务 N11。
 *
 * 对上层（页面/服务）隐藏原始句柄与 napi 细节：
 *   - SshNativeSession：一个实例对应 native 一个会话句柄，close() 幂等；
 *   - 事件经构造时注入的 onEvent 回调上抛（native 侧统一模型：
 *     「方法同步受理、事件异步回报」，语义见 types/libssh_core/index.d.ts）；
 *   - 状态/事件类型用 string 联合类型约束（与 native 投递的字符串一致）。
 *
 * 线程注意：onEvent 在 ArkTS 主线程触发（native TSFN 投递），可直接驱动 UI。
 */
import libsshCore from 'libssh_core.so';

/**
 * .so 默认导入在 ArkTS 编译器下是 any（arkts-no-any-unknown 会拦截
 * 由其推断出的变量声明），这里用显式接口收口全部原生方法。
 * 签名须与 types/libssh_core/index.d.ts 保持一致（改一侧必须同步另一侧）。
 * 导出原因：nativeCore() 的返回类型须在调用方（SshTerminal.ets）可见
 */
export interface LibSshCoreModule {
  createSession(onEvent: (event: SshEvent) => void): number;
  connect(handle: number, host: string, port: number, username: string): boolean;
  authenticatePassword(handle: number, password: string): boolean;
  authenticatePublicKey(handle: number, privateKey: ArrayBuffer | string, publicKey: string,
    passphrase: string): boolean;
  openShell(handle: number, termType: string, cols: number, rows: number): boolean;
  exec(handle: number, command: string): boolean;
  write(handle: number, channelId: number, data: ArrayBuffer | string): boolean;
  resize(handle: number, channelId: number, cols: number, rows: number): boolean;
  closeChannel(handle: number, channelId: number): boolean;
  closeSession(handle: number): boolean;
  setKeepalive(handle: number, intervalSec: number, maxMisses: number): boolean;
  setReconnectPolicy(handle: number, delaysSec: number[], maxAttempts: number): boolean;
  nextReconnectDelaySec(handle: number, attempt: number): number;
  getLibssh2Version(): string;
  getOpensslVersion(): string;
  getVtermVersion(): string;
  getArgon2Version(): string;
  // ---- T3 终端零拷贝快照（语义见 types/libssh_core/index.d.ts）----
  attachTerminal(sessionHandle: number, termType: string, cols: number, rows: number): number;
  detachTerminal(terminalHandle: number): boolean;
  beginFrame(terminalHandle: number): NativeTerminalFrame | null;
  endFrame(terminalHandle: number, seenRevision: number): boolean;
  getRevision(terminalHandle: number): number;
  selfTestGrid(terminalHandle: number): ArrayBuffer | null;
  copyGridRows(terminalHandle: number, startRow: number, count: number): ArrayBuffer | null;
  getScrollbackWindow(terminalHandle: number, startIndex: number, count: number): ArrayBuffer | null;
  writeTerminal(terminalHandle: number, data: ArrayBuffer | string): boolean;
  resizeTerminal(terminalHandle: number, cols: number, rows: number): boolean;
}

/** T3：native beginFrame 组包的原始帧对象（字段随 napi 组包，可选字段可能缺省） */
export interface NativeTerminalFrame {
  grid?: ArrayBuffer;
  gridZeroCopy: boolean;
  revision: number;
  cols: number;
  rows: number;
  cursorRow: number;
  cursorCol: number;
  cursorVisible: boolean;
  altScreen: boolean;
  mouseMode: number;
  bellCount: number;
  scrollbackOldest: number;
  scrollbackTotal: number;
  dirty?: ArrayBuffer;
}

const native: LibSshCoreModule = libsshCore;

/** T3：同进程内共享的 native 绑定（SshTerminal.ets 复用，避免第二处 .so 导入） */
export function nativeCore(): LibSshCoreModule {
  return native;
}

/** 会话状态（与 native SshSessionState 的 toString 输出一致） */
export type SshSessionStateName =
  'idle' | 'connecting' | 'handshaking' | 'authenticating' | 'established' |
  'closing' | 'closed' | 'disconnected' | 'error';

/** 通道关闭原因（与 native ChannelCloseReason 的 toString 输出一致） */
export type ChannelCloseReasonName = 'peer_eof' | 'exit_status' | 'exit_signal' | 'error';

/** 通道数据流（0=stdout 1=stderr） */
export enum ChannelStreamId {
  STDOUT = 0,
  STDERR = 1
}

/** 会话事件（字段随 type 而定，与 native 投递的 object 一一对应） */
export interface SshEvent {
  type: string;
  from?: string;
  to?: string;
  /** N12：stateChange 进终态时附——是否值得自动重连（供 SessionManager 编排退避） */
  reconnectHint?: boolean;
  /**
   * N13：stateChange 进终态时附——统一数值错误码（与 common/SshError.ets 的
   * SshErrorCode 一致；正常关闭省略）。上层经 SshError.fromNativeCode() 收口
   */
  errorCode?: number;
  /** N13：错误码调试名（snake_case，如 keepalive_timeout），随 errorCode 同附 */
  errorCodeName?: string;
  /** N13：native 原始错误描述（诊断用，不对用户展示），随 errorCode 同附 */
  errorMessage?: string;
  keyType?: string;
  fingerprintSha256?: string;
  fingerprintMd5?: string;
  randomart?: string;
  method?: string;
  success?: boolean;
  error?: string;
  message?: string;
  attemptsLeft?: number;
  channelId?: number;
  stream?: number;
  data?: ArrayBuffer;
  reason?: string;
  exitStatus?: number;
  exitSignal?: string;
  code?: string;
  count?: number;
  /** T3：终端事件携带的终端句柄（terminalOpen/terminalClose/terminalBell/
   *  terminalTitle/terminalMouseMode），均随所属会话的 onEvent 上抛 */
  terminal?: number;
  /** T3：terminalTitle 事件的标题文本 */
  title?: string;
  /** T3：terminalMouseMode 事件的模式（0=关 1=点击 2=拖动 3=任意移动） */
  mouseMode?: number;
}

export type SshEventListener = (event: SshEvent) => void;

/**
 * 一个 native SSH 会话的类型安全封装。
 * 生命周期：create → connect → authenticate* → openShell/exec → write/resize
 * → close；close 后一切方法返回 false（句柄已注销）。
 */
export class SshNativeSession {
  private handle: number;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /** 创建会话；底层 TSFN/线程创建失败返回 null */
  static create(onEvent: SshEventListener): SshNativeSession | null {
    const handle = native.createSession(onEvent);
    if (handle <= 0) {
      return null;
    }
    return new SshNativeSession(handle);
  }

  /** 发起连接（受理语义，结果经 stateChange 事件） */
  connect(host: string, port: number, username: string): boolean {
    return this.alive && native.connect(this.handle, host, port, username);
  }

  /** 密码认证（结果经 authResult 事件；password 的 native 副本用完即清零） */
  authenticatePassword(password: string): boolean {
    return this.alive && native.authenticatePassword(this.handle, password);
  }

  /** 公钥认证；publicKey 空串 = 从私钥提取，passphrase 空串 = 无短语 */
  authenticatePublicKey(privateKey: ArrayBuffer | string, publicKey: string,
    passphrase: string): boolean {
    return this.alive &&
      native.authenticatePublicKey(this.handle, privateKey, publicKey, passphrase);
  }

  /** 开 shell 通道（带 PTY）；channelId 经 channelOpen 事件回报 */
  openShell(termType: string, cols: number, rows: number): boolean {
    return this.alive && native.openShell(this.handle, termType, cols, rows);
  }

  /** 开 exec 通道（无 PTY 一次性命令） */
  exec(command: string): boolean {
    return this.alive && native.exec(this.handle, command);
  }

  /** 写通道数据；false = 通道已关/背压拒收（整次拒收，应稍后重试） */
  write(channelId: number, data: ArrayBuffer | string): boolean {
    return this.alive && native.write(this.handle, channelId, data);
  }

  /** 调整 PTY 尺寸（在途合并，最后一次生效） */
  resize(channelId: number, cols: number, rows: number): boolean {
    return this.alive && native.resize(this.handle, channelId, cols, rows);
  }

  /** 关闭通道（幂等；结果经 channelClose 事件） */
  closeChannel(channelId: number): boolean {
    return this.alive && native.closeChannel(this.handle, channelId);
  }

  /** 关闭会话（幂等）：注销句柄，native 后台线程完成优雅回收 */
  close(): void {
    if (!this.alive) {
      return;
    }
    native.closeSession(this.handle);
    this.handle = 0;
  }

  /**
   * N12：配置 keepalive（须在 connect 前调用）。
   * intervalSec 秒为发送周期、0 = 关闭（默认 30）；maxMisses 为连续无入站
   * 活动判黑洞的周期数（默认 3，0 = 只发不判）
   */
  setKeepalive(intervalSec: number, maxMisses: number): boolean {
    return this.alive && native.setKeepalive(this.handle, intervalSec, maxMisses);
  }

  /**
   * N12：设置自动重连退避策略。delaysSec 空数组 = 恢复默认 [1,2,5,10,20,30]，
   * 越界档钳到最后档；maxAttempts 0 = 无限（默认 6）
   */
  setReconnectPolicy(delaysSec: number[], maxAttempts: number): boolean {
    return this.alive && native.setReconnectPolicy(this.handle, delaysSec, maxAttempts);
  }

  /** N12：第 attempt 次重连（从 1 计）前的建议等待秒数；-1 = 已达上限放弃 */
  nextReconnectDelaySec(attempt: number): number {
    if (!this.alive) {
      return -1;
    }
    return native.nextReconnectDelaySec(this.handle, attempt);
  }

  private get alive(): boolean {
    return this.handle > 0;
  }

  /**
   * T3：native 会话句柄（attachTerminal 的入参）。
   * 仅供同模块的 SshTerminal 装配使用，业务层不应直接触碰
   */
  get nativeHandle(): number {
    return this.handle;
  }
}

/** 原生依赖版本查询（N3 验证点保留） */
export class SshNativeInfo {
  static libssh2Version(): string {
    return native.getLibssh2Version();
  }

  static opensslVersion(): string {
    return native.getOpensslVersion();
  }

  static vtermVersion(): string {
    return native.getVtermVersion();
  }

  static argon2Version(): string {
    return native.getArgon2Version();
  }
}
