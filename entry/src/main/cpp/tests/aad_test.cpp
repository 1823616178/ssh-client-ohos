/**
 * AAD 编码单测 —— 任务 N4 的框架样例，也是 DESIGN §6.2 AAD 格式的第一道防线。
 *
 * 断言规则：<utf8字节长度>:<值> 编码、| 连接、<domain>| 前缀。
 * S2（native 保险库密码学）落地时，本文件的期望值即 AAD 黄金格式的回归基线。
 */
#include <gtest/gtest.h>

#include "crypto/aad.hpp"

using sshclient::crypto::EncodeAad;
using sshclient::crypto::SyncDocumentAad;
using sshclient::crypto::VaultKeyPasswordAad;
using sshclient::crypto::VaultKeyRecoveryAad;

// 三个域的完整拼接结果，逐字节对齐 DESIGN §6.2 表格
TEST(AadTest, SyncDocumentAadMatchesDesign)
{
    EXPECT_EQ(SyncDocumentAad("vault-abc", "1", "7"),
              "ssh-client-ohos/sync-document/v1|9:vault-abc|1:1|1:7");
}

TEST(AadTest, VaultKeyPasswordAadMatchesDesign)
{
    EXPECT_EQ(VaultKeyPasswordAad("7"), "ssh-client-ohos/vault-key/password/v1|1:7");
}

TEST(AadTest, VaultKeyRecoveryAadMatchesDesign)
{
    EXPECT_EQ(VaultKeyRecoveryAad("12"), "ssh-client-ohos/vault-key/recovery/v1|2:12");
}

// 长度前缀是 UTF-8 字节数，不是字符数："主机" 二字共 6 字节
TEST(AadTest, LengthPrefixCountsUtf8Bytes)
{
    EXPECT_EQ(EncodeAad("d", {"主机"}), "d|6:主机");
}

// 长度前缀存在的意义：消除字段边界歧义（§6.2「不能省」）
TEST(AadTest, LengthPrefixDisambiguatesFieldBoundaries)
{
    EXPECT_NE(EncodeAad("d", {"12", "3"}), EncodeAad("d", {"1", "23"}));
    EXPECT_EQ(EncodeAad("d", {"12", "3"}), "d|2:12|1:3");
}

// 边界：空字段编码为 0:；无字段时只有 domain，不留尾部分隔符
TEST(AadTest, EmptyFieldAndNoFields)
{
    EXPECT_EQ(EncodeAad("d", {""}), "d|0:");
    EXPECT_EQ(EncodeAad("d", {}), "d");
}
