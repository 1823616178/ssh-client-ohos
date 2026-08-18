/**
 * 同步协议常量（任务 S1，docs/SYNC-PROTOCOL.md 的 native 唯一出处）。
 *
 * S2 及之后的 crypto / bridge 只准 include 本文件或 aad.hpp，
 * 禁止再写这些字面量。ArkTS 对应：common/sync/SyncProtocol.ets。
 */
#pragma once

#include <cstddef>
#include <string_view>

namespace sshclient {
namespace crypto {

inline constexpr int kSchemaVersion = 1;
inline constexpr int kArgon2MemoryKib = 65536;
inline constexpr int kArgon2Iterations = 3;
inline constexpr int kArgon2Parallelism = 1;
inline constexpr int kArgon2HashLen = 32;
inline constexpr std::size_t kKdfSaltLen = 16;

inline constexpr std::string_view kAesAlgorithm = "AES-256-GCM";
inline constexpr std::size_t kAesNonceLen = 12;
inline constexpr std::size_t kAesTagLen = 16;

// 域字符串与恢复密钥前缀沿用桌面端 ssh-tool（src/main/security/crypto-vault.ts）的命名空间，
// 两端共用同一个保险库与同步文档。除这几个字面量外，两端的 Argon2 参数、salt/nonce/tag 长度、
// AAD 编码格式与字段顺序本来就逐字节一致，故仅此处需要对齐。改动会使旧的 SCO1 保险库失效。
inline constexpr std::string_view kHkdfInfoRecoveryKek = "ssh-port-mapper/recovery-kek/v1";
inline constexpr std::size_t kHkdfOutLen = 32;

inline constexpr std::string_view kAadDomainSyncDocument = "ssh-port-mapper/sync-document/v1";
inline constexpr std::string_view kAadDomainVaultKeyPassword = "ssh-port-mapper/vault-key/password/v1";
inline constexpr std::string_view kAadDomainVaultKeyRecovery = "ssh-port-mapper/vault-key/recovery/v1";

inline constexpr std::string_view kRecoveryKeyPrefix = "SPM1";
inline constexpr std::size_t kRecoveryKeyRawB64urlLen = 43;
inline constexpr std::size_t kRecoveryKeyCheckHexLen = 12;
inline constexpr std::size_t kCiphertextHashHexLen = 64;

inline constexpr std::size_t kDocumentMaxBytes = 2097152;
inline constexpr std::size_t kPrivateKeyMaxBytes = 262144;
inline constexpr int kHostCountMax = 5000;

} // namespace crypto
} // namespace sshclient
