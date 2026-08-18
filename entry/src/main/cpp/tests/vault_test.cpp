/**
 * 保险库密码学单测（任务 S2）。
 *
 * 覆盖：AES-GCM 往返与篡改拒绝 / 恢复密钥 10000 次往返与篡改拒绝 /
 * HKDF 确定性 / 黄金向量（Argon2id + 文档 AAD 加密 + ciphertextHash）。
 */
#include <gtest/gtest.h>

#include "crypto/aad.hpp"
#include "crypto/vault.hpp"
#include "vault_golden_vectors.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

using sshclient::crypto::Aes256GcmDecrypt;
using sshclient::crypto::Aes256GcmEncrypt;
using sshclient::crypto::Argon2idHash;
using sshclient::crypto::CiphertextHashHex;
using sshclient::crypto::DecodeRecoveryKey;
using sshclient::crypto::DeriveRecoveryKek;
using sshclient::crypto::EncodeRecoveryKey;
using sshclient::crypto::HexDecode;
using sshclient::crypto::HexLower;
using sshclient::crypto::HkdfSha256;
using sshclient::crypto::SecureClear;
using sshclient::crypto::SyncDocumentAad;
using sshclient::crypto::kAesNonceLen;
using sshclient::crypto::kAesTagLen;
using sshclient::crypto::kArgon2HashLen;
using sshclient::crypto::kCiphertextHashHexLen;
using sshclient::crypto::kHkdfOutLen;

TEST(VaultTest, HexRoundTrip)
{
    const std::uint8_t raw[] = {0xDE, 0xAD, 0xBE, 0xEF};
    EXPECT_EQ(HexLower(raw, 4), "deadbeef");
    std::vector<std::uint8_t> back;
    ASSERT_TRUE(HexDecode("deadbeef", &back));
    ASSERT_EQ(back.size(), 4U);
    EXPECT_EQ(back[0], 0xDE);
    EXPECT_FALSE(HexDecode("zz", &back));
}

TEST(VaultTest, AesGcmRoundTripAndTamperRejected)
{
    std::uint8_t key[kArgon2HashLen];
    std::uint8_t nonce[kAesNonceLen];
    for (std::size_t i = 0; i < kArgon2HashLen; ++i) {
        key[i] = static_cast<std::uint8_t>(i + 1);
    }
    for (std::size_t i = 0; i < kAesNonceLen; ++i) {
        nonce[i] = static_cast<std::uint8_t>(0xA0 + i);
    }
    const char pt[] = "hello vault";
    std::vector<std::uint8_t> ct;
    ASSERT_TRUE(Aes256GcmEncrypt(key, nonce, "aad-v1",
                                 reinterpret_cast<const std::uint8_t *>(pt), sizeof(pt) - 1, &ct));
    EXPECT_EQ(ct.size(), (sizeof(pt) - 1) + kAesTagLen);

    std::vector<std::uint8_t> back;
    ASSERT_TRUE(Aes256GcmDecrypt(key, nonce, "aad-v1", ct.data(), ct.size(), &back));
    ASSERT_EQ(back.size(), sizeof(pt) - 1);
    EXPECT_EQ(std::memcmp(back.data(), pt, back.size()), 0);

    std::vector<std::uint8_t> wrong_aad;
    EXPECT_FALSE(Aes256GcmDecrypt(key, nonce, "aad-v2", ct.data(), ct.size(), &wrong_aad));

    ct[0] ^= 0x01;
    std::vector<std::uint8_t> tampered;
    EXPECT_FALSE(Aes256GcmDecrypt(key, nonce, "aad-v1", ct.data(), ct.size(), &tampered));
    SecureClear(key, sizeof(key));
}

TEST(VaultTest, RecoveryKeyTenThousandRoundTripsAndTamperRejected)
{
    std::uint8_t raw[kArgon2HashLen];
    std::uint8_t decoded[kArgon2HashLen];
    for (int i = 0; i < 10000; ++i) {
        for (std::size_t j = 0; j < kArgon2HashLen; ++j) {
            raw[j] = static_cast<std::uint8_t>((i * 17 + static_cast<int>(j) * 13) & 0xFF);
        }
        const std::string enc = EncodeRecoveryKey(raw);
        ASSERT_FALSE(enc.empty()) << i;
        ASSERT_TRUE(DecodeRecoveryKey(enc, decoded)) << enc;
        EXPECT_EQ(std::memcmp(decoded, raw, kArgon2HashLen), 0);

        std::string flipped = enc;
        flipped[flipped.size() - 1] = flipped.back() == 'A' ? 'B' : 'A';
        EXPECT_FALSE(DecodeRecoveryKey(flipped, decoded));
    }
    SecureClear(raw, sizeof(raw));
    SecureClear(decoded, sizeof(decoded));
}

TEST(VaultTest, RecoveryKeyRejectsBadShape)
{
    std::uint8_t raw[kArgon2HashLen];
    EXPECT_FALSE(DecodeRecoveryKey("", raw));
    EXPECT_FALSE(DecodeRecoveryKey("SPM1-abc", raw));
    EXPECT_FALSE(DecodeRecoveryKey("XXX-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA-0123456789AB",
                                   raw));
}

