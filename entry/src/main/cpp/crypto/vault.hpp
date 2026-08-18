/**
 * 保险库密码学（任务 S2，docs/SYNC-PROTOCOL.md §2）。
 *
 * Argon2id / AES-256-GCM / HKDF-SHA256 / 恢复密钥 / ciphertextHash。
 * 参数一律来自 sync_params.h。密钥与口令用完 OPENSSL_cleanse。
 * 禁止 include NAPI / hilog。
 */
#pragma once

#include "sync_params.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace sshclient {
namespace crypto {

void SecureClear(void *ptr, std::size_t len);

std::string HexLower(const std::uint8_t *data, std::size_t len);
std::string HexUpper(const std::uint8_t *data, std::size_t len);
bool HexDecode(std::string_view hex, std::vector<std::uint8_t> *out);

bool Argon2idHash(std::string_view password, const std::uint8_t *salt, std::size_t salt_len,
                  std::uint8_t out[kArgon2HashLen]);

bool HkdfSha256(const std::uint8_t *ikm, std::size_t ikm_len, const std::uint8_t *salt,
                std::size_t salt_len, std::string_view info, std::uint8_t *out, std::size_t out_len);

/** 密文 = AES-256-GCM(pt) || tag(16)。成功时 out 长度为 pt_len + kAesTagLen。 */
bool Aes256GcmEncrypt(const std::uint8_t key[kArgon2HashLen],
                      const std::uint8_t nonce[kAesNonceLen], std::string_view aad,
                      const std::uint8_t *plaintext, std::size_t plaintext_len,
                      std::vector<std::uint8_t> *out);

bool Aes256GcmDecrypt(const std::uint8_t key[kArgon2HashLen],
                      const std::uint8_t nonce[kAesNonceLen], std::string_view aad,
                      const std::uint8_t *ct_and_tag, std::size_t ct_and_tag_len,
                      std::vector<std::uint8_t> *plaintext);

/** SHA-256(密文含 tag) → 64 位小写十六进制 */
std::string CiphertextHashHex(const std::uint8_t *ct_and_tag, std::size_t len);

/** SPM1-<b64url43>-<12 位大写十六进制校验> */
std::string EncodeRecoveryKey(const std::uint8_t raw[kArgon2HashLen]);
bool DecodeRecoveryKey(std::string_view encoded, std::uint8_t raw[kArgon2HashLen]);

/** HKDF-SHA256(salt 空, info = kHkdfInfoRecoveryKek) */
bool DeriveRecoveryKek(const std::uint8_t raw[kArgon2HashLen], std::uint8_t kek[kHkdfOutLen]);

/** 标准 Base64（信封 nonce / ciphertext，服务端校验） */
std::string Base64StdEncode(const std::uint8_t *data, std::size_t len);
bool Base64StdDecode(std::string_view in, std::vector<std::uint8_t> *out);

bool RandomBytes(std::uint8_t *out, std::size_t len);

/** 密码/恢复密钥包裹后的保险库信封（字段为标准 Base64） */
struct VaultWrap {
    int keyVersion = 1;
    std::string passwordWrappedKey;
    std::string passwordWrapNonce;
    std::string recoveryWrappedKey;
    std::string recoveryWrapNonce;
    std::string kdfSalt;
};

struct DocumentSeal {
    int schemaVersion = kSchemaVersion;
    int keyVersion = 1;
    std::string algorithm;
    std::string nonce;
    std::string ciphertext;
    std::string ciphertextHash;
};

bool CreateVault(std::string_view password, int keyVersion, VaultWrap *wrap,
                 std::string *recoveryKey, std::uint8_t vaultKey[kArgon2HashLen]);

bool UnlockWithPassword(std::string_view password, const VaultWrap &wrap,
                        std::uint8_t vaultKey[kArgon2HashLen]);

bool UnlockWithRecovery(std::string_view recoveryKey, const VaultWrap &wrap,
                        std::uint8_t vaultKey[kArgon2HashLen]);

bool RewrapVault(const std::uint8_t vaultKey[kArgon2HashLen], std::string_view newPassword,
                 int keyVersion, VaultWrap *wrap, std::string *recoveryKey);

bool EncryptDocument(const std::uint8_t vaultKey[kArgon2HashLen], std::string_view vaultId,
                     int schemaVersion, int keyVersion, std::string_view plaintext,
                     DocumentSeal *out);

bool DecryptDocument(const std::uint8_t vaultKey[kArgon2HashLen], std::string_view vaultId,
                     int schemaVersion, int keyVersion, const DocumentSeal &seal,
                     std::string *plaintext);

} // namespace crypto
} // namespace sshclient
