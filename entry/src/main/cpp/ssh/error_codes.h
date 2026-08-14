/**
 * 统一 SSH 错误码 —— 任务 N13（DESIGN §7.1，TASKS N13）。
 *
 * 单一事实来源是 ArkTS 侧 entry/src/main/ets/common/SshError.ets 的 SshErrorCode
 * 枚举（X4 交付的中文文案表锚在它上面）；本头把 native 的 SshSessionError 映射到
 * 与其**数值完全一致**的码，跨层（bridge → ArkTS）只传数值码，展示层统一走
 * SshError.toUserMessage() 取中文提示。
 *
 * 数值分段：1xx 连接与网络、2xx 认证、3xx 协商与主机密钥、4xx 会话、
 * 5xx 内部、999 兜底。0 为「无错误」保留值（ArkTS 侧无对应枚举成员，bridge 不投递）。
 *
 * 防漂移机制（三处互相指向，改任何一处必须同步另外两处）：
 *   1. 本头的 kSshErrorCode* 常量表（native 侧清单）；
 *   2. SshError.ets 的 SshErrorCode 枚举与 ALL_SSH_ERROR_CODES（ArkTS 侧清单）；
 *   3. scripts/check-error-codes.sh：CI 对拍两份清单，不一致即门禁失败。
 * 映射穷尽性由 tests/error_codes_test.cpp 断言：SshSessionError 任何取值都不得
 * 落到 kSshErrorCodeUnknown（新增枚举值时必须在本头补常量并在下方 switch 补分支）。
 *
 * 纯逻辑头（header-only）：只依赖 session.h 的枚举定义，禁止 include
 * <napi/native_api.h> / <hilog/log.h>。
 */
#pragma once

#include "session.h"

namespace sshclient {
namespace ssh {

// ---- 统一错误码常量（与 ArkTS SshErrorCode 数值一一对应，注释为该码的中文文案摘要）----

inline constexpr int kSshErrorCodeNone = 0; // 无错误（保留值；ArkTS 无此成员，bridge 不投递）

// 1xx 连接与网络
inline constexpr int kSshErrorCodeDnsFailed = 101;          // 无法解析主机名
inline constexpr int kSshErrorCodeConnectTimeout = 102;     // 连接超时
inline constexpr int kSshErrorCodeConnectRefused = 103;     // 连接被拒绝
inline constexpr int kSshErrorCodeNetworkUnreachable = 104; // 网络不可达

// 2xx 认证
inline constexpr int kSshErrorCodeAuthPasswordFailed = 201;             // 密码认证失败
inline constexpr int kSshErrorCodeAuthPublickeyFailed = 202;            // 公钥认证失败
inline constexpr int kSshErrorCodeAuthKeyboardInteractiveFailed = 203;  // 交互式认证失败
inline constexpr int kSshErrorCodeAuthPassphraseFailed = 204;           // 私钥短语错误/私钥无法加载
inline constexpr int kSshErrorCodeAuthTimeout = 205;                    // 认证超时

// 3xx 协商与主机密钥
inline constexpr int kSshErrorCodeAlgorithmNegotiationFailed = 301; // 算法协商失败
inline constexpr int kSshErrorCodeHostKeyUnknown = 302;  // 主机密钥未知（TOFU 待确认；
                                                         // native 不产出，TOFU 编排在 ArkTS 侧）
inline constexpr int kSshErrorCodeHostKeyMismatch = 303; // 主机密钥与本地记录不匹配
inline constexpr int kSshErrorCodeHandshakeFailed = 304; // SSH 握手失败（非算法类）
inline constexpr int kSshErrorCodeHandshakeTimeout = 305; // SSH 握手超时

// 4xx 会话
inline constexpr int kSshErrorCodeConnectionClosedByRemote = 401; // 连接被远端关闭
inline constexpr int kSshErrorCodeSessionTimeout = 402;           // 会话超时（通用；
                                                                  // native 暂不产出，细分码优先）
inline constexpr int kSshErrorCodeSocketError = 403;              // 底层 socket 错误
inline constexpr int kSshErrorCodeKeepaliveTimeout = 404;         // keepalive 静默黑洞

// 5xx 内部
inline constexpr int kSshErrorCodeInternalError = 500; // 内部错误（资源创建失败等）

// 999 兜底（映射函数永不产出；仅 ArkTS fromNativeCode 收到未识别数值时使用）
inline constexpr int kSshErrorCodeUnknown = 999;

// SshSessionError → 统一数值码（kNone → 0）。switch 覆盖全部枚举值、刻意不写
// default：新增枚举值时编译器 -Wswitch 会点名，且 error_codes_test.cpp 的穷尽性
// 断言保证任何取值都落不到 kSshErrorCodeUnknown。
inline int toSshErrorCode(SshSessionError error)
{
    switch (error) {
    case SshSessionError::kNone:                       return kSshErrorCodeNone;
    case SshSessionError::kResolveFailed:              return kSshErrorCodeDnsFailed;
    case SshSessionError::kConnectFailed:              return kSshErrorCodeConnectRefused;
    case SshSessionError::kConnectUnreachable:         return kSshErrorCodeNetworkUnreachable;
    case SshSessionError::kConnectTimeout:             return kSshErrorCodeConnectTimeout;
    case SshSessionError::kHandshakeFailed:            return kSshErrorCodeHandshakeFailed;
    case SshSessionError::kHandshakeTimeout:           return kSshErrorCodeHandshakeTimeout;
    case SshSessionError::kAlgorithmNegotiationFailed: return kSshErrorCodeAlgorithmNegotiationFailed;
    case SshSessionError::kHostKeyMismatch:            return kSshErrorCodeHostKeyMismatch;
    case SshSessionError::kAuthFailedPassword:         return kSshErrorCodeAuthPasswordFailed;
    case SshSessionError::kAuthFailedKey:              return kSshErrorCodeAuthPublickeyFailed;
    case SshSessionError::kAuthFailedPassphrase:       return kSshErrorCodeAuthPassphraseFailed;
    case SshSessionError::kAuthFailedInteractive:      return kSshErrorCodeAuthKeyboardInteractiveFailed;
    case SshSessionError::kAuthTimeout:                return kSshErrorCodeAuthTimeout;
    case SshSessionError::kDisconnectedByPeer:         return kSshErrorCodeConnectionClosedByRemote;
    case SshSessionError::kSocketError:                return kSshErrorCodeSocketError;
    case SshSessionError::kKeepaliveTimeout:           return kSshErrorCodeKeepaliveTimeout;
    case SshSessionError::kInternal:                   return kSshErrorCodeInternalError;
    }
    return kSshErrorCodeUnknown; // 不可达（switch 已穷尽）；防御未知枚举强转
}

} // namespace ssh
} // namespace sshclient
