/**
 * libssh_core.so 的 ArkTS 类型声明（NAPI 桥接层，N3 + N11）。
 *
 * 调用模型（N11 统一约定，与 bridge/session_bridge.h 头注一致）：
 *   - 一切方法「同步受理、立即返回」：boolean/number 返回值仅表示受理与否
 *     （句柄无效、状态不允许、背压拒收等返回 false/0），**不代表操作成功**；
 *   - 一切异步结果经事件回报：createSession 注册的 onEvent 回调收到
 *     SshNativeEvent，type 字段判别事件种类；
 *   - 凭据边界：password/privateKey/passphrase 传入后 native 侧用完即清零，
 *     但 ArkTS 运行时持有的原始 string/ArrayBuffer 副本无法清零——调用方应
 *     尽量缩短其驻留时间（局部变量、用完置空）。
 */

/** libssh2 运行时版本，如 "1.11.1" */
export const getLibssh2Version: () => string;

/** OpenSSL 版本，如 "3.5.7" */
export const getOpensslVersion: () => string;

/** libvterm 版本（编译期宏，如 "0.3.3"；libvterm 无运行时版本 API） */
export const getVtermVersion: () => string;

/** Argon2 编码版本（如 "1.3"；libargon2 无库版本 API） */
export const getArgon2Version: () => string;

/**
 * 会话事件（onEvent 回调参数）。type 判别种类，其余字段随类型而定：
 * - stateChange：from / to（idle|connecting|handshaking|authenticating|
 *   established|closing|closed|disconnected|error）；
 *   终态（disconnected/error/closed）时另附：
 *   reconnectHint（N12：是否值得自动重连——disconnected 与链路类 error 为 true，
 *   凭据类/协商类失败与主动关闭为 false）；
 *   errorCode（N13：统一数值错误码，与 common/SshError.ets 的 SshErrorCode
 *   一致，经 SshError.fromNativeCode() 收口后 toUserMessage() 取中文提示；
 *   正常关闭无错误时省略）、errorCodeName（snake_case 调试名，如
 *   keepalive_timeout）与 errorMessage（native 原始错误描述，诊断用）
 * - hostKey：keyType / fingerprintSha256 / fingerprintMd5 / randomart
 *   （M1 阶段 bridge「接受并上报」，TOFU 确认编排由上层负责）
 * - authResult：method（password|publickey）/ success / error / message /
 *   attemptsLeft（失败剩余可重试次数）
 * - channelOpen：channelId / success / error / message
 * - channelData：channelId / stream（0=stdout 1=stderr）/ data（ArrayBuffer，
 *   16 KiB / 8 ms 聚合批次；原始字节可能切断 UTF-8 序列，须流式解码）
 * - channelClose：channelId / reason（peer_eof|exit_status|exit_signal|error）/
 *   exitStatus / exitSignal / message
 * - error：code / message / count（如 data_queue_full 背压丢弃通知）
 * - T3 终端事件（attachTerminal 后随本会话 onEvent 上抛，均带 terminal 句柄）：
 *   terminalOpen：terminal / success / error / message（attachTerminal 受理后回报）
 *   terminalData：terminal（native 网格已发布新 revision，只作帧调度唤醒）
 *   terminalClose：terminal / reason / exitStatus / exitSignal / message
 *   terminalBell：terminal（vterm bell，UI 触感）
 *   terminalTitle：terminal / title（OSC 标题变更）
 *   terminalMouseMode：terminal / mouseMode（0=关 1=点击 2=拖动 3=任意移动）
 *   terminalCursorKeys（T10 stub，native 未实现）：terminal / applicationCursorKeys
 *     （true=DECCKM 应用光标键，方向键发 SS3；对称 mouseMode 的会话级标志）
 *
 * 注意：channelData 与 channelClose 走两条独立 TSFN 队列（背压隔离），
 * 最后的 channelData 与 channelClose 之间不保证到达顺序——exec 场景以
 * channelClose 为结束标志、期间持续累积 channelData。
 */
export interface SshNativeEvent {
  type: string;
  from?: string;
  to?: string;
  reconnectHint?: boolean;
  /** N13：统一数值错误码（与 SshErrorCode 一致；正常关闭省略） */
  errorCode?: number;
  /** 错误码调试名（snake_case，如 keepalive_timeout） */
  errorCodeName?: string;
  /** native 原始错误描述（诊断用，不对用户展示） */
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
   *  terminalBell/terminalTitle/terminalMouseMode） */
  terminal?: number;
  /** T3：terminalTitle 事件的标题文本 */
  title?: string;
  /** T3：terminalMouseMode 事件的模式（0=关 1=点击 2=拖动 3=任意移动） */
  mouseMode?: number;
  /** T10 stub：terminalCursorKeys 事件的 DECCKM 标志（native 未实现前缺省） */
  applicationCursorKeys?: boolean;
}

