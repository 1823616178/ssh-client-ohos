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
  probeNow(handle: number, timeoutSec: number): boolean;
  setReconnectPolicy(handle: number, delaysSec: number[], maxAttempts: number): boolean;
  nextReconnectDelaySec(handle: number, attempt: number): number;
  // ---- N9 应用内 agent（进程级内存密钥托管，语义见 cpp/ssh/agent.h）----
  agentUnlock(keyId: string, privateKey: ArrayBuffer | string, passphrase: string): boolean;
  agentLock(keyId: string): boolean;
  agentLockAll(): boolean;
  agentIsLocked(keyId: string): boolean;
  agentKeyCount(): number;
  agentSetTimeout(minutes: number): boolean;
  agentTimeoutMinutes(): number;
  authenticateAgent(handle: number, keyId: string): boolean;
  /** U3：ed25519 生成；失败返回 null。私钥 PKCS#8 PEM，公钥 OpenSSH 单行 */
  agentKeygen(comment: string, passphrase: string): NativeAgentKeygenResult | null;
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
  setTerminalDefaultColors(terminalHandle: number, fgArgb: number, bgArgb: number): boolean;
  vaultCreate(password: string, keyVersion: number): NativeVaultCreateResult | null;
  vaultUnlockPassword(password: string, keyVersion: number, kdfSalt: string,
    passwordWrappedKey: string, passwordWrapNonce: string): number;
  vaultUnlockRecovery(recoveryKey: string, keyVersion: number, recoveryWrappedKey: string,
    recoveryWrapNonce: string): number;
  vaultEncrypt(handle: number, vaultId: string, schemaVersion: number, keyVersion: number,
    plaintext: string): NativeVaultSeal | null;
  vaultDecrypt(handle: number, vaultId: string, schemaVersion: number, keyVersion: number,
    nonce: string, ciphertext: string): string | null;
  vaultRewrap(handle: number, newPassword: string, keyVersion: number): NativeVaultCreateResult | null;
  vaultRotate(handle: number, password: string): NativeVaultCreateResult | null;
  vaultClose(handle: number): boolean;
  // ---- N14 SFTP（事件随所属会话 onEvent 上抛，语义见 types/libssh_core/index.d.ts）----
  sftpOpen(sessionHandle: number): number;
  sftpClose(sftpHandle: number): boolean;
  sftpList(sftpHandle: number, path: string): boolean;
  sftpStat(sftpHandle: number, path: string): boolean;
  sftpDownload(sftpHandle: number, transferId: number, remotePath: string,
    localPath: string): boolean;
  sftpUpload(sftpHandle: number, transferId: number, localPath: string,
    remotePath: string): boolean;
  sftpRename(sftpHandle: number, fromPath: string, toPath: string): boolean;
  sftpMkdir(sftpHandle: number, path: string, mode: number): boolean;
  sftpRmdir(sftpHandle: number, path: string): boolean;
  sftpUnlink(sftpHandle: number, path: string): boolean;
  sftpChmod(sftpHandle: number, path: string, mode: number): boolean;
  sftpReadlink(sftpHandle: number, path: string): boolean;
  // ---- N15 端口转发（语义见 types/libssh_core/index.d.ts）----
  openDirectTcpip(sessionHandle: number, host: string, port: number): number;
  forwardWrite(forwardHandle: number, data: ArrayBuffer | string): boolean;
  forwardClose(forwardHandle: number): boolean;
  remoteForwardListen(sessionHandle: number, bindAddress: string, port: number): number;
  remoteForwardCancel(listenHandle: number): boolean;
  forwardProxyJumpNotes(): string;
  forwardParseJumpSpec(spec: string): string;
}

export interface NativeVaultCreateResult {
  handle: number;
  keyVersion: number;
  passwordWrappedKey: string;
  passwordWrapNonce: string;
  recoveryWrappedKey: string;
  recoveryWrapNonce: string;
  kdfSalt: string;
  recoveryKey: string;
}

/** U3 agentKeygen 返回载体（与 types/libssh_core/index.d.ts 一致） */
export interface NativeAgentKeygenResult {
  keyType: string;
  privateKeyPem: string;
  publicKeyLine: string;
  comment: string;
}

