/**
 * AAD（附加认证数据）构造 —— DESIGN §6.2 的唯一实现出处。
 *
 * 编码规则（沿用桌面端 crypto-vault.ts 的 aad() 思路）：
 *   每个字段编码为 <utf8字节长度>:<值>，字段间用 | 连接，整体前缀 <domain>|。
 *   长度前缀用于消除字段边界歧义，不能省。
 *
 * 本文件是纯逻辑实现：只依赖 C++ 标准库，禁止 include <napi/native_api.h>。
 * 它同时被 OHOS 产物（../CMakeLists.txt 的 libssh_core.so）与
 * 宿主机单元测试（../tests/CMakeLists.txt）编译，两处行为必须一致。
 */
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace sshclient {
namespace crypto {

// DESIGN §6.2 的三个域分隔字符串。其它代码只准引用这些常量，不得再写字面量。
inline constexpr std::string_view kAadDomainSyncDocument = "ssh-client-ohos/sync-document/v1";
inline constexpr std::string_view kAadDomainVaultKeyPassword = "ssh-client-ohos/vault-key/password/v1";
inline constexpr std::string_view kAadDomainVaultKeyRecovery = "ssh-client-ohos/vault-key/recovery/v1";

// 通用编码：<domain>|<len1>:<value1>|<len2>:<value2>...
// fields 为空时返回 domain 本身（无尾部分隔符）。长度取 UTF-8 字节数（string_view::size）。
std::string EncodeAad(std::string_view domain, const std::vector<std::string_view> &fields);

// 文档 AAD：<sync-document 域>|<len>:<vaultId>|<len>:<schemaVersion>|<len>:<keyVersion>
// schemaVersion 按十进制字符串传入（如 "1"），与 DESIGN §6.2 示例一致。
std::string SyncDocumentAad(std::string_view vaultId, std::string_view schemaVersion,
                            std::string_view keyVersion);

// 密码包裹 AAD：<password 域>|<len>:<keyVersion>
std::string VaultKeyPasswordAad(std::string_view keyVersion);

// 恢复包裹 AAD：<recovery 域>|<len>:<keyVersion>
std::string VaultKeyRecoveryAad(std::string_view keyVersion);

} // namespace crypto
} // namespace sshclient
