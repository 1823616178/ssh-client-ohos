/**
 * 认证测试 —— 任务 N8「认证：密码 / 公钥 / keyboard-interactive」。
 *
 * 覆盖：
 *   单元级（不需要真实服务器）：
 *     - secureZero：原始 buffer 逐字节清零、std::string 清零并 clear
 *     - parseAuthMethodList：userauth_list 逗号串解析（常规/空白/未知方式/空串）
 *     - mapAuthError：libssh2 错误码 → SshSessionError 映射表全分支
 *     - 非 authenticating 态拒绝受理认证（且不清零未受理的调用方 buffer）
 *   集成（SSH_TESTS_INTEGRATION 且认证 sshd 环境就绪时；否则 GTEST_SKIP）：
 *     - userauth_list 探测：password/publickey/keyboard-interactive 三者皆在
 *     - 密码认证：连通 → established；错误密码 → kAuthFailedPassword 且停留
 *       authenticating 可重试；重试正确密码成功；失败次数达上限 → error 终态
 *     - 公钥认证：不带短语连通；带短语连通；短语错误 → kAuthFailedPassphrase
 *      （libssh2 KEYFILE_AUTH_FAILED 的实测复核）；未授权密钥 → kAuthFailedKey
 *     - keyboard-interactive：固定答案连通（provider 至少被调一次）；
 *       错误答案 → kAuthFailedInteractive
 *     - 清零断言：认证受理后调用方持有的密码/私钥/短语 buffer 已被清空
 *
 * 认证 sshd 环境（root 常驻，UsePAM yes）：由 scripts/setup-host-deps.sh 准备，
 * 材料在 $HOME/ohos-probe/build/host-deps/auth/（端口/测试用户/随机密码/密钥对；
 * 密码与私钥绝不进 git 仓库）。环境变量可覆盖：SSH_TEST_AUTH_DIR / SSH_TEST_AUTH_PORT /
 * SSH_TEST_USER / SSH_TEST_PASSWORD / SSH_TEST_KEY_PASSPHRASE。
 * 环境加载器（AuthTestEnv / LoadAuthTestEnv / ReachAuthenticating 等）自 N9 起
 * 移入 sshd_testkit.h，与 agent_test.cpp 共用。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include <libssh2.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include "io/SessionThread.h"
#include "ssh/auth.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;
using sshclient::ssh::AuthMethod;
using sshclient::ssh::AuthMethodSet;
using sshclient::ssh::AuthResult;
using sshclient::ssh::KbdIntPrompt;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionError;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;

namespace {

// ---------------------------------------------------------------- 结果收集器

class AuthMethodsBox {
public:
    void operator()(std::optional<AuthMethodSet> methods)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            methods_ = std::move(methods);
            arrived_ = true;
        }
        cv_.notify_all();
    }

    bool wait(std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return arrived_; });
    }

    std::optional<AuthMethodSet> methods() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return methods_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::optional<AuthMethodSet> methods_;
    bool arrived_ = false;
};

} // namespace

// ================================================================== 单元级

TEST(SshAuthUnitTest, SecureZeroWipesRawBuffer)
{
    uint8_t buf[64];
    for (size_t i = 0; i < sizeof(buf); ++i) {
        buf[i] = static_cast<uint8_t>(i * 7 + 1); // 非零模式
    }
    sshclient::ssh::secureZero(buf, sizeof(buf));
    for (uint8_t b : buf) {
        EXPECT_EQ(b, 0);
    }
    // 边界：空指针/零长度不得崩溃
    sshclient::ssh::secureZero(nullptr, 0);
    sshclient::ssh::secureZero(buf, 0);
}

TEST(SshAuthUnitTest, SecureZeroWipesString)
{
    std::string secret = "test-secret-material";
    sshclient::ssh::secureZero(secret);
    EXPECT_TRUE(secret.empty()); // 清零并 clear：不再持有任何内容
}

TEST(SshAuthUnitTest, ParseAuthMethodListTypical)
{
    const AuthMethodSet set =
        sshclient::ssh::parseAuthMethodList("publickey,password,keyboard-interactive");
    EXPECT_TRUE(set.publicKey);
    EXPECT_TRUE(set.password);
    EXPECT_TRUE(set.keyboardInteractive);
    EXPECT_TRUE(set.unsupported.empty());
    EXPECT_EQ(set.raw, "publickey,password,keyboard-interactive");
}

TEST(SshAuthUnitTest, ParseAuthMethodListUnknownAndWhitespace)
{
    const AuthMethodSet set =
        sshclient::ssh::parseAuthMethodList("publickey, hostbased ,gssapi-with-mic");
    EXPECT_TRUE(set.publicKey);
    EXPECT_FALSE(set.password);
    EXPECT_FALSE(set.keyboardInteractive);
    EXPECT_EQ(set.unsupported,
              (std::vector<std::string>{"hostbased", "gssapi-with-mic"}));
}

TEST(SshAuthUnitTest, ParseAuthMethodListEmpty)
{
    const AuthMethodSet set = sshclient::ssh::parseAuthMethodList("");
    EXPECT_FALSE(set.publicKey);
    EXPECT_FALSE(set.password);
    EXPECT_FALSE(set.keyboardInteractive);
    EXPECT_TRUE(set.unsupported.empty());
}

TEST(SshAuthUnitTest, MapAuthErrorTable)
{
    using sshclient::ssh::mapAuthError;
    const std::string anyMessage = "whatever";
    // 密码方式：认证失败/密码过期/其余一律归 kAuthFailedPassword（message 不参与）
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_AUTHENTICATION_FAILED, AuthMethod::kPassword,
                           anyMessage),
              SshSessionError::kAuthFailedPassword);
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_PASSWORD_EXPIRED, AuthMethod::kPassword, anyMessage),
              SshSessionError::kAuthFailedPassword);
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_SOCKET_RECV, AuthMethod::kPassword, anyMessage),
              SshSessionError::kAuthFailedPassword);
    // 公钥方式 · 本地私钥加载/解密失败 → kAuthFailedPassphrase：
    // PEM 短语错误（KEYFILE_AUTH_FAILED）
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_KEYFILE_AUTH_FAILED, AuthMethod::kPublicKey,
                           "Wrong passphrase for private key"),
              SshSessionError::kAuthFailedPassphrase);
    // 无公钥数据时 OpenSSH 加密私钥的提取阶段失败（1.11.1 退化为 FILE）
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_FILE, AuthMethod::kPublicKey,
                           "Unable to extract public key from private key file: "
                           "Unsupported private key file format"),
              SshSessionError::kAuthFailedPassphrase);
    // 带公钥数据时签名阶段本地解密失败（1.11.1 吞成 PUBLICKEY_UNVERIFIED +
    // 「Callback returned error」）
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED, AuthMethod::kPublicKey,
                           "Callback returned error"),
              SshSessionError::kAuthFailedPassphrase);
    // 公钥方式 · 服务器侧拒绝 → kAuthFailedKey：
    // 未授权密钥（AUTHENTICATION_FAILED）
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_AUTHENTICATION_FAILED, AuthMethod::kPublicKey,
                           "Username/PublicKey combination invalid"),
              SshSessionError::kAuthFailedKey);
    // 服务端签名校验失败（PUBLICKEY_UNVERIFIED 的非「Callback returned error」分支）
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED, AuthMethod::kPublicKey,
                           "Invalid signature for supplied public key, or bad "
                           "username/public key combination"),
              SshSessionError::kAuthFailedKey);
    // 其余错误码默认归 kAuthFailedKey
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_DECRYPT, AuthMethod::kPublicKey, anyMessage),
              SshSessionError::kAuthFailedKey);
    // keyboard-interactive：一律 kAuthFailedInteractive
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_AUTHENTICATION_FAILED,
                           AuthMethod::kKeyboardInteractive, anyMessage),
              SshSessionError::kAuthFailedInteractive);
    EXPECT_EQ(mapAuthError(LIBSSH2_ERROR_TIMEOUT, AuthMethod::kKeyboardInteractive,
                           anyMessage),
              SshSessionError::kAuthFailedInteractive);
}

TEST(SshAuthUnitTest, AuthenticateRejectedWhenNotAuthenticating)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    {
        SshSession session(thread, {}, nullptr); // idle 态
        std::string password = "secret-material";
        EXPECT_FALSE(session.authenticatePassword(password, [](const AuthResult &) {}));
        // 未受理：调用方 buffer 原样保留（不清零）
        EXPECT_EQ(password, "secret-material");
        std::string key = "key-material";
        std::string pub; // 空公钥数据（未受理，内容无关紧要）
        std::string phrase = "phrase";
        EXPECT_FALSE(session.authenticatePublicKey(key, pub, phrase, [](const AuthResult &) {}));
        EXPECT_EQ(key, "key-material");
        EXPECT_FALSE(session.authenticateKeyboardInteractive(
            [](const std::vector<KbdIntPrompt> &) { return std::vector<std::string>{}; },
            [](const AuthResult &) {}));
        EXPECT_FALSE(session.queryAuthMethods([](std::optional<AuthMethodSet>) {}));
        thread.stop();
    }
}

// ================================================================== 集成（真实认证 sshd）

TEST(SshAuthIntegrationTest, MethodListProbeThenPasswordAuthSucceeds)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        // 方式探测：三种认证方式都应被服务端声明
        AuthMethodsBox methodsBox;
        ASSERT_TRUE(session.queryAuthMethods(std::ref(methodsBox)));
        ASSERT_TRUE(methodsBox.wait(10s));
        ASSERT_TRUE(methodsBox.methods().has_value());
        const AuthMethodSet methods = *methodsBox.methods();
        EXPECT_TRUE(methods.password) << methods.raw;
        EXPECT_TRUE(methods.publicKey) << methods.raw;
        EXPECT_TRUE(methods.keyboardInteractive) << methods.raw;
        EXPECT_NE(methods.raw.find("password"), std::string::npos);
        // 探测后会话仍停留 authenticating，可继续认证
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);

        // 密码认证连通 → established；受理后调用方 buffer 已清零
        std::string password = env.password;
        AuthResultBox box;
        ASSERT_TRUE(session.authenticatePassword(password, std::ref(box)));
        EXPECT_TRUE(password.empty()) << "受理后调用方密码 buffer 应已被清零";
        ASSERT_TRUE(box.wait(10s));
        ASSERT_TRUE(box.result()->success) << box.result()->message;
        EXPECT_EQ(box.result()->method, AuthMethod::kPassword);
        EXPECT_EQ(box.result()->error, SshSessionError::kNone);
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        EXPECT_EQ(session.lastError(), SshSessionError::kNone);

        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kEstablished,
                         SshSessionState::kClosing, SshSessionState::kClosed});
}

TEST(SshAuthIntegrationTest, WrongPasswordMapsToAuthFailedPasswordThenRetrySucceeds)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec)); // 默认 authMaxAttempts = 3
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        // 错误密码 → 明确错误码 kAuthFailedPassword，停留 authenticating 允许重试
        std::string wrong = "definitely-wrong-password";
        AuthResultBox box1;
        ASSERT_TRUE(session.authenticatePassword(wrong, std::ref(box1)));
        EXPECT_TRUE(wrong.empty());
        ASSERT_TRUE(box1.wait(10s));
        ASSERT_FALSE(box1.result()->success);
        EXPECT_EQ(box1.result()->error, SshSessionError::kAuthFailedPassword)
            << "意外错误码: " << sshclient::ssh::toString(box1.result()->error);
        EXPECT_EQ(box1.result()->attemptsLeft, 2u);
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);
        EXPECT_EQ(session.lastError(), SshSessionError::kAuthFailedPassword);

        // 重试正确密码 → 成功进 established，错误状态清零
        std::string password = env.password;
        AuthResultBox box2;
        ASSERT_TRUE(session.authenticatePassword(password, std::ref(box2)));
        EXPECT_TRUE(password.empty());
        ASSERT_TRUE(box2.wait(10s));
        ASSERT_TRUE(box2.result()->success) << box2.result()->message;
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        EXPECT_EQ(session.lastError(), SshSessionError::kNone);
        thread.stop();
    }
}

TEST(SshAuthIntegrationTest, ExhaustedAttemptsGoTerminalError)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.authMaxAttempts = 2; // 收紧上限，两次失败即终态
        SshSession session(thread, opts, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        std::string wrong1 = "wrong-password-1";
        AuthResultBox box1;
        ASSERT_TRUE(session.authenticatePassword(wrong1, std::ref(box1)));
        ASSERT_TRUE(box1.wait(10s));
        ASSERT_FALSE(box1.result()->success);
        EXPECT_EQ(box1.result()->attemptsLeft, 1u);
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);

        std::string wrong2 = "wrong-password-2";
        AuthResultBox box2;
        ASSERT_TRUE(session.authenticatePassword(wrong2, std::ref(box2)));
        ASSERT_TRUE(box2.wait(10s));
        ASSERT_FALSE(box2.result()->success);
        EXPECT_EQ(box2.result()->attemptsLeft, 0u);
        // 达到上限 → error 终态
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 5s));
        EXPECT_EQ(session.lastError(), SshSessionError::kAuthFailedPassword);
        // 终态后不再受理认证
        std::string pw = env.password;
        EXPECT_FALSE(session.authenticatePassword(pw, [](const AuthResult &) {}));
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kError});
}

TEST(SshAuthIntegrationTest, PublicKeyNoPassphraseSucceeds)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        std::string key = env.keyNoPassphrase;
        std::string pub = env.pubNoPassphrase;
        std::string phrase; // 空 = 无短语
        AuthResultBox box;
        ASSERT_TRUE(session.authenticatePublicKey(key, pub, phrase, std::ref(box)));
        EXPECT_TRUE(key.empty()) << "受理后调用方私钥 buffer 应已被清零";
        EXPECT_FALSE(pub.empty()) << "公钥非敏感，调用方 buffer 不清零";
        ASSERT_TRUE(box.wait(10s));
        ASSERT_TRUE(box.result()->success) << box.result()->message;
        EXPECT_EQ(box.result()->method, AuthMethod::kPublicKey);
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kEstablished});
}

TEST(SshAuthIntegrationTest, PublicKeyWithPassphraseSucceeds)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        std::string key = env.keyWithPassphrase;
        std::string pub = env.pubWithPassphrase;
        std::string phrase = env.passphrase;
        AuthResultBox box;
        ASSERT_TRUE(session.authenticatePublicKey(key, pub, phrase, std::ref(box)));
        EXPECT_TRUE(key.empty()) << "受理后调用方私钥 buffer 应已被清零";
        EXPECT_TRUE(phrase.empty()) << "受理后调用方短语 buffer 应已被清零";
        ASSERT_TRUE(box.wait(10s));
        ASSERT_TRUE(box.result()->success) << box.result()->message;
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        thread.stop();
    }
}

TEST(SshAuthIntegrationTest, PublicKeyWrongPassphraseMapsToPassphraseError)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        // 短语错误（显式提供公钥数据的推荐路径）：libssh2 在签名阶段本地解密私钥
        // 失败，1.11.1 实测返回 PUBLICKEY_UNVERIFIED「Callback returned error」
        // （真实 KEYFILE_AUTH_FAILED 被吞，见 auth.h 详注）→ kAuthFailedPassphrase；
        // 这是本地失败，未向服务器发出签名认证请求
        std::string key = env.keyWithPassphrase;
        std::string pub = env.pubWithPassphrase;
        std::string wrongPhrase = "definitely-wrong-passphrase";
        AuthResultBox box1;
        ASSERT_TRUE(session.authenticatePublicKey(key, pub, wrongPhrase, std::ref(box1)));
        ASSERT_TRUE(box1.wait(10s));
        ASSERT_FALSE(box1.result()->success);
        EXPECT_EQ(box1.result()->error, SshSessionError::kAuthFailedPassphrase)
            << "意外错误码: " << sshclient::ssh::toString(box1.result()->error)
            << "（" << box1.result()->message << "）";
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);

        // 换正确短语重试 → 成功
        std::string key2 = env.keyWithPassphrase;
        std::string pub2 = env.pubWithPassphrase;
        std::string phrase = env.passphrase;
        AuthResultBox box2;
        ASSERT_TRUE(session.authenticatePublicKey(key2, pub2, phrase, std::ref(box2)));
        ASSERT_TRUE(box2.wait(10s));
        ASSERT_TRUE(box2.result()->success) << box2.result()->message;
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        thread.stop();
    }
}

// libssh2 1.11.1 实测坑（钉住以防 pin 版本升级后行为漂移而未察觉）：
// 不提供公钥数据时，OpenSSH 格式私钥的短语错误在「从私钥提取公钥」阶段被吞，
// 退化为 LIBSSH2_ERROR_FILE（"Unsupported private key file format"）；
// 我们的映射把它归一化到 kAuthFailedPassphrase（本地私钥不可用，与 PEM 路径同码）
TEST(SshAuthIntegrationTest, PublicKeyWrongPassphraseWithoutPubkeyDataShowsLibssh2Quirk)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        std::string key = env.keyWithPassphrase;
        std::string noPub; // 空 = 让 libssh2 自行从私钥提取公钥
        std::string wrongPhrase = "definitely-wrong-passphrase";
        AuthResultBox box;
        ASSERT_TRUE(session.authenticatePublicKey(key, noPub, wrongPhrase, std::ref(box)));
        ASSERT_TRUE(box.wait(10s));
        ASSERT_FALSE(box.result()->success);
        EXPECT_EQ(box.result()->error, SshSessionError::kAuthFailedPassphrase)
            << "意外错误码: " << sshclient::ssh::toString(box.result()->error);
        EXPECT_NE(box.result()->message.find("Unsupported private key file format"),
                  std::string::npos)
            << "libssh2 行为已变化（pin 版本升级？），auth.h/mapAuthError 的注释需复核: "
            << box.result()->message;
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);
        thread.stop();
    }
}

TEST(SshAuthIntegrationTest, PublicKeyUnauthorizedMapsToKeyError)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    // 现成生成一把未授权的临时密钥（/tmp 下按 pid 唯一，不进仓库，用完即删）。
    // 不用 mkdtemp：-std=c++17 严格模式（__STRICT_ANSI__）下 glibc 不暴露其声明
    const std::string dir = std::string("/tmp/sshauthkey") + std::to_string(::getpid());
    ASSERT_EQ(::mkdir(dir.c_str(), 0700), 0);
    const std::string keyPath = dir + "/id_ed25519";
    pid_t pid = -1;
    const char *argv[] = {"ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f",
                          keyPath.c_str(), nullptr};
    ASSERT_EQ(::posix_spawnp(&pid, "ssh-keygen", nullptr, nullptr,
                            const_cast<char *const *>(argv), environ),
              0);
    int status = 0;
    ::waitpid(pid, &status, 0);
    ASSERT_TRUE(FileExists(keyPath));

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    bool ok = false;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        std::string key = ReadFileOrEmpty(keyPath);
        std::string pub = ReadFileOrEmpty(keyPath + ".pub");
        ASSERT_FALSE(key.empty());
        ASSERT_FALSE(pub.empty());
        std::string phrase;
        AuthResultBox box;
        ASSERT_TRUE(session.authenticatePublicKey(key, pub, phrase, std::ref(box)));
        ASSERT_TRUE(box.wait(10s));
        ASSERT_FALSE(box.result()->success);
        // 密钥合法但未在 authorized_keys → 服务器拒绝 → kAuthFailedKey
        EXPECT_EQ(box.result()->error, SshSessionError::kAuthFailedKey)
            << "意外错误码: " << sshclient::ssh::toString(box.result()->error)
            << "（" << box.result()->message << "）";
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);
        ok = true;
        thread.stop();
    }
    ::unlink(keyPath.c_str());
    ::unlink((keyPath + ".pub").c_str());
    ::rmdir(dir.c_str());
    ASSERT_TRUE(ok);
}

TEST(SshAuthIntegrationTest, KeyboardInteractiveFixedAnswerSucceeds)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        // 固定答案提供者：对每条 prompt 都回测试密码（PAM password 会话）；
        // 记录调用次数与 prompt 内容供断言（回调在事件循环线程执行，
        // 与断言线程之间经 AuthResultBox 的互斥锁同步，无数据竞争）
        int promptCalls = 0;
        std::vector<std::string> promptTexts;
        auto provider = [&](const std::vector<KbdIntPrompt> &prompts) {
            ++promptCalls;
            std::vector<std::string> answers;
            for (const auto &p : prompts) {
                promptTexts.push_back(p.text);
                answers.push_back(env.password);
            }
            return answers;
        };
        AuthResultBox box;
        ASSERT_TRUE(session.authenticateKeyboardInteractive(provider, std::ref(box)));
        ASSERT_TRUE(box.wait(10s));
        ASSERT_TRUE(box.result()->success) << box.result()->message;
        EXPECT_EQ(box.result()->method, AuthMethod::kKeyboardInteractive);
        EXPECT_GE(promptCalls, 1); // 服务端至少发了一轮 prompt（PAM "Password: "）
        ASSERT_TRUE(rec.waitFor(SshSessionState::kEstablished, 5s));
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kEstablished});
}

TEST(SshAuthIntegrationTest, KeyboardInteractiveWrongAnswerRejected)
{
    AuthTestEnv env;
    const bool loaded = LoadAuthTestEnv(&env);
    SkipIfNoAuthEnv(env, loaded);

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(ReachAuthenticating(session, rec, env));

        auto provider = [&](const std::vector<KbdIntPrompt> &prompts) {
            return std::vector<std::string>(prompts.size(), "definitely-wrong-answer");
        };
        AuthResultBox box;
        ASSERT_TRUE(session.authenticateKeyboardInteractive(provider, std::ref(box)));
        ASSERT_TRUE(box.wait(10s));
        ASSERT_FALSE(box.result()->success);
        EXPECT_EQ(box.result()->error, SshSessionError::kAuthFailedInteractive)
            << "意外错误码: " << sshclient::ssh::toString(box.result()->error);
        EXPECT_EQ(box.result()->attemptsLeft, 2u);
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);
        thread.stop();
    }
}