/**
 * 创建 SSH 会话，返回句柄（> 0；0 = 失败）。句柄单调递增、不复用。
 * onEvent 注册后立即生效，所有事件（含随后的 stateChange）都投递给它。
 */
export const createSession: (onEvent: (event: SshNativeEvent) => void) => number;

/** 发起连接（仅 idle 态受理）。结果经 stateChange 事件（connecting→…） */
export const connect: (handle: number, host: string, port: number, username: string) => boolean;

/** 密码认证（仅 authenticating 态受理）。结果经 authResult 事件 */
export const authenticatePassword: (handle: number, password: string) => boolean;

/**
 * 公钥认证（仅 authenticating 态受理）。privateKey 为私钥文件字节
 * （ArrayBuffer 或 string）；publicKey 为 .pub 公钥文本，空串 = 从私钥提取；
 * passphrase 空串 = 无短语。结果经 authResult 事件
 */
export const authenticatePublicKey: (
  handle: number,
  privateKey: ArrayBuffer | string,
  publicKey: string,
  passphrase: string
) => boolean;

/** 开 shell 通道（带 PTY；仅 established 态受理）。结果经 channelOpen 事件 */
export const openShell: (handle: number, termType: string, cols: number, rows: number) => boolean;

/** 开 exec 通道（无 PTY 一次性命令）。结果经 channelOpen/channelClose 事件 */
export const exec: (handle: number, command: string) => boolean;

/**
 * 向通道写数据（ArrayBuffer 或 string）。false = 通道已关/背压拒收
 * （4 MiB 待发队列上限，整次拒收，调用方保留数据稍后重试）
 */
export const write: (handle: number, channelId: number, data: ArrayBuffer | string) => boolean;

/** 调整 PTY 尺寸（仅带 PTY 的通道受理；在途多次调用合并，最后一次生效） */
export const resize: (handle: number, channelId: number, cols: number, rows: number) => boolean;

/** 关闭通道（幂等，不存在视为已关闭）。结果经 channelClose 事件 */
export const closeChannel: (handle: number, channelId: number) => boolean;

/**
 * 关闭会话（幂等；false = 句柄不存在或已关闭）。摘表立即返回，
 * 实际回收（关会话→停线程→释放）在 native 后台线程完成；
 * 进行中的事件回调在入口关闭后即弃，不再投递
 */
export const closeSession: (handle: number) => boolean;

/**
 * N12：配置 keepalive（须在 connect 前调用，false = 未受理）。
 * intervalSec：发送周期秒数，0 = 关闭（默认 30）；
 * maxMisses：连续无入站活动周期数达到该值判静默断线（默认 3，0 = 只发不判）。
 * 判定触发后会话进 disconnected（stateChange 附 reconnectHint=true、
 * errorCode=404（KEEPALIVE_TIMEOUT，N13 统一数值码））
 */
export const setKeepalive: (handle: number, intervalSec: number, maxMisses: number) => boolean;

/**
 * P1：网络切换后的主动探测（受理语义，仅 established 受理，false = 未受理）。
 * 立刻发一拍 keepalive 并开 timeoutSec 秒判定窗口：窗口内无任何入站活动即判黑洞，
 * 会话进 disconnected（stateChange 附 reconnectHint=true、errorCode=404），
 * 由 ArkTS 侧走既有重连链；有入站则复位 miss 计数并续回周期 keepalive。
 * timeoutSec 省略或 0 = native 默认 5 s（与 P1「切网 5 s 内触发重连」同口径）。
 */
export const probeNow: (handle: number, timeoutSec?: number) => boolean;

/**
 * N12：设置自动重连退避策略（任意时刻可调；重连编排在 ArkTS 侧
 * SessionManager，native 不自行重连）。
 * delaysSec：逐次重连前等待秒数序列，空数组 = 恢复默认 [1,2,5,10,20,30]；
 * 次数超出序列长度钳到最后档。maxAttempts：最大重连次数（默认 6，0 = 无限）
 */
export const setReconnectPolicy: (handle: number, delaysSec: number[], maxAttempts: number) => boolean;

