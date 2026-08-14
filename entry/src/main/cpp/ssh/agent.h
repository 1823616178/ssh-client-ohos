/**
 * 应用内 SSH Agent —— 任务 N9（TASKS M1，依赖 N8；DESIGN §7.1）。
 *
 * 背景：HarmonyOS 没有系统级 ssh-agent，桌面端依赖的系统 agent 在本平台不存在，
 * 因此在进程内实现密钥托管：私钥解锁后驻留内存，供多个会话（与未来的端口转发）
 * 复用；超时或手动锁定后从内存清除。
 *
 * 职责与语义边界：
 *   - unlock 的成功语义 = 格式粗检（PEM/OpenSSH 私钥头识别 + 非空）+ 入库托管，
 *     不代表私钥/短语真实有效。libssh2 没有「只解析不认证」的独立 API，OpenSSL
 *     EVP 又不支持 OpenSSH 格式（-----BEGIN OPENSSH PRIVATE KEY-----），真正的
 *     有效性只能在首次认证时由 libssh2_userauth_publickey_frommemory 验证——
 *     短语错误的密钥可以 unlock 成功，首次认证回报 kAuthFailedPassphrase，
 *     届时上层应 lock 掉该条目；
 *   - 私钥明文与短语只存在于本进程内存，agent 自身不做任何落盘；
 *   - 「清除后内存中无密钥残留」的可验证语义（对齐 TASKS N9 验收措辞）：
 *       (1) 公开接口不再提供该密钥（getKeyMaterial 失败、isLocked 为 true）；
 *       (2) 内部容器持有的 buffer 已被 OPENSSL_cleanse 清零、条目已从容器移除
 *           —— 测试经 testOnlyPeek 保活句柄断言原字节区间全 0；
 *       (3) lockAll / 析构后容器为空（keyCount 为 0）。
 *     不在语义内：全进程内存扫描——认证期间 libssh2/OpenSSL 内部的临时副本、
 *     已归还分配器的旧块均无法在不扫描全进程的前提下断言，也不必要（认证路径
 *     上的副本由 N8 的「受理即清零」与 AuthOp 析构清零覆盖，见 auth.cpp）；
 *   - 超时是惰性语义：agent 不持有后台线程/定时器，到期判定发生在每次公开
 *     API 调用时（unlock/lock/getKeyMaterial/isLocked/keyCount/setTimeout）。
 *     参照点为滑动窗口 lastActivityAt_（unlock 与 getKeyMaterial 成功时刷新），
 *     到期即整体清除（lockAll——TASKS N9 措辞「到期自动 lockAll」：超时保护的
 *     是整个托管期而非单键租约）。需要「到点主动锁定」的场景由上层 UI 定时器
 *     到点调用 lockAll() 实现，与惰性语义不冲突（若已被惰性清除，lockAll 是
 *     幂等空操作）。
 *
 * 线程安全：所有公开方法经互斥锁保护，会话线程与 UI 线程可并发调用。
 * 本对象是显式实例（进程内单例语义由未来的 SessionManager/C4 持有一个实例
 * 实现），不引入全局单例。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库（清零经 auth.h 的 secureZero → OpenSSL
 * OPENSSL_cleanse，实现文件才引入），禁止 include <napi/native_api.h> /
 * <hilog/log.h>（桥接层是 N11）。
 */
#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>

namespace sshclient {
namespace ssh {

class SshAgent {
public:
    // getKeyMaterial 的返回载体：密钥材料快照。析构兜底清零——正常路径下快照
    // 由认证方受理时清零（N8 authenticate* 的「受理即清零」约定），本析构覆盖
    // 「取出后未使用 / 未被受理」的残留路径。
    struct AgentKeyMaterial {
        std::string privateKey; // 私钥原始字节（PEM 或 OpenSSH 格式）
        std::string passphrase; // 私钥短语（空 = 无短语）
        ~AgentKeyMaterial();
    };

    // 内部托管条目。testOnlyPeek 以 shared_ptr 形式给出只读观察句柄：
    // 句柄为条目保活，使测试在 lock/lockAll/超时清除之后仍能检查原 buffer
    // 的字节内容（已清零 = 全 0）——条目本身已从容器移除，agent 不再提供它。
    struct AgentKey {
        std::string privateKey; // 私钥原始字节
        std::string passphrase; // 私钥短语（可空；同样属敏感材料，一并清零管理）
        ~AgentKey(); // 兜底清零（正常清除路径已显式 OPENSSL_cleanse，此处防遗漏）
    };

