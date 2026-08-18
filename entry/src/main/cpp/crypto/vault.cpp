#include "vault.hpp"

#include "openssl/crypto.h"
#include "openssl/evp.h"
#include "openssl/kdf.h"
#include "openssl/params.h"
#include "openssl/rand.h"
#include "openssl/sha.h"
#include "aad.hpp"
#include "argon2.h"

#include <algorithm>
#include <array>
#include <vector>

namespace sshclient {
namespace crypto {
namespace {

constexpr char kB64Url[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

int B64UrlIndex(char c)
{
    if (c >= 'A' && c <= 'Z') {
        return c - 'A';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 26;
    }
    if (c >= '0' && c <= '9') {
        return c - '0' + 52;
    }
    if (c == '-') {
        return 62;
    }
    if (c == '_') {
        return 63;
    }
    return -1;
}

std::string Base64UrlEncode(const std::uint8_t *data, std::size_t len)
{
    std::string out;
    out.reserve((len + 2) / 3 * 4);
    std::size_t i = 0;
    while (i + 3 <= len) {
        const std::uint32_t n = (static_cast<std::uint32_t>(data[i]) << 16) |
                                (static_cast<std::uint32_t>(data[i + 1]) << 8) |
                                static_cast<std::uint32_t>(data[i + 2]);
        out.push_back(kB64Url[(n >> 18) & 63]);
        out.push_back(kB64Url[(n >> 12) & 63]);
        out.push_back(kB64Url[(n >> 6) & 63]);
        out.push_back(kB64Url[n & 63]);
        i += 3;
    }
    if (i < len) {
        std::uint32_t n = static_cast<std::uint32_t>(data[i]) << 16;
        if (i + 1 < len) {
            n |= static_cast<std::uint32_t>(data[i + 1]) << 8;
        }
        out.push_back(kB64Url[(n >> 18) & 63]);
        out.push_back(kB64Url[(n >> 12) & 63]);
        if (i + 1 < len) {
            out.push_back(kB64Url[(n >> 6) & 63]);
        }
    }
    return out;
}

bool Base64UrlDecode(std::string_view in, std::uint8_t *out, std::size_t out_len)
{
    if (in.find('=') != std::string_view::npos) {
        return false;
    }
    std::vector<std::uint8_t> acc;
    acc.reserve(out_len);
    std::uint32_t buf = 0;
    int bits = 0;
    for (char c : in) {
        const int v = B64UrlIndex(c);
        if (v < 0) {
            return false;
        }
        buf = (buf << 6) | static_cast<std::uint32_t>(v);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            acc.push_back(static_cast<std::uint8_t>((buf >> bits) & 0xFF));
        }
    }
    if (acc.size() != out_len) {
        return false;
    }
    std::copy(acc.begin(), acc.end(), out);
    return true;
}

int HexVal(char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    return -1;
}

std::string HexEncode(const std::uint8_t *data, std::size_t len, bool upper)
{
    static const char kLo[] = "0123456789abcdef";
    static const char kHi[] = "0123456789ABCDEF";
    const char *tab = upper ? kHi : kLo;
    std::string out;
    out.resize(len * 2);
    for (std::size_t i = 0; i < len; ++i) {
        out[i * 2] = tab[data[i] >> 4];
        out[i * 2 + 1] = tab[data[i] & 0x0F];
    }
    return out;
}

} // namespace

void SecureClear(void *ptr, std::size_t len)
{
    if (ptr != nullptr && len > 0) {
        OPENSSL_cleanse(ptr, len);
    }
}

std::string HexLower(const std::uint8_t *data, std::size_t len)
{
    return HexEncode(data, len, false);
}

std::string HexUpper(const std::uint8_t *data, std::size_t len)
{
    return HexEncode(data, len, true);
}

bool HexDecode(std::string_view hex, std::vector<std::uint8_t> *out)
{
    if (out == nullptr || (hex.size() % 2) != 0) {
        return false;
    }
    out->assign(hex.size() / 2, 0);
    for (std::size_t i = 0; i < out->size(); ++i) {
        const int hi = HexVal(hex[i * 2]);
        const int lo = HexVal(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            out->clear();
            return false;
        }
        (*out)[i] = static_cast<std::uint8_t>((hi << 4) | lo);
    }
    return true;
}

bool Argon2idHash(std::string_view password, const std::uint8_t *salt, std::size_t salt_len,
                  std::uint8_t out[kArgon2HashLen])
{
    if (out == nullptr || salt == nullptr || salt_len == 0) {
        return false;
    }
    const int rc = argon2id_hash_raw(static_cast<std::uint32_t>(kArgon2Iterations),
                                     static_cast<std::uint32_t>(kArgon2MemoryKib),
                                     static_cast<std::uint32_t>(kArgon2Parallelism), password.data(),
                                     password.size(), salt, salt_len, out, kArgon2HashLen);
    return rc == ARGON2_OK;
}

bool HkdfSha256(const std::uint8_t *ikm, std::size_t ikm_len, const std::uint8_t *salt,
                std::size_t salt_len, std::string_view info, std::uint8_t *out, std::size_t out_len)
{
    if (ikm == nullptr || out == nullptr || out_len == 0) {
        return false;
    }
    EVP_KDF *kdf = EVP_KDF_fetch(nullptr, "HKDF", nullptr);
    if (kdf == nullptr) {
        return false;
    }
    EVP_KDF_CTX *ctx = EVP_KDF_CTX_new(kdf);
    EVP_KDF_free(kdf);
    if (ctx == nullptr) {
        return false;
    }
    char digest[] = "SHA256";
    std::string info_buf(info);
    OSSL_PARAM params[5];
    int n = 0;
    params[n++] = OSSL_PARAM_construct_utf8_string("digest", digest, 0);
    params[n++] = OSSL_PARAM_construct_octet_string("key", const_cast<std::uint8_t *>(ikm), ikm_len);
    if (!info_buf.empty()) {
        params[n++] = OSSL_PARAM_construct_octet_string("info", info_buf.data(), info_buf.size());
    }
    if (salt != nullptr && salt_len > 0) {
        params[n++] =
            OSSL_PARAM_construct_octet_string("salt", const_cast<std::uint8_t *>(salt), salt_len);
    }
    params[n] = OSSL_PARAM_construct_end();
    const int rc = EVP_KDF_derive(ctx, out, out_len, params);
    EVP_KDF_CTX_free(ctx);
    return rc == 1;
}

bool Aes256GcmEncrypt(const std::uint8_t key[kArgon2HashLen],
                      const std::uint8_t nonce[kAesNonceLen], std::string_view aad,
                      const std::uint8_t *plaintext, std::size_t plaintext_len,
                      std::vector<std::uint8_t> *out)
{
    if (key == nullptr || nonce == nullptr || out == nullptr) {
        return false;
    }
    if (plaintext_len > 0 && plaintext == nullptr) {
        return false;
    }
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) {
        return false;
    }
    bool ok = false;
    out->assign(plaintext_len + kAesTagLen, 0);
    int len = 0;
    int total = 0;
    do {
        if (EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) {
            break;
        }
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(kAesNonceLen),
                                nullptr) != 1) {
            break;
        }
        if (EVP_EncryptInit_ex(ctx, nullptr, nullptr, key, nonce) != 1) {
            break;
        }
        if (!aad.empty()) {
            if (EVP_EncryptUpdate(ctx, nullptr, &len,
                                  reinterpret_cast<const std::uint8_t *>(aad.data()),
                                  static_cast<int>(aad.size())) != 1) {
                break;
            }
        }
        if (plaintext_len > 0) {
            if (EVP_EncryptUpdate(ctx, out->data(), &len, plaintext,
                                  static_cast<int>(plaintext_len)) != 1) {
                break;
            }
            total = len;
        }
        if (EVP_EncryptFinal_ex(ctx, out->data() + total, &len) != 1) {
            break;
        }
        total += len;
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, static_cast<int>(kAesTagLen),
                                out->data() + total) != 1) {
            break;
        }
        if (static_cast<std::size_t>(total) != plaintext_len) {
            break;
        }
        ok = true;
    } while (false);
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) {
        out->clear();
    }
    return ok;
}