/**
 * N12：查询第 attempt 次重连（从 1 计）前的建议等待秒数；
 * -1 = 已达上限（或句柄无效），放弃重连。
 * 用法：stateChange 进 disconnected 且 reconnectHint=true 时，attempt 从 1 起
 * 逐次查询并自行倒计时，到点后新建会话重连
 */
export const nextReconnectDelaySec: (handle: number, attempt: number) => number;

// ------------------------------------------------------------------
// N9 应用内 SSH Agent（进程级内存密钥托管，多会话复用，超时自动清除）
// 语义详见 cpp/ssh/agent.h：unlock 成功 = 格式粗检 + 入库，有效性在首次
// 认证时才验证；超时为惰性判定（公开 API 调用时检查滑动窗口）。
// ------------------------------------------------------------------

/** 解锁并托管私钥（keyId 由上层分配，如密钥 id / 主机配置 id） */
export const agentUnlock: (
  keyId: string,
  privateKey: ArrayBuffer | string,
  passphrase: string
) => boolean;

/** 锁定指定 keyId（清除托管材料）；不存在返回 false */
export const agentLock: (keyId: string) => boolean;

/** 锁定全部（幂等） */
export const agentLockAll: () => boolean;

/** keyId 是否锁定（不存在/已清除/已超时 → true） */
export const agentIsLocked: (keyId: string) => boolean;

/** 当前托管密钥条数 */
export const agentKeyCount: () => number;

/** 托管超时（分钟，0 = 永不超时；默认 0） */
export const agentSetTimeout: (minutes: number) => boolean;

export const agentTimeoutMinutes: () => number;

/**
 * 会话 agent 认证（仅 authenticating 受理）。从进程级 agent 取 keyId
 * 托管的私钥/短语做公钥认证；未解锁/无 keyId 时返回 false，不消耗
 * 认证重试计数（session.h 受理语义）
 */
export const authenticateAgent: (handle: number, keyId: string) => boolean;

/**
 * U3：生成 ed25519 密钥对（OpenSSL EVP）。
 * 私钥为 PKCS#8 PEM（空短语 = BEGIN PRIVATE KEY；非空 = BEGIN ENCRYPTED PRIVATE KEY，
 * AES-256-CBC）。公钥为 OpenSSH 单行 `ssh-ed25519 <b64> [comment]`。
 * 失败返回 null。详见 cpp/ssh/keygen.h。
 */
export interface NativeAgentKeygenResult {
  keyType: string;
  privateKeyPem: string;
  publicKeyLine: string;
  comment: string;
}

export const agentKeygen: (
  comment: string,
  passphrase: string
) => NativeAgentKeygenResult | null;

// ------------------------------------------------------------------
// T3 终端零拷贝快照（终端桥接；帧协议与生命周期保护的完整约定见
// cpp/bridge/terminal_bridge.h 与 cpp/term/frame_sync.h 头注）
//
// 单元格布局（Cell，16 字节/格，行优先，小端——与 cpp/term/grid.h 一致）：
//   偏移 0  u32  Unicode 码点（0 = 空；0xFFFFFFFF = 宽字符续格）
//   偏移 4  u32  前景色 ARGB
//   偏移 8  u32  背景色 ARGB
//   偏移 12 u16  属性位（bit0 bold / bit1 italic / bit2 underline / bit3 blink /
//                bit4 reverse / bit5 strike / bit6 dim 预留 / bit7 宽字符首格）
//   偏移 14 u16  保留
//
// R-9 双路径设计（external arraybuffer 在 ArkTS 运行时的可用性待真机 spike N3b）：
//   - 主路径：beginFrame 返回的 grid 为 external ArrayBuffer，直接映射 native
//     网格内存（零拷贝）；native 侧 resize/teardown 后旧 buffer 仍读到冻结的
//     旧内容（shared_ptr 保活 + finalize 延迟回收），不会读到已释放内存；
//   - 兜底路径：copyGridRows(handle, startRow, count) 每次拷贝指定行区间返回
//     （普通 ArrayBuffer；满屏 80×24×16B = 30KB，成本可忽略）；
//   - 探测：attach 后用 selfTestGrid 拿 32 字节已知模式的 external 视图，
//     DataView 读回逐字节比对；不一致则永久切兜底（ArkTS 侧封装
//     SshTerminal.ets 已实现该自动降级）。
// ------------------------------------------------------------------

