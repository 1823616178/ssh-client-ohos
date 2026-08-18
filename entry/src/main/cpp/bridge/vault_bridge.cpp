/**
 * 保险库 NAPI：create / unlock / encrypt / decrypt / rewrap / close。
 * 口令用完 OPENSSL_cleanse。不写 hilog 口令、恢复密钥、密文。
 */
#include "vault_bridge.h"

#include "crypto/vault.hpp"

#include "hilog/log.h"

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"

namespace sshclient {
namespace bridge {
namespace {

struct VaultSession {
    std::uint8_t key[sshclient::crypto::kArgon2HashLen]{};
    int keyVersion = 1;
};

std::mutex g_mu;
std::unordered_map<std::uint64_t, VaultSession> g_sessions;
std::uint64_t g_next = 1;

std::uint64_t PutSession(const std::uint8_t key[sshclient::crypto::kArgon2HashLen], int key_version)
{
    std::lock_guard<std::mutex> lock(g_mu);
    const std::uint64_t id = g_next++;
    VaultSession s;
    std::copy(key, key + sshclient::crypto::kArgon2HashLen, s.key);
    s.keyVersion = key_version;
    g_sessions.emplace(id, s);
    return id;
}

bool GetSession(std::uint64_t id, VaultSession *out)
{
    std::lock_guard<std::mutex> lock(g_mu);
    const auto it = g_sessions.find(id);
    if (it == g_sessions.end() || out == nullptr) {
        return false;
    }
    *out = it->second;
    return true;
}

bool TakeSession(std::uint64_t id)
{
    std::lock_guard<std::mutex> lock(g_mu);
    const auto it = g_sessions.find(id);
    if (it == g_sessions.end()) {
        return false;
    }
    sshclient::crypto::SecureClear(it->second.key, sizeof(it->second.key));
    g_sessions.erase(it);
    return true;
}

napi_value MakeNull(napi_env env)
{
    napi_value v = nullptr;
    napi_get_null(env, &v);
    return v;
}

napi_value MakeBool(napi_env env, bool value)
{
    napi_value v = nullptr;
    napi_get_boolean(env, value, &v);
    return v;
}

napi_value MakeNumber(napi_env env, double value)
{
    napi_value v = nullptr;
    napi_create_double(env, value, &v);
    return v;
}

napi_value MakeString(napi_env env, const std::string &s)
{
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

bool ReadString(napi_env env, napi_value value, std::string *out)
{
    if (out == nullptr) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out->assign(len, '\0');
    if (len == 0) {
        return true;
    }
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, out->data(), len + 1, &copied) != napi_ok) {
        out->clear();
        return false;
    }
    return true;
}

bool ReadInt(napi_env env, napi_value value, int *out)
{
    int32_t n = 0;
    if (napi_get_value_int32(env, value, &n) != napi_ok) {
        return false;
    }
    *out = static_cast<int>(n);
    return true;
}

bool ReadHandle(napi_env env, napi_value value, std::uint64_t *out)
{
    double d = 0;
    if (napi_get_value_double(env, value, &d) != napi_ok || d <= 0) {
        return false;
    }
    *out = static_cast<std::uint64_t>(d);
    return true;
}

void SetNamed(napi_env env, napi_value obj, const char *name, napi_value value)
{
    napi_set_named_property(env, obj, name, value);
}

napi_value WrapToObject(napi_env env, const sshclient::crypto::VaultWrap &wrap,
                        std::uint64_t handle, const std::string *recovery)
{
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetNamed(env, obj, "handle", MakeNumber(env, static_cast<double>(handle)));
    SetNamed(env, obj, "keyVersion", MakeNumber(env, wrap.keyVersion));
    SetNamed(env, obj, "passwordWrappedKey", MakeString(env, wrap.passwordWrappedKey));
    SetNamed(env, obj, "passwordWrapNonce", MakeString(env, wrap.passwordWrapNonce));
    SetNamed(env, obj, "recoveryWrappedKey", MakeString(env, wrap.recoveryWrappedKey));
    SetNamed(env, obj, "recoveryWrapNonce", MakeString(env, wrap.recoveryWrapNonce));
    SetNamed(env, obj, "kdfSalt", MakeString(env, wrap.kdfSalt));
    if (recovery != nullptr) {
        SetNamed(env, obj, "recoveryKey", MakeString(env, *recovery));
    }
    return obj;
}

sshclient::crypto::VaultWrap WrapFromArgs(int key_version, const std::string &salt,
                                          const std::string &pw_ct, const std::string &pw_nonce,
                                          const std::string &rec_ct, const std::string &rec_nonce)
{
    sshclient::crypto::VaultWrap wrap;
    wrap.keyVersion = key_version;
    wrap.kdfSalt = salt;
    wrap.passwordWrappedKey = pw_ct;
    wrap.passwordWrapNonce = pw_nonce;
    wrap.recoveryWrappedKey = rec_ct;
    wrap.recoveryWrapNonce = rec_nonce;
    return wrap;
}

napi_value VaultCreate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        return MakeNull(env);
    }
    std::string password;
    int key_version = 1;
    if (!ReadString(env, argv[0], &password) || !ReadInt(env, argv[1], &key_version)) {
        sshclient::crypto::SecureClear(password.data(), password.size());
        return MakeNull(env);
    }
    sshclient::crypto::VaultWrap wrap;
    std::string recovery;
    std::uint8_t key[sshclient::crypto::kArgon2HashLen];
    const bool ok = sshclient::crypto::CreateVault(password, key_version, &wrap, &recovery, key);
    sshclient::crypto::SecureClear(password.data(), password.size());
    password.clear();
    if (!ok) {
        return MakeNull(env);
    }
    const std::uint64_t handle = PutSession(key, key_version);
    sshclient::crypto::SecureClear(key, sizeof(key));
    return WrapToObject(env, wrap, handle, &recovery);
}