bool Aes256GcmDecrypt(const std::uint8_t key[kArgon2HashLen],
                      const std::uint8_t nonce[kAesNonceLen], std::string_view aad,
                      const std::uint8_t *ct_and_tag, std::size_t ct_and_tag_len,
                      std::vector<std::uint8_t> *plaintext)
{
    if (key == nullptr || nonce == nullptr || plaintext == nullptr || ct_and_tag == nullptr ||
        ct_and_tag_len < kAesTagLen) {
        return false;
    }
    const std::size_t ct_len = ct_and_tag_len - kAesTagLen;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx == nullptr) {
        return false;
    }
    bool ok = false;
    plaintext->assign(ct_len, 0);
    int len = 0;
    int total = 0;
    do {
        if (EVP_DecryptInit_ex(ctx, EVP_aes_256_gcm(), nullptr, nullptr, nullptr) != 1) {
            break;
        }
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, static_cast<int>(kAesNonceLen),
                                nullptr) != 1) {
            break;
        }
        if (EVP_DecryptInit_ex(ctx, nullptr, nullptr, key, nonce) != 1) {
            break;
        }
        if (!aad.empty()) {
            if (EVP_DecryptUpdate(ctx, nullptr, &len,
                                  reinterpret_cast<const std::uint8_t *>(aad.data()),
                                  static_cast<int>(aad.size())) != 1) {
                break;
            }
        }
        if (ct_len > 0) {
            if (EVP_DecryptUpdate(ctx, plaintext->data(), &len, ct_and_tag,
                                  static_cast<int>(ct_len)) != 1) {
                break;
            }
            total = len;
        }
        if (EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, static_cast<int>(kAesTagLen),
                                const_cast<std::uint8_t *>(ct_and_tag + ct_len)) != 1) {
            break;
        }
        if (EVP_DecryptFinal_ex(ctx, plaintext->data() + total, &len) != 1) {
            break;
        }
        ok = true;
    } while (false);
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) {
        if (!plaintext->empty()) {
            SecureClear(plaintext->data(), plaintext->size());
        }
        plaintext->clear();
    }
    return ok;
}