/**
 * 帧快照（beginFrame 返回值）。
 * grid 为网格内存视图：gridZeroCopy=true 时是 external ArrayBuffer（零拷贝，
 * 直接映射 native 存储）；false 时是整屏拷贝（external 创建失败的自动回落）。
 * dirty 为脏行位图快照（u64 字数组，行 r 的脏位 = 字 [r>>6] 的位 r&63；
 * 小端，可按 u32 视图读：字 [r>>5] 的位 r&31）。
 * revision 为帧有效性判据：读完网格后调 endFrame(handle, revision)，
 * native 侧若期间无新写入则清脏位图；不一致则保留（下帧重绘，自愈）。
 * 注意网格读取与远端输出并发：单格读取可能撕裂，撕裂内容最多在屏一帧
 * （下一帧 revision 不一致触发重绘修正）。
 */
export interface TerminalFrameSnapshot {
  grid?: ArrayBuffer;
  gridZeroCopy: boolean;
  revision: number;
  cols: number;
  rows: number;
  cursorRow: number;
  cursorCol: number;
  cursorVisible: boolean;
  altScreen: boolean;
  /** 鼠标上报模式：0=关 1=点击(1000) 2=拖动(1002) 3=任意移动(1003) */
  mouseMode: number;
  /** T10 stub：DECCKM 应用光标键（native 未暴露前缺省 undefined/false） */
  applicationCursorKeys?: boolean;
  bellCount: number;
  /** 回滚有效窗口 [scrollbackOldest, scrollbackTotal)，getScrollbackWindow 的查询基准 */
  scrollbackOldest: number;
  scrollbackTotal: number;
  /** 脏行位图（u64 字数组的 ArrayBuffer 拷贝）；无脏行时仍为非空（全零） */
  dirty?: ArrayBuffer;
}

/**
 * 在会话上创建终端并绑定一个新 shell 通道（PTY）：通道数据在 native 会话
 * 循环线程内直接喂 vterm（零 ArkTS 参与的数据面），渲染经 beginFrame 快照。
 * 返回终端句柄（>0 = 已受理，通道打开结果经 terminalOpen 事件回报；
 * 0 = 未受理，如会话未 established）。termType 如 "xterm-256color"
 */
export const attachTerminal: (
  sessionHandle: number,
  termType: string,
  cols: number,
  rows: number
) => number;

/**
 * 关闭终端（幂等；false = 句柄不存在或已关闭）。摘除句柄后立即返回，
 * 通道关闭与 native 资源回收在后台完成；已有的帧快照/旧 grid buffer
 * 仍可安全读取（生命周期保护）
 */
export const detachTerminal: (terminalHandle: number) => boolean;

/**
 * 取当前帧快照（同步返回；句柄无效返回 null）。网格以 external ArrayBuffer
 * 零拷贝暴露（external 创建失败自动回落为整屏拷贝并置 gridZeroCopy=false）。
 * 快照携带的 storage 保活句柄保证：之后 native resize/释放，本帧 buffer
 * 读到的仍是存活的旧内容
 */
export const beginFrame: (terminalHandle: number) => TerminalFrameSnapshot | null;

/**
 * 帧消费回执（受理语义）：post 进会话循环线程，网格 revision 仍等于
 * seenRevision 则清脏位图并重新发布；不一致则保留脏位（期间又脏了，
 * 下帧 beginFrame 仍会拿到这些行）。false = 句柄无效/已关闭
 */
export const endFrame: (terminalHandle: number, seenRevision: number) => boolean;

/** 当前已发布的网格 revision（-1 = 句柄无效）。帧循环每帧先比对本地值，变了才 beginFrame */
export const getRevision: (terminalHandle: number) => number;

/**
 * R-9 探测点：返回 32 字节已知模式自检块的 external ArrayBuffer 视图
 * （失败返回 null）。模式布局（与 native terminal_bridge.cpp
 * MakeSelfTestPattern 一致，改一侧必须同步另一侧）：
 *   字节 0-7   "SSHTGRID"
 *   字节 8-11  u32 LE = 0x01020304（端序校验）
 *   字节 12-15 u32 LE = 0xA5A55A5A
 *   字节 16-31 递增值 0x00..0x0F
 * ArkTS 读回逐字节比对，不一致即永久切 copyGridRows 兜底
 */
export const selfTestGrid: (terminalHandle: number) => ArrayBuffer | null;

