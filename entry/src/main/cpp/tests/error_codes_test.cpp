/**
 * N13 统一错误码测试 —— ssh/error_codes.h（SshSessionError → 统一数值码）。
 *
 * 覆盖：
 *   - 穷尽性（N13 验收「未知错误兜底占比受控」的可验收形态）：SshSessionError
 *     全部枚举值的映射结果都不得是 kSshErrorCodeUnknown——新增枚举值忘了补
 *     toSshErrorCode 分支时本测试立即变红（kAllSessionErrors 清单须同步追加，
 *     且 toSshErrorCode 的 switch 无 default，-Wswitch 也会点名）；
 *   - 数值锚定：每个枚举值映射到的数值与 ArkTS 侧
 *     entry/src/main/ets/common/SshError.ets 的 SshErrorCode 逐一相等。
 *     两侧清单由 scripts/check-error-codes.sh 在 CI 对拍（改一侧不同步即门禁失败）；
 *   - toString(SshSessionError)：全部枚举值都有非 "unknown" 的名字（bridge 的
 *     errorCodeName 调试字段来源）。
 */
#include <gtest/gtest.h>

#include <cstring>

#include "ssh/error_codes.h"
#include "ssh/session.h"

using sshclient::ssh::SshSessionError;
using sshclient::ssh::toSshErrorCode;
using sshclient::ssh::toString;
namespace codes = sshclient::ssh;

namespace {

// SshSessionError 全部枚举值（与 ssh/session.h 一一对应；新增枚举值必须追加，
// 否则穷尽性断言覆盖不到它）
constexpr SshSessionError kAllSessionErrors[] = {
    SshSessionError::kNone,
    SshSessionError::kResolveFailed,
    SshSessionError::kConnectFailed,
    SshSessionError::kConnectUnreachable,
    SshSessionError::kConnectTimeout,
    SshSessionError::kHandshakeFailed,
    SshSessionError::kHandshakeTimeout,
    SshSessionError::kAlgorithmNegotiationFailed,
    SshSessionError::kHostKeyMismatch,
    SshSessionError::kAuthFailedPassword,
    SshSessionError::kAuthFailedKey,
    SshSessionError::kAuthFailedPassphrase,
    SshSessionError::kAuthFailedInteractive,
    SshSessionError::kAuthTimeout,
    SshSessionError::kDisconnectedByPeer,
    SshSessionError::kSocketError,
    SshSessionError::kKeepaliveTimeout,
    SshSessionError::kInternal,
};

// ================================================================== 穷尽性

TEST(SshErrorCodeTest, MappingIsExhaustive_NeverUnknown)
{
    for (SshSessionError err : kAllSessionErrors) {
        const int code = toSshErrorCode(err);
        EXPECT_NE(code, codes::kSshErrorCodeUnknown)
            << "SshSessionError::" << toString(err) << " 映射到了 UNKNOWN 兜底——"
            << "请在 error_codes.h 补 toSshErrorCode 分支与对应常量";
        if (err == SshSessionError::kNone) {
            EXPECT_EQ(code, codes::kSshErrorCodeNone); // 无错误 = 保留值 0
        } else {
            EXPECT_GT(code, 0) << toString(err) << " 不应映射到保留值 0";
        }
    }
}

// ================================================================== 数值锚定（与 ArkTS SshErrorCode 一致）

TEST(SshErrorCodeTest, MappingMatchesArktsTable)
{
    EXPECT_EQ(toSshErrorCode(SshSessionError::kNone), 0);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kResolveFailed), 101);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kConnectTimeout), 102);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kConnectFailed), 103);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kConnectUnreachable), 104);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kAuthFailedPassword), 201);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kAuthFailedKey), 202);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kAuthFailedInteractive), 203);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kAuthFailedPassphrase), 204);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kAuthTimeout), 205);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kAlgorithmNegotiationFailed), 301);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kHostKeyMismatch), 303);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kHandshakeFailed), 304);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kHandshakeTimeout), 305);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kDisconnectedByPeer), 401);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kSocketError), 403);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kKeepaliveTimeout), 404);
    EXPECT_EQ(toSshErrorCode(SshSessionError::kInternal), 500);
    // 302 HOST_KEY_UNKNOWN / 402 SESSION_TIMEOUT：native 不产出（TOFU 待确认在
    // ArkTS 侧编排；会话通用超时由细分码优先），只存在于 ArkTS 码表
}

// ================================================================== toString 名字（bridge errorCodeName 来源）

TEST(SshErrorCodeTest, ToStringCoversAllErrors)
{
    for (SshSessionError err : kAllSessionErrors) {
        const char *name = toString(err);
        ASSERT_NE(name, nullptr);
        EXPECT_STRNE(name, "unknown") << "枚举值缺少 toString 分支";
        EXPECT_STRNE(name, "");
    }
}

} // namespace