napi_value VaultUnlockPassword(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        return MakeNumber(env, 0);
    }
    std::string password;
    int key_version = 1;
    std::string salt;
    std::string pw_ct;
    std::string pw_nonce;
    if (!ReadString(env, argv[0], &password) || !ReadInt(env, argv[1], &key_version) ||
        !ReadString(env, argv[2], &salt) || !ReadString(env, argv[3], &pw_ct) ||
        !ReadString(env, argv[4], &pw_nonce)) {
        sshclient::crypto::SecureClear(password.data(), password.size());
        return MakeNumber(env, 0);
    }
    const sshclient::crypto::VaultWrap wrap =
        WrapFromArgs(key_version, salt, pw_ct, pw_nonce, "", "");
    std::uint8_t key[sshclient::crypto::kArgon2HashLen];
    const bool ok = sshclient::crypto::UnlockWithPassword(password, wrap, key);
    sshclient::crypto::SecureClear(password.data(), password.size());
    password.clear();
    if (!ok) {
        return MakeNumber(env, 0);
    }
    const std::uint64_t handle = PutSession(key, key_version);
    sshclient::crypto::SecureClear(key, sizeof(key));
    return MakeNumber(env, static_cast<double>(handle));
}

napi_value VaultUnlockRecovery(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 4) {
        return MakeNumber(env, 0);
    }
    std::string recovery;
    int key_version = 1;
    std::string rec_ct;
    std::string rec_nonce;
    if (!ReadString(env, argv[0], &recovery) || !ReadInt(env, argv[1], &key_version) ||
        !ReadString(env, argv[2], &rec_ct) || !ReadString(env, argv[3], &rec_nonce)) {
        sshclient::crypto::SecureClear(recovery.data(), recovery.size());
        return MakeNumber(env, 0);
    }
    const sshclient::crypto::VaultWrap wrap =
        WrapFromArgs(key_version, "", "", "", rec_ct, rec_nonce);
    std::uint8_t key[sshclient::crypto::kArgon2HashLen];
    const bool ok = sshclient::crypto::UnlockWithRecovery(recovery, wrap, key);
    sshclient::crypto::SecureClear(recovery.data(), recovery.size());
    recovery.clear();
    if (!ok) {
        return MakeNumber(env, 0);
    }
    const std::uint64_t handle = PutSession(key, key_version);
    sshclient::crypto::SecureClear(key, sizeof(key));
    return MakeNumber(env, static_cast<double>(handle));
}

napi_value VaultEncrypt(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        return MakeNull(env);
    }
    std::uint64_t handle = 0;
    std::string vault_id;
    int schema = 1;
    int key_version = 1;
    std::string plain;
    if (!ReadHandle(env, argv[0], &handle) || !ReadString(env, argv[1], &vault_id) ||
        !ReadInt(env, argv[2], &schema) || !ReadInt(env, argv[3], &key_version) ||
        !ReadString(env, argv[4], &plain)) {
        return MakeNull(env);
    }
    VaultSession session;
    if (!GetSession(handle, &session)) {
        return MakeNull(env);
    }
    sshclient::crypto::DocumentSeal seal;
    const bool ok = sshclient::crypto::EncryptDocument(session.key, vault_id, schema, key_version,
                                                       plain, &seal);
    sshclient::crypto::SecureClear(plain.data(), plain.size());
    if (!ok) {
        return MakeNull(env);
    }
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetNamed(env, obj, "schemaVersion", MakeNumber(env, seal.schemaVersion));
    SetNamed(env, obj, "keyVersion", MakeNumber(env, seal.keyVersion));
    SetNamed(env, obj, "algorithm", MakeString(env, seal.algorithm));
    SetNamed(env, obj, "nonce", MakeString(env, seal.nonce));
    SetNamed(env, obj, "ciphertext", MakeString(env, seal.ciphertext));
    SetNamed(env, obj, "ciphertextHash", MakeString(env, seal.ciphertextHash));
    return obj;
}