/**
 * 兜底路径：从最新发布快照拷贝 [startRow, startRow+count) 行区间，
 * 返回 count' × cols × 16B 的普通 ArrayBuffer（count' 为钳制后的行数；
 * 越界/句柄无效返回 null）
 */
export const copyGridRows: (
  terminalHandle: number,
  startRow: number,
  count: number
) => ArrayBuffer | null;

/**
 * 回滚窗口拷贝：absoluteIndex ∈ [scrollbackOldest, scrollbackTotal)，
 * 返回 count × cols × 16B 的普通 ArrayBuffer（越界行填零值 Cell；
 * cols 取最新帧快照的 cols）。回滚量小频次低，不做零拷贝
 */
export const getScrollbackWindow: (
  terminalHandle: number,
  startIndex: number,
  count: number
) => ArrayBuffer | null;

/**
 * 向终端绑定的 shell 通道写数据（ArrayBuffer 或 string）。
 * false = 终端已关/背压拒收（4 MiB 待发队列上限，整次拒收，稍后重试）
 */
export const writeTerminal: (terminalHandle: number, data: ArrayBuffer | string) => boolean;

/**
 * 调整终端尺寸（受理语义）：post 进会话循环线程驱动 vterm resize +
 * 通道 request_pty_size（远端收 SIGWINCH）；网格换入新存储后立刻发布新快照，
 * 下一次 beginFrame 拿到新尺寸的 grid；旧 grid buffer 仍读到冻结旧内容
 */
export const resizeTerminal: (terminalHandle: number, cols: number, rows: number) => boolean;

/**
 * 注入外观默认前后景色（ARGB 无符号 32 位）。post 进会话循环线程调用
 * VtermBridge::setDefaultColors，空白格与 DEFAULT 色按新值重解析并发布快照。
 */
export const setTerminalDefaultColors: (
  terminalHandle: number,
  fgArgb: number,
  bgArgb: number
) => boolean;

/** 保险库 create 结果（recoveryKey 只应展示一次） */
export interface VaultNativeCreateResult {
  handle: number;
  keyVersion: number;
  passwordWrappedKey: string;
  passwordWrapNonce: string;
  recoveryWrappedKey: string;
  recoveryWrapNonce: string;
  kdfSalt: string;
  recoveryKey: string;
}

export interface VaultNativeSeal {
  schemaVersion: number;
  keyVersion: number;
  algorithm: string;
  nonce: string;
  ciphertext: string;
  ciphertextHash: string;
}

export const vaultCreate: (password: string, keyVersion: number) => VaultNativeCreateResult | null;
export const vaultUnlockPassword: (
  password: string,
  keyVersion: number,
  kdfSalt: string,
  passwordWrappedKey: string,
  passwordWrapNonce: string
) => number;
export const vaultUnlockRecovery: (
  recoveryKey: string,
  keyVersion: number,
  recoveryWrappedKey: string,
  recoveryWrapNonce: string
) => number;
export const vaultEncrypt: (
  handle: number,
  vaultId: string,
  schemaVersion: number,
  keyVersion: number,
  plaintext: string
) => VaultNativeSeal | null;
export const vaultDecrypt: (
  handle: number,
  vaultId: string,
  schemaVersion: number,
  keyVersion: number,
  nonce: string,
  ciphertext: string
) => string | null;
export const vaultRewrap: (
  handle: number,
  newPassword: string,
  keyVersion: number
) => VaultNativeCreateResult | null;
export const vaultRotate: (handle: number, password: string) => VaultNativeCreateResult | null;
export const vaultClose: (handle: number) => boolean;

// ------------------------------------------------------------------
// N14 SFTP（事件随所属会话 onEvent 上抛）
// 事件 type：
// - sftpOpen：sftp / success / error / message
// - sftpList：sftp / success / path / error / message / entriesJson
// - sftpStat：sftp / success / path / error / message / entryJson
// - sftpOpDone：sftp / success / op / path / error / message / linkTarget
// - sftpProgress：sftp / transferId / transferred / total
// - sftpTransferDone：sftp / transferId / success / error / message /
//   transferred / total
// entriesJson / entryJson 字段见 SftpNativeEntry。
// ------------------------------------------------------------------

export interface SftpNativeEntry {
  name: string;
  path: string;
  /** file | dir | symlink | other */
  type: string;
  size: number;
  mtime: number;
  mode: number;
  /** "rwxr-xr-x" */
  permissions: string;
  linkTarget: string;
}