std::string CiphertextHashHex(const std::uint8_t *ct_and_tag, std::size_t len)
{
    if (ct_and_tag == nullptr || len == 0) {
        return {};
    }
    std::uint8_t digest[SHA256_DIGEST_LENGTH];
    SHA256(ct_and_tag, len, digest);
    std::string hex = HexLower(digest, SHA256_DIGEST_LENGTH);
    SecureClear(digest, sizeof(digest));
    return hex;
}

std::string EncodeRecoveryKey(const std::uint8_t raw[kArgon2HashLen])
{
    if (raw == nullptr) {
        return {};
    }
    const std::string b64 = Base64UrlEncode(raw, kArgon2HashLen);
    std::array<std::uint8_t, kRecoveryKeyPrefix.size() + kArgon2HashLen> material{};
    std::copy(kRecoveryKeyPrefix.begin(), kRecoveryKeyPrefix.end(), material.begin());
    std::copy(raw, raw + kArgon2HashLen, material.begin() + kRecoveryKeyPrefix.size());
    std::array<std::uint8_t, SHA256_DIGEST_LENGTH> digest{};
    SHA256(material.data(), material.size(), digest.data());
    const std::string check = HexUpper(digest.data(), kRecoveryKeyCheckHexLen / 2);
    SecureClear(material.data(), material.size());
    SecureClear(digest.data(), digest.size());
    std::string out;
    out.reserve(kRecoveryKeyPrefix.size() + 1 + b64.size() + 1 + kRecoveryKeyCheckHexLen);
    out.append(kRecoveryKeyPrefix);
    out.push_back('-');
    out.append(b64);
    out.push_back('-');
    out.append(check);
    return out;
}