napi_value VaultDecrypt(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value argv[6] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 6) {
        return MakeNull(env);
    }
    std::uint64_t handle = 0;
    std::string vault_id;
    int schema = 1;
    int key_version = 1;
    std::string nonce;
    std::string ciphertext;
    if (!ReadHandle(env, argv[0], &handle) || !ReadString(env, argv[1], &vault_id) ||
        !ReadInt(env, argv[2], &schema) || !ReadInt(env, argv[3], &key_version) ||
        !ReadString(env, argv[4], &nonce) || !ReadString(env, argv[5], &ciphertext)) {
        return MakeNull(env);
    }
    VaultSession session;
    if (!GetSession(handle, &session)) {
        return MakeNull(env);
    }
    sshclient::crypto::DocumentSeal seal;
    seal.schemaVersion = schema;
    seal.keyVersion = key_version;
    seal.nonce = nonce;
    seal.ciphertext = ciphertext;
    std::string plain;
    if (!sshclient::crypto::DecryptDocument(session.key, vault_id, schema, key_version, seal,
                                            &plain)) {
        return MakeNull(env);
    }
    napi_value out = MakeString(env, plain);
    sshclient::crypto::SecureClear(plain.data(), plain.size());
    return out;
}

napi_value VaultRewrap(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 3) {
        return MakeNull(env);
    }
    std::uint64_t handle = 0;
    std::string password;
    int key_version = 1;
    if (!ReadHandle(env, argv[0], &handle) || !ReadString(env, argv[1], &password) ||
        !ReadInt(env, argv[2], &key_version)) {
        sshclient::crypto::SecureClear(password.data(), password.size());
        return MakeNull(env);
    }
    VaultSession session;
    if (!GetSession(handle, &session)) {
        sshclient::crypto::SecureClear(password.data(), password.size());
        return MakeNull(env);
    }
    sshclient::crypto::VaultWrap wrap;
    std::string recovery;
    const bool ok =
        sshclient::crypto::RewrapVault(session.key, password, key_version, &wrap, &recovery);
    sshclient::crypto::SecureClear(password.data(), password.size());
    if (!ok) {
        return MakeNull(env);
    }
    return WrapToObject(env, wrap, handle, &recovery);
}

napi_value VaultRotate(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        return MakeNull(env);
    }
    std::uint64_t old_handle = 0;
    std::string password;
    if (!ReadHandle(env, argv[0], &old_handle) || !ReadString(env, argv[1], &password)) {
        sshclient::crypto::SecureClear(password.data(), password.size());
        return MakeNull(env);
    }
    VaultSession old_session;
    if (!GetSession(old_handle, &old_session)) {
        sshclient::crypto::SecureClear(password.data(), password.size());
        return MakeNull(env);
    }
    const int new_ver = old_session.keyVersion + 1;
    sshclient::crypto::VaultWrap wrap;
    std::string recovery;
    std::uint8_t new_key[sshclient::crypto::kArgon2HashLen];
    const bool ok = sshclient::crypto::CreateVault(password, new_ver, &wrap, &recovery, new_key);
    sshclient::crypto::SecureClear(password.data(), password.size());
    if (!ok) {
        return MakeNull(env);
    }
    TakeSession(old_handle);
    const std::uint64_t handle = PutSession(new_key, new_ver);
    sshclient::crypto::SecureClear(new_key, sizeof(new_key));
    return WrapToObject(env, wrap, handle, &recovery);
}

napi_value VaultClose(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return MakeBool(env, false);
    }
    std::uint64_t handle = 0;
    if (!ReadHandle(env, argv[0], &handle)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, TakeSession(handle));
}

} // namespace

void RegisterVaultBridge(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"vaultCreate", nullptr, VaultCreate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vaultUnlockPassword", nullptr, VaultUnlockPassword, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"vaultUnlockRecovery", nullptr, VaultUnlockRecovery, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"vaultEncrypt", nullptr, VaultEncrypt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vaultDecrypt", nullptr, VaultDecrypt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vaultRewrap", nullptr, VaultRewrap, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vaultRotate", nullptr, VaultRotate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"vaultClose", nullptr, VaultClose, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterVaultBridge: napi_define_properties failed");
    }
}

} // namespace bridge
} // namespace sshclient