/**
 * 在已 established 的会话上打开 SFTP 通道。
 * 返回句柄（>0 = 已受理，打开结果经 sftpOpen 事件）；0 = 未受理
 */
export const sftpOpen: (sessionHandle: number) => number;

/** 关闭 SFTP（幂等） */
export const sftpClose: (sftpHandle: number) => boolean;

/** 列目录；结果经 sftpList（entriesJson） */
export const sftpList: (sftpHandle: number, path: string) => boolean;

/** 路径 stat；结果经 sftpStat（entryJson） */
export const sftpStat: (sftpHandle: number, path: string) => boolean;

/**
 * 下载远端文件到本地路径（应用沙箱内 POSIX 路径）。
 * transferId 由上层分配（与 TransferQueue 对齐）；进度/终态经
 * sftpProgress / sftpTransferDone
 */
export const sftpDownload: (
  sftpHandle: number,
  transferId: number,
  remotePath: string,
  localPath: string
) => boolean;

/** 上传本地文件到远端路径；事件同 sftpDownload */
export const sftpUpload: (
  sftpHandle: number,
  transferId: number,
  localPath: string,
  remotePath: string
) => boolean;

/** 重命名；结果经 sftpOpDone（op=rename） */
export const sftpRename: (sftpHandle: number, fromPath: string, toPath: string) => boolean;

export const sftpMkdir: (sftpHandle: number, path: string, mode?: number) => boolean;

export const sftpRmdir: (sftpHandle: number, path: string) => boolean;

export const sftpUnlink: (sftpHandle: number, path: string) => boolean;

export const sftpChmod: (sftpHandle: number, path: string, mode: number) => boolean;

/** 读软链接目标；sftpOpDone.linkTarget */
export const sftpReadlink: (sftpHandle: number, path: string) => boolean;

// ------------------------------------------------------------------
// N15 端口转发（事件随所属会话 onEvent 上抛）
// 事件 type：
// - forwardOpen：forward / success / error / message
//   （direct-tcpip 数据通道打开结果）
// - forwardData：forward / data（ArrayBuffer，远端→本端字节）
// - forwardClose：forward / reason（peer_eof|local_close|error|session_lost）/ message
// - forwardListen：forward（listen 句柄）/ success / boundPort / error / message
//   （远程 -R 监听打开；sshd 需 AllowTcpForwarding）
// - forwardAccept：forward（新数据通道句柄）/ listen（监听句柄）/ success / origin
//   （origin 常为空：libssh2 未暴露 originator host:port）
//
// N16 ProxyJump 缺口：native 仅提供规划/注记 API；多级会话串联需要
// SshSession 抽象传输层（LIBSSH2_CALLBACK_SEND/RECV），尚未打通。
// ------------------------------------------------------------------

/**
 * 在已 established 的会话上打开 direct-tcpip 通道（-L / -D 的数据面）。
 * 返回句柄（>0 = 已受理，打开结果经 forwardOpen）；0 = 未受理。
 * host:port 为远端网络内可达目标；写入用 forwardWrite。
 */
export const openDirectTcpip: (
  sessionHandle: number,
  host: string,
  port: number
) => number;

/**
 * 向转发数据通道写入（ArrayBuffer 或 string）。
 * false = 通道已关 / 背压拒收（4 MiB 上限，整次拒收，稍后重试）
 */
export const forwardWrite: (forwardHandle: number, data: ArrayBuffer | string) => boolean;

/** 关闭转发数据通道或远程监听（幂等） */
export const forwardClose: (forwardHandle: number) => boolean;

/**
 * 开启远程转发监听（-R）。bindAddress 空串 = 服务器默认；port 为远端监听端口。
 * 返回 listen 句柄（>0 = 已受理，结果经 forwardListen）；0 = 未受理。
 * 入站连接经 forwardAccept 上抛新数据通道句柄。
 */
export const remoteForwardListen: (
  sessionHandle: number,
  bindAddress: string,
  port: number
) => number;

/** 取消远程监听（等价 forwardClose） */
export const remoteForwardCancel: (listenHandle: number) => boolean;

/** N16：ProxyJump 传输层设计注记（多行英文说明；诊断/文档用） */
export const forwardProxyJumpNotes: () => string;

/**
 * N16：解析 OpenSSH ProxyJump 规格（-J 子集）。
 * 返回 hops 的 JSON 数组字符串：[{username,host,port},…]；非法规格返回 "[]"。
 */
export const forwardParseJumpSpec: (spec: string) => string;