export interface NativeVaultSeal {
  schemaVersion: number;
  keyVersion: number;
  algorithm: string;
  nonce: string;
  ciphertext: string;
  ciphertextHash: string;
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
  /**
   * T10 stub：DECCKM 应用光标键模式（true=方向键 SS3）。native 尚未暴露该位
   * （对称 mouseMode 的未来扩展）；缺省 undefined 时上层按 false 处理。
   * native 接入后由帧组包填充，KeyMap 已接受该标志。
   */
  applicationCursorKeys?: boolean;
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
  /** T3：终端事件携带的终端句柄（terminalOpen/terminalData/terminalClose/
   *  terminalBell/terminalTitle/terminalMouseMode），均随所属会话的 onEvent 上抛 */
  terminal?: number;
  /** T3：terminalTitle 事件的标题文本 */
  title?: string;
  /** T3：terminalMouseMode 事件的模式（0=关 1=点击 2=拖动 3=任意移动） */
  mouseMode?: number;
  /**
   * T10 stub：terminalCursorKeys 事件的应用光标键模式位（DECCKM，对称
   * terminalMouseMode）。native 暴露后投递 type='terminalCursorKeys' +
   * applicationCursorKeys；未暴露前上层维持默认 false。
   */
  applicationCursorKeys?: boolean;
  /** N14：SFTP 句柄（sftpOpen/sftpList/sftpStat/sftpOpDone/sftp*） */
  sftp?: number;
  /** N14：传输任务 id（sftpProgress/sftpTransferDone） */
  transferId?: number;
  /** N14：sftpList 的 entriesJson 数组字符串 / sftpStat 的 entryJson 对象 */
  entriesJson?: string;
  entryJson?: string;
  path?: string;
  op?: string;
  linkTarget?: string;
  transferred?: number;
  total?: number;
  /** N15：转发数据通道 / 远程监听句柄 */
  forward?: number;
  /** N15：forwardAccept 所属监听句柄 */
  listen?: number;
  /** N15：forwardListen 成功时的实际上报端口 */
  boundPort?: number;
  /** N15：forwardAccept 的 originator（常为空） */
  origin?: string;
}

