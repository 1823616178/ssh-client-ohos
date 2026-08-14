#include "auth.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <utility>

#include <libssh2.h>
#include <openssl/crypto.h>

#include "../io/SessionThread.h"

// 与 session.cpp 同款：native 统一日志基建（hilog 封装）是后续任务，先落 stderr
#define SSH_LOG(...)                               \
    do {                                           \
        std::fprintf(stderr, "[ssh] " __VA_ARGS__); \
        std::fprintf(stderr, "\n");                \
    } while (0)

namespace sshclient {
namespace ssh {

// ---------------------------------------------------------------- 纯逻辑辅助

void secureZero(void *data, size_t len)
{
    if (data == nullptr || len == 0) {
        return;
    }
    // OPENSSL_cleanse：抗编译器优化的清零（选型理由见 auth.h 头注）
    OPENSSL_cleanse(data, len);
}

void secureZero(std::string &s)
{
    if (!s.empty()) {
        OPENSSL_cleanse(s.data(), s.size()); // C++17 起 data() 返回可写指针
    }
    s.clear();
}

AuthMethodSet parseAuthMethodList(const std::string &csv)
{
    AuthMethodSet set;
    set.raw = csv;
    size_t pos = 0;
    while (pos <= csv.size()) {
        const size_t comma = csv.find(',', pos);
        std::string item =
            csv.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
        // trim 首尾空白（sshd 通常不吐空格，宽容解析）
        const size_t begin = item.find_first_not_of(" \t\r\n");
        const size_t end = item.find_last_not_of(" \t\r\n");
        item = begin == std::string::npos ? "" : item.substr(begin, end - begin + 1);
        if (item.empty()) {
            // 跳过空项（含全空串输入）
        } else if (item == "password") {
            set.password = true;
        } else if (item == "publickey") {
            set.publicKey = true;
        } else if (item == "keyboard-interactive") {
            set.keyboardInteractive = true;
        } else {
            set.unsupported.push_back(item);
        }
        if (comma == std::string::npos) {
            break;
        }
        pos = comma + 1;
    }
    return set;
}

SshSessionError mapAuthError(int libssh2Error, AuthMethod method, const std::string &message)
{
    switch (method) {
    case AuthMethod::kPassword:
        // AUTHENTICATION_FAILED（密码错误/用户不存在）、PASSWORD_EXPIRED 等
        // 一律归密码认证失败（规则详表见 auth.h）
        return SshSessionError::kAuthFailedPassword;
    case AuthMethod::kPublicKey:
        // 私钥本地加载/解密失败（短语错误、短语缺失或私钥无法解析）的三条实际路径：
        if (libssh2Error == LIBSSH2_ERROR_KEYFILE_AUTH_FAILED) {
            return SshSessionError::kAuthFailedPassphrase; // PEM 私钥短语错误
        }
        if (libssh2Error == LIBSSH2_ERROR_FILE) {
            // 无公钥数据时的提取阶段失败（OpenSSH 加密私钥短语错误在此退化为
            // FILE「Unsupported private key file format」，见 auth.h 详注）
            return SshSessionError::kAuthFailedPassphrase;
        }
        if (libssh2Error == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED &&
            message.find("Callback returned error") != std::string::npos) {
            // 带公钥数据时签名阶段的本地解密失败被吞成 PUBLICKEY_UNVERIFIED
            // （userauth.c:1771）；同名错误码的服务端签名校验失败
            // （「Invalid signature for supplied public key...」）不在此列
            return SshSessionError::kAuthFailedPassphrase;
        }
        return SshSessionError::kAuthFailedKey;
    case AuthMethod::kKeyboardInteractive:
        return SshSessionError::kAuthFailedInteractive;
    }
    return SshSessionError::kInternal;
}

const char *toString(AuthMethod method)
{
    switch (method) {
    case AuthMethod::kPassword:            return "password";
    case AuthMethod::kPublicKey:           return "publickey";
    case AuthMethod::kKeyboardInteractive: return "keyboard-interactive";
    }
    return "unknown";
}

// ---------------------------------------------------------------- AuthOp（session.h 内嵌定义的析构）

SshSession::AuthOp::~AuthOp()
{
    // 用完即清：无论成功/失败/中止，凭据不残留在会话内存里
    // （publicKey 非敏感信息，同样一并清理以保持「认证材料不残留」的统一语义）
    secureZero(password);
    secureZero(privateKey);
    secureZero(publicKey);
    secureZero(passphrase);
}

// ---------------------------------------------------------------- 受理入口（任意线程）

bool SshSession::authenticatePassword(std::string &password, AuthCallback callback)
{
    if (state() != SshSessionState::kAuthenticating || !callback) {
        SSH_LOG("密码认证拒绝受理：状态 %s（仅 authenticating 可发起）", toString(state()));
        return false;
    }
    bool expected = false;
    if (!authBusy_.compare_exchange_strong(expected, true)) {
        SSH_LOG("密码认证拒绝受理：已有认证类操作进行中");
        return false;
    }
    auto op = std::make_unique<AuthOp>();
    op->method = AuthMethod::kPassword;
    op->password = password;
    op->callback = std::move(callback);
    // 受理即清零调用方 buffer：凭据已复制进会话内部状态，外部副本不再有用。
    // 内部副本由 AuthOp 析构（clearAuthState / releaseResources）负责清零。
    secureZero(password);
    // 交接槽写入与循环线程的读取经 post 互斥锁构成 happens-before（同 connect 惯例）
    authOpStaging_ = std::move(op);
    thread_.post([this] { beginAuthOp(); });
    return true;
}

bool SshSession::authenticatePublicKey(std::string &privateKeyData, std::string &publicKeyData,
                                       std::string &passphrase, AuthCallback callback)
{
    if (state() != SshSessionState::kAuthenticating || !callback || privateKeyData.empty()) {
        SSH_LOG("公钥认证拒绝受理：状态 %s", toString(state()));
        return false;
    }
    bool expected = false;
    if (!authBusy_.compare_exchange_strong(expected, true)) {
        SSH_LOG("公钥认证拒绝受理：已有认证类操作进行中");
        return false;
    }
    auto op = std::make_unique<AuthOp>();
    op->method = AuthMethod::kPublicKey;
    op->privateKey = privateKeyData;
    op->publicKey = publicKeyData;
    op->passphrase = passphrase;
    op->callback = std::move(callback);
    secureZero(privateKeyData); // 受理即清零调用方私钥/短语 buffer（公钥非敏感，不清零）
    secureZero(passphrase);
    authOpStaging_ = std::move(op);
    thread_.post([this] { beginAuthOp(); });
    return true;
}

bool SshSession::authenticateKeyboardInteractive(KbdIntResponseProvider provider,
                                                 AuthCallback callback)
{
    if (state() != SshSessionState::kAuthenticating || !callback || !provider) {
        SSH_LOG("keyboard-interactive 认证拒绝受理：状态 %s", toString(state()));
        return false;
    }
    bool expected = false;
    if (!authBusy_.compare_exchange_strong(expected, true)) {
        SSH_LOG("keyboard-interactive 认证拒绝受理：已有认证类操作进行中");
        return false;
    }
    auto op = std::make_unique<AuthOp>();
    op->method = AuthMethod::kKeyboardInteractive;
    op->provider = std::move(provider);
    op->callback = std::move(callback);
    // 应答材料此时还没产生（provider 在 libssh2 回调内才被调用），
    // 应答串用完后在 onKbdIntPrompts 内清零
    authOpStaging_ = std::move(op);
    thread_.post([this] { beginAuthOp(); });
    return true;
}

bool SshSession::queryAuthMethods(AuthMethodsCallback callback)
{
    if (state() != SshSessionState::kAuthenticating || !callback) {
        SSH_LOG("认证方式探测拒绝受理：状态 %s", toString(state()));
        return false;
    }
    bool expected = false;
    if (!authBusy_.compare_exchange_strong(expected, true)) {
        SSH_LOG("认证方式探测拒绝受理：已有认证类操作进行中");
        return false;
    }
    // AuthMethodsCallback（std::function）可复制，直接随任务捕获
    thread_.post([this, callback = std::move(callback)]() mutable {
        beginAuthMethodsQuery(std::move(callback));
    });
    return true;
}

// ---------------------------------------------------------------- 装配与驱动（循环线程）

void SshSession::beginAuthOp()
{
    std::unique_ptr<AuthOp> op = std::move(authOpStaging_);
    authOpStaging_ = nullptr;
    if (op == nullptr) {
        authBusy_.store(false, std::memory_order_release); // 防御：不应发生
        return;
    }
    if (state() != SshSessionState::kAuthenticating || authOp_ != nullptr) {
        // 受理后状态竞态变化（如对端断开/前一次操作未清场）：回报失败并释放受理位
        authBusy_.store(false, std::memory_order_release);
        if (op->callback) {
            op->callback(AuthResult{op->method, false, SshSessionError::kInternal,
                                    "会话已离开待认证状态", 0});
        }
        return; // op 析构清零凭据
    }
    authOp_ = std::move(op);
    authOp_->timer = thread_.loop().runAfter(options_.authTimeoutMs, [this] {
        // 单次尝试超时：15 s 无应答通常是链路异常，重试同一凭据无益，按终态处理
        if (authOp_ != nullptr && state() == SshSessionState::kAuthenticating) {
            failWith(SshSessionError::kAuthTimeout, "认证尝试超时（authTimeoutMs）");
        }
    });
    driveAuth();
}

void SshSession::driveAuth()
{
    AuthOp *op = authOp_.get();
    if (op == nullptr) {
        return;
    }

    int rc = LIBSSH2_ERROR_INVAL;
    switch (op->method) {
    case AuthMethod::kPassword:
        rc = ::libssh2_userauth_password_ex(
            session_, username_.c_str(), static_cast<unsigned int>(username_.size()),
            op->password.data(), static_cast<unsigned int>(op->password.size()), nullptr);
        break;
    case AuthMethod::kPublicKey:
        // 公钥数据显式传入（推荐路径）：跳过 libssh2 的「从私钥提取公钥」阶段，
        // 少一次私钥解密；两条路径的短语错误原始码不同（提取阶段退化为 FILE、
        // 签名阶段被吞成 PUBLICKEY_UNVERIFIED「Callback returned error」），
        // 均由 mapAuthError 归一化为 kAuthFailedPassphrase（见 auth.h 详注）。
        // 私钥/短语在 EAGAIN 续跑期间一直驻留在 AuthOp（libssh2 每次调用重新取参，
        // 不跨调用持有指针），结论得出后由 clearAuthState 清零
        rc = ::libssh2_userauth_publickey_frommemory(
            session_, username_.c_str(), username_.size(),
            op->publicKey.empty() ? nullptr : op->publicKey.data(), op->publicKey.size(),
            op->privateKey.data(), op->privateKey.size(),
            op->passphrase.empty() ? nullptr : op->passphrase.c_str());
        break;
    case AuthMethod::kKeyboardInteractive:
        rc = ::libssh2_userauth_keyboard_interactive_ex(
            session_, username_.c_str(), static_cast<unsigned int>(username_.size()),
            &SshSession::kbdIntResponseCb);
        break;
    }
    if (rc == LIBSSH2_ERROR_EAGAIN) {
        updateFdInterest(); // 按 libssh2 声明的阻塞方向重挂事件，事件到来续跑
        return;
    }

    // 尝试有了结论：先把回调与方式取出来（clearAuthState 会连回调一起释放）
    const AuthMethod method = op->method;
    AuthCallback callback = std::move(op->callback);

    if (rc == 0) {
        clearAuthState(); // 清零凭据、摘定时器、释放受理位
        authFailedAttempts_ = 0;
        {
            std::lock_guard<std::mutex> lock(errorMutex_);
            error_ = SshSessionError::kNone;
            errorMessage_.clear();
        }
        transitionTo(SshSessionState::kEstablished);
        if (callback) {
            callback(AuthResult{method, true, SshSessionError::kNone, "",
                                options_.authMaxAttempts});
        }
        return;
    }

    char *errmsg = nullptr;
    int errmsgLen = 0;
    ::libssh2_session_last_error(session_, &errmsg, &errmsgLen, 0);
    const std::string message =
        errmsg != nullptr ? std::string(errmsg, errmsgLen) : std::string("未知错误");
    const SshSessionError code = mapAuthError(rc, method, message);

    clearAuthState();
    ++authFailedAttempts_;
    const unsigned left = options_.authMaxAttempts > authFailedAttempts_
                              ? options_.authMaxAttempts - authFailedAttempts_
                              : 0;
    SSH_LOG("认证失败（方式 %s，错误码 %s）：%s（剩余可重试 %u）", toString(method),
            toString(code), message.c_str(), left);
    {
        // 非终态失败也同步到 lastError()（参照 kHostKeyMismatch 惯例），
        // 供上层在 AuthCallback 之外轮询最近一次失败原因
        std::lock_guard<std::mutex> lock(errorMutex_);
        error_ = code;
        errorMessage_ = message;
    }
    if (left == 0) {
        failWith(code, std::string("认证失败次数达到上限（") + toString(method) +
                           "）: " + message); // → error 终态
    }
    if (callback) {
        callback(AuthResult{method, false, code, message, left});
    }
}

// ---------------------------------------------------------------- 方式探测（循环线程）

void SshSession::beginAuthMethodsQuery(AuthMethodsCallback callback)
{
    if (state() != SshSessionState::kAuthenticating || authOp_ != nullptr ||
        authMethodsCallback_) {
        // 受理后状态竞态变化：回报失败并释放受理位
        authBusy_.store(false, std::memory_order_release);
        if (callback) {
            callback(std::nullopt);
        }
        return;
    }
    authMethodsCallback_ = std::move(callback);
    authMethodsTimer_ = thread_.loop().runAfter(options_.authTimeoutMs, [this] {
        if (authMethodsCallback_ && state() == SshSessionState::kAuthenticating) {
            failWith(SshSessionError::kAuthTimeout, "认证方式探测超时（authTimeoutMs）");
        }
    });
    driveAuthMethodsQuery();
}

void SshSession::driveAuthMethodsQuery()
{
    if (!authMethodsCallback_) {
        return;
    }
    // userauth_list 内部发 "none" 方式请求，从服务器的失败应答里取支持方式列表
    char *list = ::libssh2_userauth_list(session_, username_.c_str(),
                                         static_cast<unsigned int>(username_.size()));
    if (list == nullptr) {
        if (::libssh2_session_last_errno(session_) == LIBSSH2_ERROR_EAGAIN) {
            updateFdInterest();
            return;
        }
        char *errmsg = nullptr;
        int errmsgLen = 0;
        ::libssh2_session_last_error(session_, &errmsg, &errmsgLen, 0);
        SSH_LOG("认证方式探测失败：%s",
                errmsg != nullptr ? std::string(errmsg, errmsgLen).c_str() : "未知错误");
        finishAuthMethodsQuery(std::nullopt);
        return;
    }
    // 返回缓冲区归 libssh2 所有（下次 userauth 调用即失效），立即复制解析
    finishAuthMethodsQuery(parseAuthMethodList(list));
}

void SshSession::finishAuthMethodsQuery(std::optional<AuthMethodSet> result)
{
    AuthMethodsCallback callback = std::move(authMethodsCallback_);
    authMethodsCallback_ = nullptr;
    if (authMethodsTimer_ != 0) {
        thread_.loop().cancelTimer(authMethodsTimer_);
        authMethodsTimer_ = 0;
    }
    authBusy_.store(false, std::memory_order_release);
    if (callback) {
        callback(std::move(result));
    }
}

// ---------------------------------------------------------------- keyboard-interactive 应答桥

void SshSession::kbdIntResponseCb(const char *name, int nameLen, const char *instruction,
                                  int instructionLen, int numPrompts,
                                  const _LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                                  _LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
                                  void **abstract)
{
    (void)name;
    (void)nameLen;
    (void)instruction;
    (void)instructionLen;
    // abstract 即 beginHandshake 时 libssh2_session_init_ex 传入的 this
    auto *self = static_cast<SshSession *>(abstract != nullptr ? *abstract : nullptr);
    if (self == nullptr) {
        return; // 防御：responses 已由 libssh2 零初始化，空应答导致认证失败
    }
    self->onKbdIntPrompts(numPrompts, prompts, responses);
}

void SshSession::onKbdIntPrompts(int numPrompts, const _LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                                 _LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses)
{
    // libssh2 在回调返回后用自己的分配器 free 掉每条 responses[i].text（见
    // libssh2.h 注释 "Responses data will be freed by libssh2 after callback
    // return"）；本项目未自定义分配器，默认即 malloc/free，故此处用 malloc 配对。
    // 若日后 libssh2_session_init_ex 注入自定义分配器，此处必须改用同款。
    auto fillResponse = [&](int i, const char *data, size_t len) {
        char *buf = static_cast<char *>(std::malloc(len + 1));
        if (buf != nullptr) {
            if (len > 0) {
                std::memcpy(buf, data, len);
            }
            buf[len] = '\0';
        }
        responses[i].text = buf;
        responses[i].length = static_cast<unsigned int>(len);
    };

    AuthOp *op = authOp_.get();
    if (op == nullptr || op->method != AuthMethod::kKeyboardInteractive || !op->provider) {
        // 防御（正常路径不会到达：只有 kbdint 尝试才会注册本回调）：
        // 空应答让服务器干脆地拒绝，而不是挂起等输入
        for (int i = 0; i < numPrompts; ++i) {
            fillResponse(i, "", 0);
        }
        return;
    }

    std::vector<KbdIntPrompt> promptList;
    promptList.reserve(static_cast<size_t>(numPrompts));
    for (int i = 0; i < numPrompts; ++i) {
        KbdIntPrompt p;
        if (prompts[i].text != nullptr && prompts[i].length > 0) {
            p.text.assign(reinterpret_cast<const char *>(prompts[i].text), prompts[i].length);
        }
        p.echo = prompts[i].echo != 0;
        promptList.push_back(std::move(p));
    }

    // 同步调用注入的应答提供者（事件循环线程内，契约：快速返回，见 session.h）。
    // 异常必须拦在本 TU：回调穿行在 libssh2 的 C 帧中，让 C++ 异常跨 C 帧传播
    // 是未定义行为——provider 抛异常按空应答处理（认证失败），不拖垮事件循环
    std::vector<std::string> answers;
    try {
        answers = op->provider(promptList);
    } catch (...) {
        answers.clear();
    }
    for (int i = 0; i < numPrompts; ++i) {
        if (static_cast<size_t>(i) < answers.size()) {
            fillResponse(i, answers[i].data(), answers[i].size());
        } else {
            fillResponse(i, "", 0); // 应答条数不足：空串兜底（通常导致认证失败）
        }
    }
    for (auto &answer : answers) {
        secureZero(answer); // 应答（常即密码/OTP）复制给 libssh2 后立即清零本地副本
    }
}

// ---------------------------------------------------------------- 清场（循环线程）

void SshSession::clearAuthState()
{
    if (authOp_ != nullptr) {
        if (authOp_->timer != 0) {
            thread_.loop().cancelTimer(authOp_->timer);
            authOp_->timer = 0;
        }
        authOp_.reset(); // AuthOp 析构清零密码/私钥/短语副本
    }
    if (authMethodsTimer_ != 0) {
        thread_.loop().cancelTimer(authMethodsTimer_);
        authMethodsTimer_ = 0;
    }
    authMethodsCallback_ = nullptr;
    authBusy_.store(false, std::memory_order_release);
}

} // namespace ssh
} // namespace sshclient