bool DecodeRecoveryKey(std::string_view encoded, std::uint8_t raw[kArgon2HashLen])
{
    if (raw == nullptr) {
        return false;
    }
    const std::size_t first = encoded.find('-');
    const std::size_t last = encoded.rfind('-');
    if (first == std::string_view::npos || last == first || last + 1 >= encoded.size()) {
        return false;
    }
    const std::string_view prefix = encoded.substr(0, first);
    const std::string_view b64 = encoded.substr(first + 1, last - first - 1);
    const std::string_view check = encoded.substr(last + 1);
    if (prefix != kRecoveryKeyPrefix || b64.size() != kRecoveryKeyRawB64urlLen ||
        check.size() != kRecoveryKeyCheckHexLen) {
        return false;
    }
    std::uint8_t decoded[kArgon2HashLen];
    if (!Base64UrlDecode(b64, decoded, kArgon2HashLen)) {
        return false;
    }
    const std::string expect = EncodeRecoveryKey(decoded);
    const bool match = expect == std::string(encoded);
    if (match) {
        std::copy(decoded, decoded + kArgon2HashLen, raw);
    }
    SecureClear(decoded, sizeof(decoded));
    return match;
}

bool DeriveRecoveryKek(const std::uint8_t raw[kArgon2HashLen], std::uint8_t kek[kHkdfOutLen])
{
    if (raw == nullptr || kek == nullptr) {
        return false;
    }
    return HkdfSha256(raw, kArgon2HashLen, nullptr, 0, kHkdfInfoRecoveryKek, kek, kHkdfOutLen);
}

std::string Base64StdEncode(const std::uint8_t *data, std::size_t len)
{
    if (data == nullptr && len > 0) {
        return {};
    }
    std::string out;
    out.resize(((len + 2) / 3) * 4);
    const int n = EVP_EncodeBlock(reinterpret_cast<unsigned char *>(out.data()), data,
                                  static_cast<int>(len));
    if (n < 0) {
        return {};
    }
    out.resize(static_cast<std::size_t>(n));
    return out;
}

bool Base64StdDecode(std::string_view in, std::vector<std::uint8_t> *out)
{
    if (out == nullptr) {
        return false;
    }
    if (in.empty()) {
        out->clear();
        return true;
    }
    std::string padded(in);
    while (padded.size() % 4 != 0) {
        padded.push_back('=');
    }
    std::vector<unsigned char> buf(padded.size());
    const int n = EVP_DecodeBlock(buf.data(), reinterpret_cast<const unsigned char *>(padded.data()),
                                  static_cast<int>(padded.size()));
    if (n < 0) {
        out->clear();
        return false;
    }
    std::size_t pad = 0;
    if (!padded.empty() && padded[padded.size() - 1] == '=') {
        pad++;
    }
    if (padded.size() > 1 && padded[padded.size() - 2] == '=') {
        pad++;
    }
    const std::size_t real = static_cast<std::size_t>(n) - pad;
    out->assign(buf.begin(), buf.begin() + static_cast<std::ptrdiff_t>(real));
    return true;
}

bool RandomBytes(std::uint8_t *out, std::size_t len)
{
    if (out == nullptr || len == 0) {
        return false;
    }
    return RAND_bytes(out, static_cast<int>(len)) == 1;
}

