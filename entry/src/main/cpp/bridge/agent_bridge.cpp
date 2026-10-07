/**
 * NAPI 应用内 Agent 桥接实现 —— 任务 N9。
 *
 * 进程级单例 SshAgent：多会话共用同一托管库（「解锁一次后第二个会话免密」）。
 * 不做全局 C++ 单例宏，用函数内 static（C++11 线程安全初始化）。
 */

#include "agent_bridge.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"
#include "hilog/log.h"

#include <string>

#include "../ssh/agent.h"
#include "../ssh/auth.h"   // secureZero
#include "../ssh/keygen.h" // U3 ed25519 keygen
#include "../ssh/session.h"
#include "internal.h"

namespace sshclient {
namespace bridge {

namespace {

ssh::SshAgent &SharedAgent()
{
    static ssh::SshAgent agent;
    return agent;
}

napi_value AgentUnlock(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string keyId, privateKey, passphrase;
    if (argc < 3 || !GetStringArg(env, argv[0], keyId) ||
        !GetBytesArg(env, argv[1], privateKey) || !GetStringArg(env, argv[2], passphrase)) {
        ssh::secureZero(privateKey);
        ssh::secureZero(passphrase);
        return MakeBool(env, false);
    }
    const bool ok = SharedAgent().unlock(keyId, privateKey, passphrase);
    if (!ok) {
        ssh::secureZero(privateKey);
        ssh::secureZero(passphrase);
    }
    return MakeBool(env, ok);
}

napi_value AgentLock(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string keyId;
    if (argc < 1 || !GetStringArg(env, argv[0], keyId)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, SharedAgent().lock(keyId));
}

napi_value AgentLockAll(napi_env env, napi_callback_info /*info*/)
{
    SharedAgent().lockAll();
    return MakeBool(env, true);
}

napi_value AgentIsLocked(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string keyId;
    if (argc < 1 || !GetStringArg(env, argv[0], keyId)) {
        return MakeBool(env, true);
    }
    return MakeBool(env, SharedAgent().isLocked(keyId));
}

napi_value AgentKeyCount(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    const double count = static_cast<double>(SharedAgent().keyCount());
    if (napi_create_double(env, count, &result) != napi_ok) {
        napi_create_int32(env, 0, &result);
    }
    return result;
}

napi_value AgentSetTimeout(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint32_t minutes = 0;
    if (argc < 1 || !GetUint32Arg(env, argv[0], minutes)) {
        return MakeBool(env, false);
    }
    SharedAgent().setTimeout(minutes);
    return MakeBool(env, true);
}

napi_value AgentTimeoutMinutes(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    const double minutes = static_cast<double>(SharedAgent().timeoutMinutes());
    if (napi_create_double(env, minutes, &result) != napi_ok) {
        napi_create_int32(env, 0, &result);
    }
    return result;
}

napi_value AuthenticateAgent(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t h = 0;
    std::string keyId;
    if (argc < 2 || !GetHandleArg(env, argv[0], h) || !GetStringArg(env, argv[1], keyId)) {
        return MakeBool(env, false);
    }
    auto sh = LookupLive(h);
    if (!sh || !sh->session) {
        return MakeBool(env, false);
    }
    // 受理语义见 session.h：agent 未解锁/无 keyId 时返回 false，不消耗认证重试
    const bool ok =
        sh->session->authenticateAgent(keyId, SharedAgent(), MakeAuthCallback(sh.get(), "agent"));
    return MakeBool(env, ok);
}

/**
 * U3：生成 ed25519 密钥对（OpenSSL EVP）。
 * 返回对象 { keyType, privateKeyPem, publicKeyLine, comment }；失败返回 null。
 * 私钥为 PKCS#8 PEM（见 cpp/ssh/keygen.h 头注），公钥为 OpenSSH 单行。
 * 短语仅用于 PEM 加密，桥接层不落盘、不记日志。
 */
napi_value AgentKeygen(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string comment;
    std::string passphrase;
    if (argc < 1 || !GetStringArg(env, argv[0], comment)) {
        return nullptr;
    }
    if (argc >= 2 && !GetStringArg(env, argv[1], passphrase)) {
        return nullptr;
    }
    ssh::GeneratedKeyPair pair;
    const bool ok = ssh::generateEd25519KeyPair(comment, passphrase, &pair);
    ssh::secureZero(passphrase);
    if (!ok) {
        return nullptr;
    }
    napi_value obj = nullptr;
    if (napi_create_object(env, &obj) != napi_ok) {
        ssh::secureZero(pair.privateKeyPem);
        return nullptr;
    }
    SetStrProp(env, obj, "keyType", pair.keyType);
    SetStrProp(env, obj, "privateKeyPem", pair.privateKeyPem);
    SetStrProp(env, obj, "publicKeyLine", pair.publicKeyLine);
    SetStrProp(env, obj, "comment", pair.comment);
    ssh::secureZero(pair.privateKeyPem);
    return obj;
}

} // namespace

void RegisterAgentBridge(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"agentUnlock", nullptr, AgentUnlock, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentLock", nullptr, AgentLock, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentLockAll", nullptr, AgentLockAll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentIsLocked", nullptr, AgentIsLocked, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentKeyCount", nullptr, AgentKeyCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentSetTimeout", nullptr, AgentSetTimeout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"agentTimeoutMinutes", nullptr, AgentTimeoutMinutes, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"authenticateAgent", nullptr, AuthenticateAgent, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"agentKeygen", nullptr, AgentKeygen, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "RegisterAgentBridge: napi_define_properties failed");
    }
}

} // namespace bridge
} // namespace sshclient
