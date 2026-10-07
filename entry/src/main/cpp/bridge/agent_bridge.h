/**
 * NAPI 应用内 Agent 桥接 —— 任务 N9 的 ArkTS 出口。
 *
 * 进程内共享一个 SshAgent（内存密钥托管，语义见 ssh/agent.h 头注）：
 *   - agentUnlock / agentLock / agentLockAll / agentIsLocked / agentKeyCount /
 *     agentSetTimeout / agentTimeoutMinutes：托管库管理；
 *   - authenticateAgent(handle, keyId)：会话侧用已托管密钥做公钥认证
 *     （受理语义与 authenticatePublicKey 相同；agent 未解锁/无 keyId 时返回
 *     false 且不消耗认证重试计数，见 session.h）；
 *   - agentKeygen(comment, passphrase)：U3 生成 ed25519 密钥对。
 *     成功返回 { keyType, privateKeyPem, publicKeyLine, comment }，失败 null。
 *     私钥为 PKCS#8 PEM（OpenSSH 私钥完整序列化过重，见 cpp/ssh/keygen.h）；
 *     公钥为 OpenSSH 单行，指纹由 ArkTS KeyManagerLogic.formatOpenSshFingerprint 计算。
 *
 * 线程：全部方法在 ArkTS 主线程同步受理；agent 内部互斥锁保证与会话
 * 循环线程上的 getKeyMaterial 并发安全。
 *
 * 凭据安全：privateKey/passphrase 从 napi 读入后交给 SshAgent::unlock
 * （受理即复制并清零调用方 buffer）；未受理时本层自行 secureZero。
 */
#pragma once

#include "napi/native_api.h"

namespace sshclient {
namespace bridge {

// 向 exports 注册 agent 桥接方法（由 napi_init.cpp 调用）
void RegisterAgentBridge(napi_env env, napi_value exports);

} // namespace bridge
} // namespace sshclient
