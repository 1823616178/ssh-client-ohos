#include "agent.h"

#include <cstring>
#include <utility>

#include "auth.h" // secureZero（OPENSSL_cleanse 封装，选型理由见 auth.h 头注）

namespace sshclient {
namespace ssh {

// ---------------------------------------------------------------- 敏感材料的析构兜底

SshAgent::AgentKeyMaterial::~AgentKeyMaterial()
{
    secureZero(privateKey);
    secureZero(passphrase);
}

SshAgent::AgentKey::~AgentKey()
{
    secureZero(privateKey);
    secureZero(passphrase);
}

// ---------------------------------------------------------------- 构造 / 析构

SshAgent::SshAgent()
    : now_([] { return std::chrono::steady_clock::now(); }),
      lastActivityAt_(std::chrono::steady_clock::now())
{
}

SshAgent::SshAgent(Clock now) : now_(std::move(now)), lastActivityAt_(now_()) {}

SshAgent::~SshAgent()
{
    lockAll();
}

// ---------------------------------------------------------------- 格式粗检（纯逻辑）

bool SshAgent::looksLikePrivateKey(const std::string &data)
{
    const size_t begin = data.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) {
        return false; // 空或全空白
    }
    // 受支持的私钥头（逐前缀比较；注意「-----BEGIN PRIVATE KEY-----」不会误中
    // 「-----BEGIN ENCRYPTED PRIVATE KEY-----」，compare 按完整头长度逐字节比对）
    static const char *const kHeaders[] = {
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----",
        "-----BEGIN DSA PRIVATE KEY-----",
        "-----BEGIN PRIVATE KEY-----",          // PKCS#8 明文
        "-----BEGIN ENCRYPTED PRIVATE KEY-----", // PKCS#8 加密
    };
    for (const char *header : kHeaders) {
        if (data.compare(begin, std::strlen(header), header) == 0) {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------- 解锁 / 锁定

bool SshAgent::unlock(const std::string &keyId, std::string &privateKeyData,
                      std::string &passphrase)
{
    if (keyId.empty() || !looksLikePrivateKey(privateKeyData)) {
        // 粗检不通过：未受理，调用方 buffer 原样保留（与 N8 未受理语义一致）
        return false;
    }
    std::lock_guard<std::mutex> guard(mutex_);
    expireIfNeededLocked();
    // 替换语义：同 keyId 已存在时先安全清除旧条目再入库
    const auto it = keys_.find(keyId);
    if (it != keys_.end()) {
        wipeEntry(*it->second);
        keys_.erase(it);
    }
    auto entry = std::make_shared<AgentKey>();
    entry->privateKey = privateKeyData;
    entry->passphrase = passphrase;
    keys_.emplace(keyId, std::move(entry));
    lastActivityAt_ = now_(); // 解锁刷新超时滑动窗口
    // 受理即清零调用方 buffer（复制语义而非 move，理由见头注——SSO 内联
    // buffer 只有 secureZero 覆盖 [0,size) 才可靠）
    secureZero(privateKeyData);
    secureZero(passphrase);
    return true;
}

bool SshAgent::lock(const std::string &keyId)
{
    std::lock_guard<std::mutex> guard(mutex_);
    expireIfNeededLocked();
    const auto it = keys_.find(keyId);
    if (it == keys_.end()) {
        return false;
    }
    wipeEntry(*it->second);
    keys_.erase(it);
    return true;
}

void SshAgent::lockAll()
{
    std::lock_guard<std::mutex> guard(mutex_);
    wipeAllLocked();
}

// ---------------------------------------------------------------- 超时

void SshAgent::setTimeout(uint32_t minutes)
{
    std::lock_guard<std::mutex> guard(mutex_);
    timeoutMinutes_ = minutes;
    // 收紧超时时若活动参照点已过期，本次调用即触发整体清除
    expireIfNeededLocked();
}

uint32_t SshAgent::timeoutMinutes()
{
    std::lock_guard<std::mutex> guard(mutex_);
    expireIfNeededLocked();
    return timeoutMinutes_;
}

// ---------------------------------------------------------------- 查询 / 取钥

bool SshAgent::isLocked(const std::string &keyId)
{
    std::lock_guard<std::mutex> guard(mutex_);
    expireIfNeededLocked();
    return keys_.find(keyId) == keys_.end();
}

size_t SshAgent::keyCount()
{
    std::lock_guard<std::mutex> guard(mutex_);
    expireIfNeededLocked();
    return keys_.size();
}

std::optional<SshAgent::AgentKeyMaterial> SshAgent::getKeyMaterial(const std::string &keyId)
{
    std::lock_guard<std::mutex> guard(mutex_);
    expireIfNeededLocked();
    const auto it = keys_.find(keyId);
    if (it == keys_.end()) {
        return std::nullopt;
    }
    AgentKeyMaterial material;
    material.privateKey = it->second->privateKey;
    material.passphrase = it->second->passphrase;
    lastActivityAt_ = now_(); // 成功取钥刷新滑动窗口
    return material;
}

std::shared_ptr<const SshAgent::AgentKey> SshAgent::testOnlyPeek(const std::string &keyId) const
{
    std::lock_guard<std::mutex> guard(mutex_);
    const auto it = keys_.find(keyId);
    if (it == keys_.end()) {
        return nullptr;
    }
    return it->second; // shared_ptr<AgentKey> → shared_ptr<const AgentKey> 隐式转换
}

// ---------------------------------------------------------------- 清除（持锁调用）

void SshAgent::expireIfNeededLocked()
{
    if (timeoutMinutes_ == 0 || keys_.empty()) {
        return;
    }
    if (now_() - lastActivityAt_ >= std::chrono::minutes(timeoutMinutes_)) {
        wipeAllLocked();
    }
}

void SshAgent::wipeEntry(AgentKey &entry)
{
    secureZero(entry.privateKey);
    secureZero(entry.passphrase);
}

void SshAgent::wipeAllLocked()
{
    for (auto &kv : keys_) {
        wipeEntry(*kv.second);
    }
    keys_.clear();
}

} // namespace ssh
} // namespace sshclient
