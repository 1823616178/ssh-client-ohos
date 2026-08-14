/**
 * 应用内 SSH Agent 测试 —— 任务 N9「内存密钥托管，多会话复用，超时自动清除」。
 *
 * 覆盖：
 *   单元级（不需要真实服务器）：
 *     - unlock 粗检：PEM/OpenSSH 头识别、空/垃圾输入拒绝（且未受理时调用方
 *       buffer 原样保留）、受理即清零调用方 buffer、同 keyId 替换语义
 *      （旧条目先 OPENSSL_cleanse 再移除）
 *     - getKeyMaterial：返回独立快照（清零快照不影响托管副本）、未知 keyId 失败
 *     - lock / lockAll：公开接口不再提供密钥 + 内部 buffer 字节全 0
 *      （testOnlyPeek 保活句柄断言原字节区间被 OPENSSL_cleanse）+ 容器清空
 *     - 超时（注入假时钟）：滑动窗口刷新、到期整体清除且 buffer 全 0、
 *       timeout=0 永不过期、收紧超时立即生效；析构兜底清除
 *     - authenticateAgent：非 authenticating 态 / agent 锁定时拒绝受理
 *     - 多线程并发 smoke：unlock/get/lock/lockAll 交替（ASan 下验证无越界与泄漏）
 *   集成（SSH_TESTS_INTEGRATION 且认证 sshd 环境就绪时；否则 GTEST_SKIP）：
 *     - 验收一「解锁一次后第二个会话免密」：会话 A 用 authenticateAgent 连通后，
 *       会话 B 只凭 keyId（接口不接收私钥材料）连通同一 sshd
 *     - 带短语密钥经 agent 托管，两个会话先后连通（短语同样免重复输入）
 *     - agent 锁定/未知 keyId 时不消耗认证重试计数（authMaxAttempts=1 下仍可密码连通）
 *
 * 「内存无密钥残留」的验证语义边界（与 agent.h 头注一致）：断言点是 (1) 公开接口
 * 不再提供密钥、(2) 内部容器持有的 buffer 字节全 0（testOnlyPeek 保活句柄观察）、
 * (3) 容器清空；不做全进程内存扫描（也不需要——认证路径副本由 N8 清零链覆盖）。
 *
 * 清零断言的字节观察前提：合成密钥材料为长串（> SSO 容量，强制堆分配）——
 * SSO 内联 buffer 随对象本身存活，「原字节区域」语义不同，故断言针对堆 buffer；
 * testOnlyPeek 的 shared_ptr 为条目保活，使被清零的 buffer 在断言期间仍可安全读取。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "io/SessionThread.h"
#include "ssh/agent.h"
#include "ssh/auth.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;
using sshclient::ssh::AuthMethod;
using sshclient::ssh::SshAgent;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;

namespace {

// ---------------------------------------------------------------- 测试辅助

// 可手动推进的假时钟（steady_clock 时间轴）：注入 SshAgent 验证惰性超时
class FakeClock {
public:
    FakeClock() : now_(std::chrono::steady_clock::now()) {}
    std::chrono::steady_clock::time_point now() const { return now_; }
    void advance(std::chrono::milliseconds delta) { now_ += delta; }

private:
    std::chrono::steady_clock::time_point now_;
};

// 合成私钥材料：带真实私钥头的长串（512 字节填充 > SSO 容量，强制堆分配，
// 见文件头注的清零断言前提）
std::string FakeOpenSshKey(char fill = 'K')
{
    return std::string("-----BEGIN OPENSSH PRIVATE KEY-----\n") + std::string(512, fill) +
           "\n-----END OPENSSH PRIVATE KEY-----\n";
}

std::string FakePemKey()
{
    return std::string("-----BEGIN RSA PRIVATE KEY-----\n") + std::string(256, 'R') +
           "\n-----END RSA PRIVATE KEY-----\n";
}

// 64 字节填充 > SSO 容量（libstdc++ 15 / libc++ 22），强制堆分配
std::string FakePassphrase(char fill = 'p')
{
    return std::string(64, fill);
}

bool AllZero(const char *p, size_t n)
{
    for (size_t i = 0; i < n; ++i) {
        if (p[i] != 0) {
            return false;
        }
    }
    return true;
}

bool AnyNonZero(const char *p, size_t n)
{
    for (size_t i = 0; i < n; ++i) {
        if (p[i] != 0) {
            return true;
        }
    }
    return false;
}

} // namespace

// ================================================================== 单元级

TEST(SshAgentUnitTest, UnlockCoarseCheckAndCallerBufferWiped)
{
    SshAgent agent;

    // 垃圾内容（无私钥头）拒绝受理，调用方 buffer 原样保留
    std::string garbage = "not-a-private-key";
    std::string phrase = FakePassphrase();
    EXPECT_FALSE(agent.unlock("k", garbage, phrase));
    EXPECT_EQ(garbage, "not-a-private-key");
    EXPECT_EQ(phrase, FakePassphrase());
    EXPECT_TRUE(agent.isLocked("k"));
    EXPECT_EQ(agent.keyCount(), 0u);

    // 空私钥拒绝；空 keyId 拒绝
    std::string empty;
    EXPECT_FALSE(agent.unlock("k", empty, phrase));
    std::string key = FakeOpenSshKey();
    EXPECT_FALSE(agent.unlock("", key, phrase));
    EXPECT_FALSE(key.empty());

    // OpenSSH 头受理；受理即清零调用方私钥/短语 buffer
    ASSERT_TRUE(agent.unlock("k", key, phrase));
    EXPECT_TRUE(key.empty()) << "unlock 受理后调用方私钥 buffer 应已清零";
    EXPECT_TRUE(phrase.empty()) << "unlock 受理后调用方短语 buffer 应已清零";
    EXPECT_FALSE(agent.isLocked("k"));
    EXPECT_EQ(agent.keyCount(), 1u);

    // PEM 头（PKCS#1）同样受理；带前导空白也可识别
    std::string pem = "  \r\n" + FakePemKey();
    std::string noPhrase;
    EXPECT_TRUE(agent.unlock("pem", pem, noPhrase));
    EXPECT_EQ(agent.keyCount(), 2u);
    EXPECT_TRUE(agent.isLocked("missing"));
}

TEST(SshAgentUnitTest, UnlockSameKeyIdReplacesAndWipesOldEntry)
{
    SshAgent agent;
    std::string keyA = FakeOpenSshKey('A');
    std::string phrase;
    ASSERT_TRUE(agent.unlock("k", keyA, phrase));

    const auto peekA = agent.testOnlyPeek("k");
    ASSERT_TRUE(peekA != nullptr);
    const char *bufA = peekA->privateKey.data();
    const size_t lenA = peekA->privateKey.size();
    ASSERT_GT(lenA, 0u);
    ASSERT_TRUE(AnyNonZero(bufA, lenA)); // 防「本来就是 0」假阳性

    // 同 keyId 重复 unlock：替换语义——旧条目先清零再移除
    std::string keyB = FakeOpenSshKey('B');
    ASSERT_TRUE(agent.unlock("k", keyB, phrase));
    EXPECT_EQ(agent.keyCount(), 1u);
    EXPECT_TRUE(peekA->privateKey.empty());
    EXPECT_TRUE(AllZero(bufA, lenA)) << "被替换的旧私钥 buffer 应已清零";

    const auto material = agent.getKeyMaterial("k");
    ASSERT_TRUE(material.has_value());
    EXPECT_EQ(material->privateKey, FakeOpenSshKey('B'));
}

TEST(SshAgentUnitTest, GetKeyMaterialReturnsIndependentSnapshot)
{
    SshAgent agent;
    std::string key = FakeOpenSshKey();
    std::string phrase = FakePassphrase();
    const std::string keyRef = key;     // 参照副本（unlock 会清零 key/phrase）
    const std::string phraseRef = phrase;
    ASSERT_TRUE(agent.unlock("k", key, phrase));

    auto m1 = agent.getKeyMaterial("k"); // 非 const：后面要清零快照验证独立性
    ASSERT_TRUE(m1.has_value());
    EXPECT_EQ(m1->privateKey, keyRef);
    EXPECT_EQ(m1->passphrase, phraseRef);

    // 快照独立：清零快照不影响 agent 托管的副本（认证方用完即清的常规动作）
    sshclient::ssh::secureZero(m1->privateKey);
    sshclient::ssh::secureZero(m1->passphrase);
    const auto m2 = agent.getKeyMaterial("k");
    ASSERT_TRUE(m2.has_value());
    EXPECT_EQ(m2->privateKey, keyRef);
    EXPECT_EQ(m2->passphrase, phraseRef);

    // 未知 keyId
    EXPECT_FALSE(agent.getKeyMaterial("missing").has_value());
}

TEST(SshAgentUnitTest, LockWipesInternalBufferAndRemovesKey)
{
    SshAgent agent;
    std::string key = FakeOpenSshKey();
    std::string phrase = FakePassphrase();
    ASSERT_TRUE(agent.unlock("k", key, phrase));

    const auto peek = agent.testOnlyPeek("k");
    ASSERT_TRUE(peek != nullptr);
    const char *keyBuf = peek->privateKey.data();
    const size_t keyLen = peek->privateKey.size();
    const char *phrBuf = peek->passphrase.data();
    const size_t phrLen = peek->passphrase.size();
    ASSERT_TRUE(AnyNonZero(keyBuf, keyLen));
    ASSERT_TRUE(AnyNonZero(phrBuf, phrLen));

    EXPECT_FALSE(agent.lock("missing")); // 不存在
    ASSERT_TRUE(agent.lock("k"));

    // (1) 公开接口不再提供该密钥
    EXPECT_TRUE(agent.isLocked("k"));
    EXPECT_FALSE(agent.getKeyMaterial("k").has_value());
    EXPECT_EQ(agent.keyCount(), 0u);
    // (2) 内部 buffer 已被 OPENSSL_cleanse：std::string 已 clear，原字节区间全 0
    //    （peek 保活条目，buffer 内存仍有效）
    EXPECT_TRUE(peek->privateKey.empty());
    EXPECT_TRUE(peek->passphrase.empty());
    EXPECT_TRUE(AllZero(keyBuf, keyLen)) << "私钥 buffer 清除后应全 0";
    EXPECT_TRUE(AllZero(phrBuf, phrLen)) << "短语 buffer 清除后应全 0";
    // 重复 lock → false
    EXPECT_FALSE(agent.lock("k"));
}

TEST(SshAgentUnitTest, LockAllWipesEveryEntry)
{
    SshAgent agent;
    std::string keyA = FakeOpenSshKey('A');
    std::string keyB = FakePemKey();
    std::string phraseA;
    std::string phraseB = FakePassphrase('q');
    ASSERT_TRUE(agent.unlock("a", keyA, phraseA));
    ASSERT_TRUE(agent.unlock("b", keyB, phraseB));
    EXPECT_EQ(agent.keyCount(), 2u);

    const auto peekA = agent.testOnlyPeek("a");
    const auto peekB = agent.testOnlyPeek("b");
    ASSERT_TRUE(peekA != nullptr && peekB != nullptr);
    const char *bufA = peekA->privateKey.data();
    const size_t lenA = peekA->privateKey.size();
    const char *bufB = peekB->passphrase.data();
    const size_t lenB = peekB->passphrase.size();

    agent.lockAll();
    EXPECT_EQ(agent.keyCount(), 0u);
    EXPECT_TRUE(agent.isLocked("a"));
    EXPECT_TRUE(agent.isLocked("b"));
    EXPECT_FALSE(agent.getKeyMaterial("a").has_value());
    EXPECT_TRUE(peekA->privateKey.empty());
    EXPECT_TRUE(AllZero(bufA, lenA));
    EXPECT_TRUE(peekB->passphrase.empty());
    EXPECT_TRUE(AllZero(bufB, lenB));
    agent.lockAll(); // 幂等：空容器再调不崩
}

TEST(SshAgentUnitTest, TimeoutLazyExpiryWipesAll)
{
    const auto fc = std::make_shared<FakeClock>();
    SshAgent agent([fc] { return fc->now(); });
    agent.setTimeout(1); // 1 分钟
    EXPECT_EQ(agent.timeoutMinutes(), 1u);

    std::string key = FakeOpenSshKey();
    std::string phrase = FakePassphrase();
    ASSERT_TRUE(agent.unlock("k", key, phrase));
    const auto peek = agent.testOnlyPeek("k");
    ASSERT_TRUE(peek != nullptr);
    const char *keyBuf = peek->privateKey.data();
    const size_t keyLen = peek->privateKey.size();
    const char *phrBuf = peek->passphrase.data();
    const size_t phrLen = peek->passphrase.size();

    // 滑动窗口：30 s 后取钥成功并刷新活动参照点
    fc->advance(30s);
    EXPECT_TRUE(agent.getKeyMaterial("k").has_value());
    // 再推进 40 s（距上次活动 40 s < 1 min）仍未过期
    fc->advance(40s);
    EXPECT_TRUE(agent.getKeyMaterial("k").has_value());
    EXPECT_FALSE(agent.isLocked("k"));
    // 再推进 61 s（距上次活动 61 s ≥ 1 min）→ 惰性到期，整体清除
    fc->advance(61s);
    EXPECT_FALSE(agent.getKeyMaterial("k").has_value());
    EXPECT_TRUE(agent.isLocked("k"));
    EXPECT_EQ(agent.keyCount(), 0u);
    // 验收二断言点：超时到期后内部 buffer 全 0（容器已清空，peek 保活观察）
    EXPECT_TRUE(peek->privateKey.empty());
    EXPECT_TRUE(AllZero(keyBuf, keyLen)) << "超时到期后私钥 buffer 应全 0";
    EXPECT_TRUE(AllZero(phrBuf, phrLen)) << "超时到期后短语 buffer 应全 0";
}

TEST(SshAgentUnitTest, TimeoutZeroNeverExpires)
{
    const auto fc = std::make_shared<FakeClock>();
    SshAgent agent([fc] { return fc->now(); });
    EXPECT_EQ(agent.timeoutMinutes(), 0u); // 默认 0 = 不过期

    std::string key = FakeOpenSshKey();
    std::string phrase;
    ASSERT_TRUE(agent.unlock("k", key, phrase));
    fc->advance(std::chrono::hours(24 * 365)); // 推进一年
    const auto material = agent.getKeyMaterial("k");
    ASSERT_TRUE(material.has_value());
    EXPECT_FALSE(agent.isLocked("k"));
}

TEST(SshAgentUnitTest, TighteningTimeoutAppliesImmediately)
{
    const auto fc = std::make_shared<FakeClock>();
    SshAgent agent([fc] { return fc->now(); });
    std::string key = FakeOpenSshKey();
    std::string phrase;
    ASSERT_TRUE(agent.unlock("k", key, phrase));

    fc->advance(5min); // 无超时时随意推进
    agent.setTimeout(1); // 收紧到 1 分钟：活动参照点已过期 → 本次调用即整体清除
    EXPECT_TRUE(agent.isLocked("k"));
    EXPECT_EQ(agent.keyCount(), 0u);
}

TEST(SshAgentUnitTest, DestructorWipesAllEntries)
{
    std::shared_ptr<const SshAgent::AgentKey> peek;
    const char *buf = nullptr;
    size_t len = 0;
    {
        SshAgent agent;
        std::string key = FakeOpenSshKey();
        std::string phrase = FakePassphrase();
        ASSERT_TRUE(agent.unlock("k", key, phrase));
        peek = agent.testOnlyPeek("k");
        ASSERT_TRUE(peek != nullptr);
        buf = peek->privateKey.data();
        len = peek->privateKey.size();
        ASSERT_TRUE(AnyNonZero(buf, len));
    } // agent 析构 → 兜底 lockAll
    EXPECT_TRUE(peek->privateKey.empty());
    EXPECT_TRUE(AllZero(buf, len)) << "agent 析构后私钥 buffer 应全 0";
}

TEST(SshAgentUnitTest, ConcurrencySmoke)
{
    SshAgent agent; // 真实时钟、无超时
    std::atomic<bool> start{false};
    std::atomic<int> getOk{0};
    std::vector<std::thread> threads;
    threads.reserve(8);
    for (int i = 0; i < 8; ++i) {
        threads.emplace_back([&, i] {
            while (!start.load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            const std::string id = "key" + std::to_string(i % 4); // 4 个 keyId 交错竞争
            for (int iter = 0; iter < 200; ++iter) {
                switch ((i + iter) % 4) {
                case 0: {
                    std::string key = FakeOpenSshKey();
                    std::string phrase = FakePassphrase();
                    agent.unlock(id, key, phrase);
                    break;
                }
                case 1:
                    if (agent.getKeyMaterial(id).has_value()) {
                        getOk.fetch_add(1, std::memory_order_relaxed);
                    }
                    break;
                case 2:
                    agent.lock(id);
                    break;
                default:
                    if (iter % 25 == 0) {
                        agent.lockAll();
                    } else {
                        (void)agent.isLocked(id);
                        (void)agent.keyCount();
                    }
                    break;
                }
            }
        });
    }
    start.store(true, std::memory_order_release);
    for (auto &t : threads) {
        t.join();
    }
    agent.lockAll();
    EXPECT_EQ(agent.keyCount(), 0u);
    EXPECT_GT(getOk.load(), 0) << "并发期间应有成功取钥发生";
}

TEST(SshAgentUnitTest, AuthenticateAgentRejectedWhenSessionIdle)
{
    SshAgent agent;
    std::string key = FakeOpenSshKey();
    std::string phrase;
    ASSERT_TRUE(agent.unlock("k", key, phrase));

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    {
        SshSession session(thread, {}, nullptr); // idle 态
        AuthResultBox box;
        EXPECT_FALSE(session.authenticateAgent("k", agent, std::ref(box)));
        // agent 内条目不受取钥影响（取的是快照副本），仍处解锁状态
        EXPECT_FALSE(agent.isLocked("k"));
        thread.stop();
    }
}

// ================================================================== 集成（真实认证 sshd）

TEST(SshAgentIntegrationTest, UnlockOnceSecondSessionAuthFree)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SshAgent agent;
    std::string key = env.keyNoPassphrase; // 复制：env 持有原件供后续对照
    std::string phrase;                    // 空 = 无短语
    ASSERT_TRUE(agent.unlock("main", key, phrase));
    EXPECT_TRUE(key.empty()) << "unlock 受理后调用方私钥 buffer 应已清零";

    // 会话 A：经 agent 取钥认证连通
    {
        SessionThread thread;
        ASSERT_TRUE(thread.start());
        StateRecorder rec;
        {
            SshSession session(thread, {}, std::ref(rec));
            ASSERT_TRUE(ReachAuthenticating(session, rec, env));
            AuthResultBox box;
            ASSERT_TRUE(session.authenticateAgent("main", agent, std::ref(box)));
            ASSERT_TRUE(box.wait(10s));
            ASSERT_TRUE(box.result()->success) << box.result()->message;
            EXPECT_EQ(box.result()->method, AuthMethod::kPublicKey);
            ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
            session.close();
            ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
            thread.stop();
        }
    }

    // 会话 B：同一 agent 同一 keyId，全程不接触私钥材料（authenticateAgent
    // 接口本身不接收私钥参数）——「解锁一次后第二个会话免密」
    {
        SessionThread thread;
        ASSERT_TRUE(thread.start());
        StateRecorder rec;
        {
            SshSession session(thread, {}, std::ref(rec));
            ASSERT_TRUE(ReachAuthenticating(session, rec, env));
            AuthResultBox box;
            ASSERT_TRUE(session.authenticateAgent("main", agent, std::ref(box)));
            ASSERT_TRUE(box.wait(10s));
            ASSERT_TRUE(box.result()->success) << box.result()->message;
            ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
            thread.stop();
        }
    }

    // 密钥仍托管中且内容未被认证过程破坏（供更多会话复用）
    const auto material = agent.getKeyMaterial("main");
    ASSERT_TRUE(material.has_value());
    EXPECT_EQ(material->privateKey, env.keyNoPassphrase);
    agent.lockAll();
    EXPECT_EQ(agent.keyCount(), 0u);
}

TEST(SshAgentIntegrationTest, PassphraseKeyReusedAcrossSessions)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SshAgent agent;
    std::string key = env.keyWithPassphrase;
    std::string phrase = env.passphrase; // 短语一并托管
    ASSERT_TRUE(agent.unlock("enc", key, phrase));
    EXPECT_TRUE(key.empty());
    EXPECT_TRUE(phrase.empty());

    for (int round = 0; round < 2; ++round) { // 两个会话先后复用同一托管条目
        SessionThread thread;
        ASSERT_TRUE(thread.start());
        StateRecorder rec;
        {
            SshSession session(thread, {}, std::ref(rec));
            ASSERT_TRUE(ReachAuthenticating(session, rec, env));
            AuthResultBox box;
            ASSERT_TRUE(session.authenticateAgent("enc", agent, std::ref(box)));
            ASSERT_TRUE(box.wait(10s));
            ASSERT_TRUE(box.result()->success)
                << "第 " << round << " 个会话: " << box.result()->message;
            ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
            thread.stop();
        }
    }
    agent.lockAll();
}

TEST(SshAgentIntegrationTest, LockedAgentDoesNotConsumeAuthAttempts)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SshAgent agent; // 从未 unlock
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.authMaxAttempts = 1; // 一次认证失败即终态——以此反证 agent 失败未计数
        SshSession session(thread, opts, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        // agent 锁定（keyId 不存在）：拒绝受理，不回调、不进认证尝试
        AuthResultBox agentBox;
        EXPECT_FALSE(session.authenticateAgent("missing", agent, std::ref(agentBox)));
        EXPECT_FALSE(agentBox.wait(300ms)) << "未受理的 agent 认证不应回调";
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);

        // 若上面的 agent 调用消耗了唯一一次尝试次数，会话应已进 error 终态；
        // 这里密码认证直接成功，反证未消耗
        std::string password = env.password;
        AuthResultBox box;
        ASSERT_TRUE(session.authenticatePassword(password, std::ref(box)));
        ASSERT_TRUE(box.wait(10s));
        ASSERT_TRUE(box.result()->success) << box.result()->message;
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        thread.stop();
    }
}
