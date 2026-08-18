/**
 * 保险库高层操作（Create/Unlock/Encrypt/Decrypt/Rewrap）。
 */
#include <gtest/gtest.h>

#include "crypto/vault.hpp"

#include <cstring>
#include <string>
#include <vector>

using sshclient::crypto::Base64StdDecode;
using sshclient::crypto::Base64StdEncode;
using sshclient::crypto::CreateVault;
using sshclient::crypto::DecryptDocument;
using sshclient::crypto::DocumentSeal;
using sshclient::crypto::EncryptDocument;
using sshclient::crypto::RewrapVault;
using sshclient::crypto::SecureClear;
using sshclient::crypto::UnlockWithPassword;
using sshclient::crypto::UnlockWithRecovery;
using sshclient::crypto::VaultWrap;
using sshclient::crypto::kArgon2HashLen;

TEST(VaultOpsTest, Base64StdRoundTrip)
{
    const std::uint8_t raw[] = {0x00, 0x01, 0xFE, 0xFF, 0x10};
    const std::string b64 = Base64StdEncode(raw, sizeof(raw));
    EXPECT_FALSE(b64.empty());
    std::vector<std::uint8_t> back;
    ASSERT_TRUE(Base64StdDecode(b64, &back));
    ASSERT_EQ(back.size(), sizeof(raw));
    EXPECT_EQ(std::memcmp(back.data(), raw, sizeof(raw)), 0);
}

TEST(VaultOpsTest, CreateUnlockEncryptDecrypt)
{
    VaultWrap wrap;
    std::string recovery;
    std::uint8_t key[kArgon2HashLen];
    ASSERT_TRUE(CreateVault("password12ab", 1, &wrap, &recovery, key));
    EXPECT_EQ(wrap.keyVersion, 1);
    EXPECT_FALSE(wrap.kdfSalt.empty());
    EXPECT_EQ(recovery.substr(0, 5), "SPM1-");

    std::uint8_t unlocked[kArgon2HashLen];
    ASSERT_TRUE(UnlockWithPassword("password12ab", wrap, unlocked));
    EXPECT_EQ(std::memcmp(key, unlocked, kArgon2HashLen), 0);

    std::uint8_t bad[kArgon2HashLen];
    EXPECT_FALSE(UnlockWithPassword("wrong-password", wrap, bad));

    std::uint8_t via_rec[kArgon2HashLen];
    ASSERT_TRUE(UnlockWithRecovery(recovery, wrap, via_rec));
    EXPECT_EQ(std::memcmp(key, via_rec, kArgon2HashLen), 0);

    DocumentSeal seal;
    ASSERT_TRUE(EncryptDocument(key, "vault-id-1", 1, 1, "{\"schemaVersion\":1}", &seal));
    EXPECT_EQ(seal.algorithm, "AES-256-GCM");
    EXPECT_EQ(seal.ciphertextHash.size(), 64U);

    std::string plain;
    ASSERT_TRUE(DecryptDocument(key, "vault-id-1", 1, 1, seal, &plain));
    EXPECT_EQ(plain, "{\"schemaVersion\":1}");

    std::string wrong_id;
    EXPECT_FALSE(DecryptDocument(key, "other-vault", 1, 1, seal, &wrong_id));

    VaultWrap wrap2;
    std::string recovery2;
    ASSERT_TRUE(RewrapVault(key, "new-password1", 1, &wrap2, &recovery2));
    std::uint8_t unlocked2[kArgon2HashLen];
    ASSERT_TRUE(UnlockWithPassword("new-password1", wrap2, unlocked2));
    EXPECT_EQ(std::memcmp(key, unlocked2, kArgon2HashLen), 0);
    EXPECT_FALSE(UnlockWithPassword("password12ab", wrap2, bad));
    EXPECT_NE(recovery2, recovery);

    SecureClear(key, sizeof(key));
    SecureClear(unlocked, sizeof(unlocked));
    SecureClear(via_rec, sizeof(via_rec));
    SecureClear(unlocked2, sizeof(unlocked2));
}