static bool FillGoldenOutputs(std::string *vault_key_hex, std::string *ct_hex, std::string *hash,
                              std::string *recovery, std::string *kek_hex)
{
    std::uint8_t vault_key[kArgon2HashLen];
    if (!Argon2idHash(sshclient::crypto::golden::kPassword, sshclient::crypto::golden::kSalt,
                      sizeof(sshclient::crypto::golden::kSalt), vault_key)) {
        return false;
    }
    *vault_key_hex = HexLower(vault_key, kArgon2HashLen);

    const std::string aad =
        SyncDocumentAad(sshclient::crypto::golden::kVaultId, sshclient::crypto::golden::kSchemaVersion,
                        sshclient::crypto::golden::kKeyVersion);
    const auto *pt = reinterpret_cast<const std::uint8_t *>(sshclient::crypto::golden::kPlaintext);
    const std::size_t pt_len = std::strlen(sshclient::crypto::golden::kPlaintext);
    std::vector<std::uint8_t> ct;
    if (!Aes256GcmEncrypt(vault_key, sshclient::crypto::golden::kNonce, aad, pt, pt_len, &ct)) {
        SecureClear(vault_key, sizeof(vault_key));
        return false;
    }
    *ct_hex = HexLower(ct.data(), ct.size());
    *hash = CiphertextHashHex(ct.data(), ct.size());

    *recovery = EncodeRecoveryKey(sshclient::crypto::golden::kRecoveryRaw);
    std::uint8_t kek[kHkdfOutLen];
    if (!DeriveRecoveryKek(sshclient::crypto::golden::kRecoveryRaw, kek)) {
        SecureClear(vault_key, sizeof(vault_key));
        return false;
    }
    *kek_hex = HexLower(kek, kHkdfOutLen);

    SecureClear(vault_key, sizeof(vault_key));
    SecureClear(kek, sizeof(kek));
    return hash->size() == kCiphertextHashHexLen;
}

TEST(VaultGolden, GenerateOrAssertRegistered)
{
    std::string vault_key_hex;
    std::string ct_hex;
    std::string hash;
    std::string recovery;
    std::string kek_hex;
    ASSERT_TRUE(FillGoldenOutputs(&vault_key_hex, &ct_hex, &hash, &recovery, &kek_hex));

    if (std::getenv("SSH_GENERATE_GOLDEN") != nullptr) {
        std::printf("kVaultKeyHex[] = \"%s\";\n", vault_key_hex.c_str());
        std::printf("kCiphertextHex[] = \"%s\";\n", ct_hex.c_str());
        std::printf("kCiphertextHash[] = \"%s\";\n", hash.c_str());
        std::printf("kRecoveryKey[] = \"%s\";\n", recovery.c_str());
        std::printf("kRecoveryKekHex[] = \"%s\";\n", kek_hex.c_str());
        return;
    }

    ASSERT_GT(std::strlen(sshclient::crypto::golden::kCiphertextHash), 0U)
        << "黄金向量尚未登记。在 WSL 里：SSH_GENERATE_GOLDEN=1 跑本用例，把打印值写入 "
           "vault_golden_vectors.h（此后永不改）。";
    EXPECT_EQ(vault_key_hex, sshclient::crypto::golden::kVaultKeyHex);
    EXPECT_EQ(ct_hex, sshclient::crypto::golden::kCiphertextHex);
    EXPECT_EQ(hash, sshclient::crypto::golden::kCiphertextHash);
    EXPECT_EQ(recovery, sshclient::crypto::golden::kRecoveryKey);
    EXPECT_EQ(kek_hex, sshclient::crypto::golden::kRecoveryKekHex);

    std::uint8_t key[kArgon2HashLen];
    std::vector<std::uint8_t> key_vec;
    ASSERT_TRUE(HexDecode(vault_key_hex, &key_vec));
    ASSERT_EQ(key_vec.size(), kArgon2HashLen);
    std::memcpy(key, key_vec.data(), kArgon2HashLen);
    std::vector<std::uint8_t> ct;
    ASSERT_TRUE(HexDecode(ct_hex, &ct));
    const std::string aad =
        SyncDocumentAad(sshclient::crypto::golden::kVaultId, sshclient::crypto::golden::kSchemaVersion,
                        sshclient::crypto::golden::kKeyVersion);
    std::vector<std::uint8_t> pt;
    ASSERT_TRUE(Aes256GcmDecrypt(key, sshclient::crypto::golden::kNonce, aad, ct.data(), ct.size(),
                                 &pt));
    EXPECT_EQ(std::string(pt.begin(), pt.end()), sshclient::crypto::golden::kPlaintext);
    SecureClear(key, sizeof(key));
}

TEST(VaultTest, HkdfDeterministicEmptySalt)
{
    std::uint8_t ikm[32];
    for (int i = 0; i < 32; ++i) {
        ikm[i] = static_cast<std::uint8_t>(i);
    }
    std::uint8_t a[32];
    std::uint8_t b[32];
    ASSERT_TRUE(HkdfSha256(ikm, 32, nullptr, 0, sshclient::crypto::kHkdfInfoRecoveryKek, a, 32));
    ASSERT_TRUE(HkdfSha256(ikm, 32, nullptr, 0, sshclient::crypto::kHkdfInfoRecoveryKek, b, 32));
    EXPECT_EQ(std::memcmp(a, b, 32), 0);
    std::uint8_t other[32];
    ASSERT_TRUE(HkdfSha256(ikm, 32, nullptr, 0, "other-info", other, 32));
    EXPECT_NE(std::memcmp(a, other, 32), 0);
}
