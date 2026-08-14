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
 *   N12 起进入终态（disconnected/error/closed）时另附：
 *   reconnectHint（是否值得自动重连：disconnected 与链路类 error 为 true，
 *   凭据类失败与主动关闭为 false）与 errorCode（如 keepalive_timeout；
 *   正常关闭无错误时省略）
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
  errorCode?: string;
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
 * errorCode=keepalive_timeout）
 */
export const setKeepalive: (handle: number, intervalSec: number, maxMisses: number) => boolean;

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
