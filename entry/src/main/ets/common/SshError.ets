/**
 * SSH 错误码与中文文案映射（DESIGN §7.1 / N13，任务 X4）。
 *
 * 按 N13 的方向先建 ArkTS 侧的枚举骨架与文案表，native 侧后续对齐同一组数值，
 * 跨层传递只传数值码，展示层统一走 toUserMessage() 映射成中文可读提示。
 *
 * 数值分段：1xx 连接与网络、2xx 认证、3xx 协商与主机密钥、4xx 会话、999 兜底。
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
  /** 算法协商失败 */
  ALGORITHM_NEGOTIATION_FAILED = 301,
  /** 主机密钥未知（TOFU 待用户确认） */
  HOST_KEY_UNKNOWN = 302,
  /** 主机密钥与本地记录不匹配 */
  HOST_KEY_MISMATCH = 303,
  /** 连接被远端关闭 */
  CONNECTION_CLOSED_BY_REMOTE = 401,
  /** 会话超时 */
  SESSION_TIMEOUT = 402,
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
  SshErrorCode.ALGORITHM_NEGOTIATION_FAILED,
  SshErrorCode.HOST_KEY_UNKNOWN,
  SshErrorCode.HOST_KEY_MISMATCH,
  SshErrorCode.CONNECTION_CLOSED_BY_REMOTE,
  SshErrorCode.SESSION_TIMEOUT,
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
      case SshErrorCode.ALGORITHM_NEGOTIATION_FAILED:
        return '加密算法协商失败，客户端与服务器无共同支持的算法';
      case SshErrorCode.HOST_KEY_UNKNOWN:
        return '首次连接该主机，请核对主机指纹后确认信任';
      case SshErrorCode.HOST_KEY_MISMATCH:
        return '主机密钥与本地记录不匹配，可能存在安全风险，连接已拒绝';
      case SshErrorCode.CONNECTION_CLOSED_BY_REMOTE:
        return '连接被远端主机关闭';
      case SshErrorCode.SESSION_TIMEOUT:
        return '会话超时，连接已断开';
      case SshErrorCode.UNKNOWN:
        return '未知错误';
      default:
        return '未知错误';
    }
  }
}
