/**
 * SSH 错误码与中文文案映射（DESIGN §7.1 / N13，X4 交付）。
 *
 * N13 统一错误码体系：本枚举的数值码是跨层（native → ArkTS）传递的唯一契约，
 * native 侧 cpp/ssh/error_codes.h 的 kSshErrorCode* 常量与 toSshErrorCode() 映射到
 * 与本枚举**完全一致**的数值；bridge 的 stateChange 终态事件携带数值 errorCode，
 * 上层经 SshError.fromNativeCode() 收为枚举，展示层统一走 toUserMessage() 取中文提示。
 *
 * 数值分段：1xx 连接与网络、2xx 认证、3xx 协商与主机密钥、4xx 会话、
 * 5xx 内部、999 兜底。0 为「无错误」保留值（native 不投递，fromNativeCode(0) 归 UNKNOWN）。
 *
 * 防漂移：新增/修改错误码必须三处同步——本文件、cpp/ssh/error_codes.h、
 * 两侧测试；scripts/check-error-codes.sh 在 CI 对拍两份码表，不一致即门禁失败。
 */

/** 统一 SSH 错误码 */
export enum SshErrorCode {
  /** DNS 解析失败 */
  DNS_FAILED = 101,
  /** 连接超时 */
  CONNECT_TIMEOUT = 102,
  /** 连接被拒绝 */
  CONNECT_REFUSED = 103,
  /** 网络不可达 */
  NETWORK_UNREACHABLE = 104,
  /** 认证失败：密码 */
  AUTH_PASSWORD_FAILED = 201,
  /** 认证失败：公钥 */
  AUTH_PUBLICKEY_FAILED = 202,
  /** 认证失败：keyboard-interactive */
  AUTH_KEYBOARD_INTERACTIVE_FAILED = 203,
  /** 私钥短语错误或私钥无法加载 */
  AUTH_PASSPHRASE_FAILED = 204,
  /** 认证超时（对端在认证期不应答） */
  AUTH_TIMEOUT = 205,
  /**
   * 本机凭据库里没有该主机的凭据（native 不产出，纯上层编排码）。
   * 与 AUTH_* 系列的区别：不是服务器拒绝，而是压根还没拿到凭据——
   * 上层据此弹出输入框补录，而不是当成连接失败。
   */
  CREDENTIAL_MISSING = 206,
  /** 算法协商失败 */
  ALGORITHM_NEGOTIATION_FAILED = 301,
  /** 主机密钥未知（TOFU 待用户确认；native 不产出，由上层编排使用） */
  HOST_KEY_UNKNOWN = 302,
  /** 主机密钥与本地记录不匹配 */
  HOST_KEY_MISMATCH = 303,
  /** SSH 握手失败（banner/协议错误等非算法类） */
  HANDSHAKE_FAILED = 304,
  /** SSH 握手超时 */
  HANDSHAKE_TIMEOUT = 305,
  /** 连接被远端关闭 */
  CONNECTION_CLOSED_BY_REMOTE = 401,
  /** 会话超时（通用；native 优先产出更细分的码，如 205/305/404） */
  SESSION_TIMEOUT = 402,
  /** 底层 socket 错误 */
  SOCKET_ERROR = 403,
  /** keepalive 静默黑洞（连续无入站活动判定断线） */
  KEEPALIVE_TIMEOUT = 404,
  /** 内部错误（资源创建失败等） */
  INTERNAL_ERROR = 500,
  /** 未知错误（兜底，占比应受控，见 N13 验收） */
  UNKNOWN = 999
}

/** 全部错误码清单：N13 native 对齐与测试遍历的唯一来源，新增枚举必须同步追加 */
export const ALL_SSH_ERROR_CODES: SshErrorCode[] = [
  SshErrorCode.DNS_FAILED,
  SshErrorCode.CONNECT_TIMEOUT,
  SshErrorCode.CONNECT_REFUSED,
  SshErrorCode.NETWORK_UNREACHABLE,
  SshErrorCode.AUTH_PASSWORD_FAILED,
  SshErrorCode.AUTH_PUBLICKEY_FAILED,
  SshErrorCode.AUTH_KEYBOARD_INTERACTIVE_FAILED,
  SshErrorCode.AUTH_PASSPHRASE_FAILED,
  SshErrorCode.AUTH_TIMEOUT,
  SshErrorCode.ALGORITHM_NEGOTIATION_FAILED,
  SshErrorCode.HOST_KEY_UNKNOWN,
  SshErrorCode.HOST_KEY_MISMATCH,
  SshErrorCode.HANDSHAKE_FAILED,
  SshErrorCode.HANDSHAKE_TIMEOUT,
  SshErrorCode.CONNECTION_CLOSED_BY_REMOTE,
  SshErrorCode.SESSION_TIMEOUT,
  SshErrorCode.SOCKET_ERROR,
  SshErrorCode.KEEPALIVE_TIMEOUT,
  SshErrorCode.INTERNAL_ERROR,
  SshErrorCode.UNKNOWN
];