namespace {

bool WrapKey(const std::uint8_t vault_key[kArgon2HashLen], const std::uint8_t kek[kArgon2HashLen],
             std::string_view aad, std::string *wrapped_b64, std::string *nonce_b64)
{
    std::uint8_t nonce[kAesNonceLen];
    if (!RandomBytes(nonce, kAesNonceLen)) {
        return false;
    }
    std::vector<std::uint8_t> ct;
    if (!Aes256GcmEncrypt(kek, nonce, aad, vault_key, kArgon2HashLen, &ct)) {
        SecureClear(nonce, sizeof(nonce));
        return false;
    }
    *wrapped_b64 = Base64StdEncode(ct.data(), ct.size());
    *nonce_b64 = Base64StdEncode(nonce, kAesNonceLen);
    SecureClear(nonce, sizeof(nonce));
    return !wrapped_b64->empty() && !nonce_b64->empty();
}

bool UnwrapKey(const std::uint8_t kek[kArgon2HashLen], std::string_view aad,
               std::string_view wrapped_b64, std::string_view nonce_b64,
               std::uint8_t vault_key[kArgon2HashLen])
{
    std::vector<std::uint8_t> ct;
    std::vector<std::uint8_t> nonce;
    if (!Base64StdDecode(wrapped_b64, &ct) || !Base64StdDecode(nonce_b64, &nonce)) {
        return false;
    }
    if (nonce.size() != kAesNonceLen) {
        return false;
    }
    std::vector<std::uint8_t> pt;
    if (!Aes256GcmDecrypt(kek, nonce.data(), aad, ct.data(), ct.size(), &pt)) {
        return false;
    }
    if (pt.size() != kArgon2HashLen) {
        SecureClear(pt.data(), pt.size());
        return false;
    }
    std::copy(pt.begin(), pt.end(), vault_key);
    SecureClear(pt.data(), pt.size());
    return true;
}

std::string KeyVerStr(int key_version)
{
    return std::to_string(key_version);
}

bool WrapBoth(const std::uint8_t vault_key[kArgon2HashLen], std::string_view password,
              int key_version, VaultWrap *wrap, std::string *recovery_key)
{
    std::uint8_t salt[kKdfSaltLen];
    std::uint8_t recovery_raw[kArgon2HashLen];
    std::uint8_t pw_kek[kArgon2HashLen];
    std::uint8_t rec_kek[kHkdfOutLen];
    bool ok = false;
    do {
        if (!RandomBytes(salt, kKdfSaltLen) || !RandomBytes(recovery_raw, kArgon2HashLen)) {
            break;
        }
        if (!Argon2idHash(password, salt, kKdfSaltLen, pw_kek)) {
            break;
        }
        if (!DeriveRecoveryKek(recovery_raw, rec_kek)) {
            break;
        }
        const std::string kv = KeyVerStr(key_version);
        const std::string pw_aad = VaultKeyPasswordAad(kv);
        const std::string rec_aad = VaultKeyRecoveryAad(kv);
        if (!WrapKey(vault_key, pw_kek, pw_aad, &wrap->passwordWrappedKey,
                     &wrap->passwordWrapNonce)) {
            break;
        }
        if (!WrapKey(vault_key, rec_kek, rec_aad, &wrap->recoveryWrappedKey,
                     &wrap->recoveryWrapNonce)) {
            break;
        }
        wrap->kdfSalt = Base64StdEncode(salt, kKdfSaltLen);
        wrap->keyVersion = key_version;
        *recovery_key = EncodeRecoveryKey(recovery_raw);
        ok = !wrap->kdfSalt.empty() && !recovery_key->empty();
    } while (false);
    SecureClear(salt, sizeof(salt));
    SecureClear(recovery_raw, sizeof(recovery_raw));
    SecureClear(pw_kek, sizeof(pw_kek));
    SecureClear(rec_kek, sizeof(rec_kek));
    return ok;
}

} // namespace

bool CreateVault(std::string_view password, int key_version, VaultWrap *wrap,
                 std::string *recovery_key, std::uint8_t vault_key[kArgon2HashLen])
{
    if (wrap == nullptr || recovery_key == nullptr || vault_key == nullptr || password.empty()) {
        return false;
    }
    if (!RandomBytes(vault_key, kArgon2HashLen)) {
        return false;
    }
    if (!WrapBoth(vault_key, password, key_version, wrap, recovery_key)) {
        SecureClear(vault_key, kArgon2HashLen);
        return false;
    }
    return true;
}

bool UnlockWithPassword(std::string_view password, const VaultWrap &wrap,
                        std::uint8_t vault_key[kArgon2HashLen])
{
    if (vault_key == nullptr || password.empty()) {
        return false;
    }
    std::vector<std::uint8_t> salt;
    if (!Base64StdDecode(wrap.kdfSalt, &salt) || salt.size() != kKdfSaltLen) {
        return false;
    }
    std::uint8_t pw_kek[kArgon2HashLen];
    if (!Argon2idHash(password, salt.data(), salt.size(), pw_kek)) {
        return false;
    }
    const std::string aad = VaultKeyPasswordAad(KeyVerStr(wrap.keyVersion));
    const bool ok =
        UnwrapKey(pw_kek, aad, wrap.passwordWrappedKey, wrap.passwordWrapNonce, vault_key);
    SecureClear(pw_kek, sizeof(pw_kek));
    return ok;
}