    // 可注入时钟（测试用假时钟推进超时；默认 steady_clock，单调、不受系统
    // 时钟回拨影响）。构造后不可变，读取无需加锁之外的同步。
    using Clock = std::function<std::chrono::steady_clock::time_point()>;
    SshAgent();
    explicit SshAgent(Clock now);
    ~SshAgent(); // 兜底 lockAll：agent 销毁时密钥材料不残留

    SshAgent(const SshAgent &) = delete;
    SshAgent &operator=(const SshAgent &) = delete;

    // 解锁并托管私钥（成功语义边界见文件头注：格式粗检 + 入库，有效性在首次
    // 认证时才验证）。keyId 为上层分配的标识（如密钥指纹/主机配置 id）；
    // 重复 unlock 同 keyId 采用替换语义：先安全清除旧条目再入库。
    // 受理成功返回 true 并清零调用方的 privateKeyData / passphrase buffer
    // （复制后 OPENSSL_cleanse 原串并 clear，与 N8 认证「受理即清零」同一约定；
    // 不用 move——短串 SSO 场景下 move 会让源串内联 buffer 残留明文，复制 +
    // secureZero 覆盖 [0,size) 才可靠）。粗检不通过返回 false，buffer 原样保留。
    bool unlock(const std::string &keyId, std::string &privateKeyData,
                std::string &passphrase);

    // 手动锁定：清除指定条目的密钥材料（OPENSSL_cleanse + 容器移除）。
    // 返回 false = 不存在该 keyId（含已被超时惰性清除）。
    bool lock(const std::string &keyId);
    // 锁定全部（幂等）：所有条目清零并移除。超时到期、UI「立即锁定」、
    // 应用退出清理共用此入口。
    void lockAll();

    // 托管超时（分钟，0 = 永不超时；默认 0）。惰性检查（见头注）：收紧超时
    // 时若活动参照点已过期，本次调用即触发整体清除。
    void setTimeout(uint32_t minutes);
    uint32_t timeoutMinutes(); // 读取前同样做一次惰性过期检查

    // keyId 当前是否处于锁定状态（不存在 / 已手动清除 / 已超时清除 → true）
    bool isLocked(const std::string &keyId);
    // 当前托管的密钥条数（惰性过期检查后的真实值；诊断与测试用）
    size_t keyCount();

    // 受控取钥：仅供认证调用（SshSession::authenticateAgent）。返回材料快照
    // 副本；nullopt = 锁定/不存在/已超时。职责链：agent 内部副本继续托管，
    // 快照由认证方受理时清零（authenticatePublicKey 的受理即清零），未被受理
    // 时由 AgentKeyMaterial 析构兜底清零。成功取钥刷新超时滑动窗口。
    std::optional<AgentKeyMaterial> getKeyMaterial(const std::string &keyId);

    // 仅供测试：返回内部条目的只读保活句柄（nullptr = 不存在）。
    // 用途与可验证语义边界见文件头注第 (2) 条。本钩子故意不做惰性过期
    // 检查——它观察的是「调用瞬间容器内是否仍有该条目」的原始状态。
    std::shared_ptr<const AgentKey> testOnlyPeek(const std::string &keyId) const;

private:
    // 私钥格式粗检（纯逻辑）：剥掉前导空白后以受支持的私钥头起始。
    // 覆盖 OpenSSH 新格式与 PEM 系（PKCS#1 RSA/DSA/EC、PKCS#8 明文/加密）。
    static bool looksLikePrivateKey(const std::string &data);

    // 惰性过期（持锁调用）：timeoutMinutes_ > 0 且活动参照点距今已达超时
    // → 整体清除（wipeAllLocked）
    void expireIfNeededLocked();
    static void wipeEntry(AgentKey &entry); // OPENSSL_cleanse 私钥与短语并 clear
    void wipeAllLocked();                   // 清零并移除全部条目（持锁调用）

    mutable std::mutex mutex_;
    Clock now_;
    uint32_t timeoutMinutes_ = 0;
    std::chrono::steady_clock::time_point lastActivityAt_; // 滑动窗口参照点
    std::unordered_map<std::string, std::shared_ptr<AgentKey>> keys_;
};

} // namespace ssh
} // namespace sshclient