/** SSH 业务异常：错误码 + 原始 message + 底层 cause */
export class SshError extends Error {
  /** 统一错误码（展示层据此取中文提示） */
  readonly code: SshErrorCode;
  /** 底层原始异常（如 socket / libssh2 抛出的 Error） */
  readonly cause?: Error;

  constructor(code: SshErrorCode, message: string, cause?: Error) {
    super(message);
    this.name = 'SshError';
    this.code = code;
    this.cause = cause;
  }

  /** 面向用户的中文提示，等价于 SshError.toUserMessage(this.code) */
  toUserMessage(): string {
    return SshError.toUserMessage(this.code);
  }

  /**
   * native 数值错误码 → 枚举（N13 跨层收口；bridge stateChange 终态事件的 errorCode）。
   * 已识别数值原样返回；未识别数值（含保留值 0）归 UNKNOWN——native 侧
   * toSshErrorCode() 映射穷尽（tests/error_codes_test.cpp 断言），正常不会走到兜底。
   */
  static fromNativeCode(code: number): SshErrorCode {
    for (const known of ALL_SSH_ERROR_CODES) {
      if (known === code) {
        return known;
      }
    }
    return SshErrorCode.UNKNOWN;
  }

  /** 错误码 → 中文可读提示（DESIGN §7.1）；每个枚举都有明确文案，UNKNOWN 兜底 */
  static toUserMessage(code: SshErrorCode): string {
    switch (code) {
      case SshErrorCode.DNS_FAILED:
        return '无法解析主机名，请检查主机地址是否正确';
      case SshErrorCode.CONNECT_TIMEOUT:
        return '连接超时，请检查网络或确认主机在线';
      case SshErrorCode.CONNECT_REFUSED:
        return '连接被拒绝，请确认主机已开启 SSH 服务且端口正确';
      case SshErrorCode.NETWORK_UNREACHABLE:
        return '网络不可达，请检查设备的网络连接';
      case SshErrorCode.AUTH_PASSWORD_FAILED:
        return '密码认证失败，请检查用户名和密码';
      case SshErrorCode.AUTH_PUBLICKEY_FAILED:
        return '公钥认证失败，请检查私钥文件或密码短语';
      case SshErrorCode.AUTH_KEYBOARD_INTERACTIVE_FAILED:
        return '交互式认证失败，请检查验证码或应答内容';
      case SshErrorCode.AUTH_PASSPHRASE_FAILED:
        return '私钥解密失败，请检查私钥密码短语或私钥文件是否损坏';
      case SshErrorCode.AUTH_TIMEOUT:
        return '认证超时，服务器在认证过程中未应答';
      case SshErrorCode.CREDENTIAL_MISSING:
        return '本机还没有保存该主机的凭据';
      case SshErrorCode.ALGORITHM_NEGOTIATION_FAILED:
        return '加密算法协商失败，客户端与服务器无共同支持的算法';
      case SshErrorCode.HOST_KEY_UNKNOWN:
        return '首次连接该主机，请核对主机指纹后确认信任';
      case SshErrorCode.HOST_KEY_MISMATCH:
        return '主机密钥与本地记录不匹配，可能存在安全风险，连接已拒绝';
      case SshErrorCode.HANDSHAKE_FAILED:
        return 'SSH 握手失败，请确认对端是 SSH 服务且协议版本兼容';
      case SshErrorCode.HANDSHAKE_TIMEOUT:
        return 'SSH 握手超时，请检查网络或确认对端 SSH 服务正常';
      case SshErrorCode.CONNECTION_CLOSED_BY_REMOTE:
        return '连接被远端主机关闭';
      case SshErrorCode.SESSION_TIMEOUT:
        return '会话超时，连接已断开';
      case SshErrorCode.SOCKET_ERROR:
        return '连接发生网络错误，请检查网络连接后重试';
      case SshErrorCode.KEEPALIVE_TIMEOUT:
        return '心跳检测超时，连接已断开（网络可能已中断）';
      case SshErrorCode.INTERNAL_ERROR:
        return '客户端内部错误，请重试或重启应用';
      case SshErrorCode.UNKNOWN:
        return '未知错误';
      default:
        return '未知错误';
    }
  }
}