bool UnlockWithRecovery(std::string_view recovery_key, const VaultWrap &wrap,
                        std::uint8_t vault_key[kArgon2HashLen])
{
    if (vault_key == nullptr) {
        return false;
    }
    std::uint8_t raw[kArgon2HashLen];
    if (!DecodeRecoveryKey(recovery_key, raw)) {
        return false;
    }
    std::uint8_t rec_kek[kHkdfOutLen];
    if (!DeriveRecoveryKek(raw, rec_kek)) {
        SecureClear(raw, sizeof(raw));
        return false;
    }
    const std::string aad = VaultKeyRecoveryAad(KeyVerStr(wrap.keyVersion));
    const bool ok =
        UnwrapKey(rec_kek, aad, wrap.recoveryWrappedKey, wrap.recoveryWrapNonce, vault_key);
    SecureClear(raw, sizeof(raw));
    SecureClear(rec_kek, sizeof(rec_kek));
    return ok;
}

bool RewrapVault(const std::uint8_t vault_key[kArgon2HashLen], std::string_view new_password,
                 int key_version, VaultWrap *wrap, std::string *recovery_key)
{
    if (vault_key == nullptr || wrap == nullptr || recovery_key == nullptr || new_password.empty()) {
        return false;
    }
    return WrapBoth(vault_key, new_password, key_version, wrap, recovery_key);
}

bool EncryptDocument(const std::uint8_t vault_key[kArgon2HashLen], std::string_view vault_id,
                     int schema_version, int key_version, std::string_view plaintext,
                     DocumentSeal *out)
{
    if (vault_key == nullptr || out == nullptr) {
        return false;
    }
    std::uint8_t nonce[kAesNonceLen];
    if (!RandomBytes(nonce, kAesNonceLen)) {
        return false;
    }
    const std::string sv = std::to_string(schema_version);
    const std::string kv = KeyVerStr(key_version);
    const std::string aad = SyncDocumentAad(vault_id, sv, kv);
    std::vector<std::uint8_t> ct;
    if (!Aes256GcmEncrypt(vault_key, nonce, aad,
                          reinterpret_cast<const std::uint8_t *>(plaintext.data()),
                          plaintext.size(), &ct)) {
        SecureClear(nonce, sizeof(nonce));
        return false;
    }
    out->schemaVersion = schema_version;
    out->keyVersion = key_version;
    out->algorithm = std::string(kAesAlgorithm);
    out->nonce = Base64StdEncode(nonce, kAesNonceLen);
    out->ciphertext = Base64StdEncode(ct.data(), ct.size());
    out->ciphertextHash = CiphertextHashHex(ct.data(), ct.size());
    SecureClear(nonce, sizeof(nonce));
    return !out->nonce.empty() && !out->ciphertext.empty() &&
           out->ciphertextHash.size() == kCiphertextHashHexLen;
}

bool DecryptDocument(const std::uint8_t vault_key[kArgon2HashLen], std::string_view vault_id,
                     int schema_version, int key_version, const DocumentSeal &seal,
                     std::string *plaintext)
{
    if (vault_key == nullptr || plaintext == nullptr) {
        return false;
    }
    std::vector<std::uint8_t> nonce;
    std::vector<std::uint8_t> ct;
    if (!Base64StdDecode(seal.nonce, &nonce) || !Base64StdDecode(seal.ciphertext, &ct)) {
        return false;
    }
    if (nonce.size() != kAesNonceLen) {
        return false;
    }
    const std::string sv = std::to_string(schema_version);
    const std::string kv = KeyVerStr(key_version);
    const std::string aad = SyncDocumentAad(vault_id, sv, kv);
    std::vector<std::uint8_t> pt;
    if (!Aes256GcmDecrypt(vault_key, nonce.data(), aad, ct.data(), ct.size(), &pt)) {
        return false;
    }
    plaintext->assign(reinterpret_cast<const char *>(pt.data()), pt.size());
    SecureClear(pt.data(), pt.size());
    return true;
}

} // namespace crypto
} // namespace sshclient
