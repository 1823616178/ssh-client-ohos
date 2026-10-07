/**
 * U3 native ed25519 keygen —— OpenSSL EVP 生成 + 导出。
 *
 * 格式约定（OpenSSH 私钥完整序列化过重，本任务走 PEM PKCS#8）：
 *   - 私钥：PKCS#8 PEM
 *       passphrase 空  → -----BEGIN PRIVATE KEY-----（明文 PKCS#8）
 *       passphrase 非空 → -----BEGIN ENCRYPTED PRIVATE KEY-----（AES-256-CBC PKCS#8）
 *     libssh2_userauth_publickey_frommemory 经 OpenSSL PEM 读取可识别上述格式；
 *     与 OpenSSH 原生 `-----BEGIN OPENSSH PRIVATE KEY-----` 不同，import 标为 pkcs8。
 *   - 公钥：OpenSSH 单行格式 `ssh-ed25519 <base64> [comment]`
 *     blob = string("ssh-ed25519") + string(raw32)，与 ssh-keygen -y / authorized_keys 一致。
 *
 * 纯逻辑层（KeyManagerLogic.buildOpensshPublicKeyLine）对同一 wire 格式有 ArkTS 镜像与单测。
 */
#pragma once

#include <cstddef>
#include <string>

namespace sshclient {
namespace ssh {

struct GeneratedKeyPair {
    std::string privateKeyPem; // PKCS#8 PEM（见文件头注）
    std::string publicKeyLine; // "ssh-ed25519 AAAA... [comment]"
    std::string keyType;       // 固定 "ssh-ed25519"
    std::string comment;       // 实际写入公钥行的 comment（空则无第三段）
};

/**
 * 生成 ed25519 密钥对。
 * comment 空时公钥行不带 comment 字段（不伪造 user@host）。
 * passphrase 空 = 明文 PKCS#8；非空 = 加密 PKCS#8。
 * 失败返回 false 且 *out 不被写入完整结果（内部已尽量清零临时密钥材料）。
 */
bool generateEd25519KeyPair(const std::string &comment, const std::string &passphrase,
                            GeneratedKeyPair *out);

/**
 * 由 32 字节 ed25519 公钥组装 OpenSSH 公钥行（无 comment 则不带第三段）。
 * keyType 非空时用于 wire 前缀；调用方应传 "ssh-ed25519"。
 */
std::string formatOpensshPublicKeyLine(const std::string &keyType,
                                       const unsigned char *publicKeyBytes,
                                       size_t publicKeyLen,
                                       const std::string &comment);

} // namespace ssh
} // namespace sshclient