/** T10 stub：DECCKM 会话级事件类型名（native 未投递前仅作文档/测试约定） */
export const TERMINAL_CURSOR_KEYS_EVENT_TYPE: string = 'terminalCursorKeys';


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

  /**
   * N9：应用内 agent 认证（仅 authenticating 受理）。keyId 须已在进程级
   * agent 中解锁；未解锁/已超时清除时返回 false 且不消耗认证重试计数。
   */
  authenticateAgent(keyId: string): boolean {
    return this.alive && native.authenticateAgent(this.handle, keyId);
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
   * P1：主动探测（仅 established 受理，false = 未受理）。网络切换后调用：
   * 立刻发一拍 keepalive 并开 timeoutSec 秒判定窗口，窗口内无入站活动即判黑洞
   * → 会话进 disconnected（reconnectHint=true），由 SessionManager 走既有重连链。
   * timeoutSec 传 0 = native 默认 5 s
   */
  probeNow(timeoutSec: number): boolean {
    return this.alive && native.probeNow(this.handle, timeoutSec);
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

  /** native 句柄（只读；U4 装配终端、N14 打开 SFTP 用，业务层不应直接触碰） */
  get nativeHandle(): number {
    return this.handle;
  }

  /**
   * N14：在本会话上打开 SFTP 通道（仅 established 受理）。
   * 返回句柄（>0 = 已受理，结果经 sftpOpen 事件）；0 = 未受理。
   * 关闭用 SshNativeSftp.close() 或 nativeCore().sftpClose(handle)
   */
  openSftp(): number {
    if (!this.alive) {
      return 0;
    }
    return native.sftpOpen(this.handle);
  }

  /**
   * N15：在本会话上打开 direct-tcpip 转发通道（-L/-D 数据面）。
   * 返回句柄（>0 = 已受理，结果经 forwardOpen 事件）；0 = 未受理。
   * 写入用 SshNativeForward.write / nativeCore().forwardWrite
   */
  openDirectTcpip(host: string, port: number): number {
    if (!this.alive || host.length === 0 || port <= 0 || port > 65535) {
      return 0;
    }
    return native.openDirectTcpip(this.handle, host, port);
  }

  /**
   * N15：开启远程转发监听（-R）。bindAddress 空串 = 服务器默认。
   * 返回 listen 句柄（>0 = 已受理，结果经 forwardListen）；0 = 未受理。
   * 入站连接经 forwardAccept 上抛新数据通道句柄。
   */
  remoteForwardListen(bindAddress: string, port: number): number {
    if (!this.alive || port <= 0 || port > 65535) {
      return 0;
    }
    return native.remoteForwardListen(this.handle, bindAddress, port);
  }
}

/** N9：进程级应用内 agent 的类型安全封装（内存密钥托管，多会话复用） */
export class SshAgentBridge {
  /** 解锁并托管私钥；成功后调用方 buffer 的 native 副本被清零（ArkTS 原串无法清零） */
  static unlock(keyId: string, privateKey: ArrayBuffer | string, passphrase: string): boolean {
    return native.agentUnlock(keyId, privateKey, passphrase);
  }

  /** 锁定指定 keyId（清除托管材料）；不存在返回 false */
  static lock(keyId: string): boolean {
    return native.agentLock(keyId);
  }

  /** 锁定全部（幂等）：超时/退出/用户「立即锁定」共用入口 */
  static lockAll(): void {
    native.agentLockAll();
  }

  /** keyId 是否处于锁定状态（不存在/已清除/已超时 → true） */
  static isLocked(keyId: string): boolean {
    return native.agentIsLocked(keyId);
  }

  /** 当前托管条数（诊断用） */
  static keyCount(): number {
    return native.agentKeyCount();
  }

  /** 托管超时（分钟，0 = 永不超时） */
  static setTimeout(minutes: number): boolean {
    return native.agentSetTimeout(minutes);
  }

  static timeoutMinutes(): number {
    return native.agentTimeoutMinutes();
  }

  /**
   * U3：生成 ed25519 密钥对。失败 / native 未导出时返回 null。
   * 私钥 PKCS#8 PEM（OpenSSH 完整私钥序列化过重，见 cpp/ssh/keygen.h）；
   * 公钥 OpenSSH 单行，指纹由 KeyManagerLogic.formatOpenSshFingerprint 计算。
   */
  static keygen(comment: string, passphrase: string): NativeAgentKeygenResult | null {
    try {
      return native.agentKeygen(comment, passphrase);
    } catch (_e) {
      return null;
    }
  }

  /** native 是否导出 agentKeygen（UI 决定是否启用「生成密钥对」） */
  static keygenSupported(): boolean {
    try {
      return typeof native.agentKeygen === 'function';
    } catch (_e) {
      return false;
    }
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

/** N14：SFTP 目录项（native entriesJson / entryJson 解析结果） */
export interface SftpNativeEntry {
  name: string;
  path: string;
  type: string;
  size: number;
  mtime: number;
  mode: number;
  permissions: string;
  linkTarget: string;
}

/** N14：SFTP 通道句柄薄封装（事件仍随所属会话 onEvent 上抛） */
export class SshNativeSftp {
  private handle: number;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /** 从会话 openSftp() 的受理句柄装配；0/负值返回 null */
  static fromHandle(handle: number): SshNativeSftp | null {
    if (handle <= 0) {
      return null;
    }
    return new SshNativeSftp(handle);
  }

  get nativeHandle(): number {
    return this.handle;
  }

  list(path: string): boolean {
    return this.alive && native.sftpList(this.handle, path);
  }

  stat(path: string): boolean {
    return this.alive && native.sftpStat(this.handle, path);
  }

  download(transferId: number, remotePath: string, localPath: string): boolean {
    return this.alive && native.sftpDownload(this.handle, transferId, remotePath, localPath);
  }

  upload(transferId: number, localPath: string, remotePath: string): boolean {
    return this.alive && native.sftpUpload(this.handle, transferId, localPath, remotePath);
  }

  rename(fromPath: string, toPath: string): boolean {
    return this.alive && native.sftpRename(this.handle, fromPath, toPath);
  }

  mkdir(path: string, mode: number): boolean {
    return this.alive && native.sftpMkdir(this.handle, path, mode);
  }

  rmdir(path: string): boolean {
    return this.alive && native.sftpRmdir(this.handle, path);
  }

  unlink(path: string): boolean {
    return this.alive && native.sftpUnlink(this.handle, path);
  }

  chmod(path: string, mode: number): boolean {
    return this.alive && native.sftpChmod(this.handle, path, mode);
  }

  readlink(path: string): boolean {
    return this.alive && native.sftpReadlink(this.handle, path);
  }

  close(): void {
    if (!this.alive) {
      return;
    }
    native.sftpClose(this.handle);
    this.handle = 0;
  }

  private get alive(): boolean {
    return this.handle > 0;
  }
}

/**
 * 解析 native sftpList 的 entriesJson（JSON 数组字符串）。
 * ArkTS 严格模式不使用 any；解析失败返回空数组。
 */
export function parseSftpEntriesJson(entriesJson: string | undefined): SftpNativeEntry[] {
  if (entriesJson === undefined || entriesJson.length === 0) {
    return [];
  }
  try {
    const parsed: Object | null = JSON.parse(entriesJson) as Object | null;
    if (parsed === null || !Array.isArray(parsed)) {
      return [];
    }
    const arr: Object[] = parsed as Object[];
    const out: SftpNativeEntry[] = [];
    for (let i = 0; i < arr.length; i++) {
      const e: SftpNativeEntry = parseOneSftpEntry(arr[i]);
      if (e.name.length > 0) {
        out.push(e);
      }
    }
    return out;
  } catch (_e) {
    return [];
  }
}

/** 解析 sftpStat 的 entryJson；失败返回 null */
export function parseSftpEntryJson(entryJson: string | undefined): SftpNativeEntry | null {
  if (entryJson === undefined || entryJson.length === 0) {
    return null;
  }
  try {
    const parsed: Object | null = JSON.parse(entryJson) as Object | null;
    if (parsed === null || Array.isArray(parsed)) {
      return null;
    }
    const e: SftpNativeEntry = parseOneSftpEntry(parsed);
    return e.name.length > 0 || e.path.length > 0 ? e : null;
  } catch (_e) {
    return null;
  }
}

function parseOneSftpEntry(raw: Object): SftpNativeEntry {
  const rec: Record<string, Object> = raw as Record<string, Object>;
  return {
    name: typeof rec['name'] === 'string' ? rec['name'] as string : '',
    path: typeof rec['path'] === 'string' ? rec['path'] as string : '',
    type: typeof rec['type'] === 'string' ? rec['type'] as string : 'file',
    size: typeof rec['size'] === 'number' ? rec['size'] as number : 0,
    mtime: typeof rec['mtime'] === 'number' ? rec['mtime'] as number : 0,
    mode: typeof rec['mode'] === 'number' ? rec['mode'] as number : 0,
    permissions: typeof rec['permissions'] === 'string' ? rec['permissions'] as string : '',
    linkTarget: typeof rec['linkTarget'] === 'string' ? rec['linkTarget'] as string : ''
  };
}

// ------------------------------------------------------------------
// N15 端口转发：native 数据通道 / 远程监听薄封装
// 事件仍随所属会话 onEvent 上抛（type: forwardOpen/forwardData/forwardClose/
// forwardListen/forwardAccept）
// ------------------------------------------------------------------

/** N15：转发数据通道句柄薄封装 */
export class SshNativeForward {
  private handle: number;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /** 从 openDirectTcpip / forwardAccept 的受理句柄装配；0/负值返回 null */
  static fromHandle(handle: number): SshNativeForward | null {
    if (handle <= 0) {
      return null;
    }
    return new SshNativeForward(handle);
  }

  get nativeHandle(): number {
    return this.handle;
  }

  /** 写入（背压整次拒收时 false，调用方保留数据稍后重试） */
  write(data: ArrayBuffer | string): boolean {
    return this.alive && native.forwardWrite(this.handle, data);
  }

  close(): void {
    if (!this.alive) {
      return;
    }
    native.forwardClose(this.handle);
    this.handle = 0;
  }

  private get alive(): boolean {
    return this.handle > 0;
  }
}

/** N15：远程 -R 监听句柄薄封装 */
export class SshNativeRemoteForward {
  private handle: number;

  private constructor(handle: number) {
    this.handle = handle;
  }

  static fromHandle(handle: number): SshNativeRemoteForward | null {
    if (handle <= 0) {
      return null;
    }
    return new SshNativeRemoteForward(handle);
  }

  get nativeHandle(): number {
    return this.handle;
  }

  cancel(): void {
    if (!this.alive) {
      return;
    }
    native.remoteForwardCancel(this.handle);
    this.handle = 0;
  }

  private get alive(): boolean {
    return this.handle > 0;
  }
}

/**
 * N15：探测 native 端口转发桥是否可用（openDirectTcpip 已注册）。
 * PortForwardRuntime 据此把 nativeChannelRequired 置 false。
 */
export function isNativeForwardAvailable(): boolean {
  try {
    return typeof native.openDirectTcpip === 'function';
  } catch (_e) {
    return false;
  }
}

/** N16：ProxyJump 传输层设计注记（诊断用） */
export function proxyJumpTransportNotes(): string {
  try {
    return native.forwardProxyJumpNotes();
  } catch (_e) {
    return '';
  }
}

/** N16 hop 条目（forwardParseJumpSpec JSON 解析结果） */
export interface ProxyJumpHopSpec {
  username: string;
  host: string;
  port: number;
}

/**
 * N16：解析 OpenSSH -J 规格。native 不可用时回落到 ArkTS 纯逻辑
 * （service/portforward/ProxyJump.ets 的 parseProxyJumpSpec）。
 */
export function parseProxyJumpSpecNative(spec: string): ProxyJumpHopSpec[] {
  try {
    const raw: string = native.forwardParseJumpSpec(spec);
    if (raw.length === 0 || raw === '[]') {
      return [];
    }
    const parsed: Object | null = JSON.parse(raw) as Object | null;
    if (parsed === null || !Array.isArray(parsed)) {
      return [];
    }
    const arr: Object[] = parsed as Object[];
    const out: ProxyJumpHopSpec[] = [];
    for (let i = 0; i < arr.length; i++) {
      const rec: Record<string, Object> = arr[i] as Record<string, Object>;
      out.push({
        username: typeof rec['username'] === 'string' ? rec['username'] as string : '',
        host: typeof rec['host'] === 'string' ? rec['host'] as string : '',
        port: typeof rec['port'] === 'number' ? rec['port'] as number : 22
      });
    }
    return out;
  } catch (_e) {
    return [];
  }
}
