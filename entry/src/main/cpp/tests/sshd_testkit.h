/**
 * 集成测试共享辅助 —— N6 从 ssh_session_test.cpp 抽出，供 N6/N7/N8/N9 等测试文件共用。
 *
 * 内容：
 *   - StateRecorder / ExpectSequence：状态迁移记录与按序断言；
 *   - AuthResultBox：认证回调结果收集与等待（N8）；
 *   - PickFreePort / FileExists：小工具；
 *   - sshd 生命周期：FindSshd / SshdRuntimeDir / PrepareSshdRuntime /
 *     SshdLdLibraryPath / StartSshd / StopSshd / RequireSshd；
 *   - 认证测试环境：AuthTestEnv / LoadAuthTestEnv / ReachAuthenticating /
 *     SkipIfNoAuthEnv（N8 认证 sshd 产物读取，N9 agent 测试同用）。
 *
 * sshd 来源（按优先级）：环境变量 SSH_TESTS_SSHD 指定的二进制 →
 * scripts/setup-host-deps.sh 解包产物（免 root）→ 系统 /usr/sbin/sshd。
 * 每个集成用例用 `sshd -d`（单连接调试模式，不 fork、处理一条连接后退出）
 * 起独立实例在 127.0.0.1 空闲高端口，用例间互不影响。
 *
 * 本头文件全部内容置于匿名命名空间：每个包含它的测试 TU 各持一份副本，
 * 链接同一测试二进制时无 ODR 冲突。
 */
#pragma once

#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <netdb.h>
#include <spawn.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "ssh/session.h"

using namespace std::chrono_literals;

extern char **environ;

namespace {

// ---------------------------------------------------------------- 状态记录器

class StateRecorder {
public:
    // 直接可转 std::function 的回调入口（在事件循环线程执行）
    void operator()(sshclient::ssh::SshSessionState from, sshclient::ssh::SshSessionState to)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            transitions_.emplace_back(from, to);
        }
        cv_.notify_all();
    }

    bool waitFor(sshclient::ssh::SshSessionState target, std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] {
            return !transitions_.empty() && transitions_.back().second == target;
        });
    }

    // 迁移序列里所有「目标态」的有序快照（用于断言回调顺序）
    std::vector<sshclient::ssh::SshSessionState> toSequence() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<sshclient::ssh::SshSessionState> seq;
        seq.reserve(transitions_.size());
        for (const auto &t : transitions_) {
            seq.push_back(t.second);
        }
        return seq;
    }

    // 迁移序列是否到达过某状态（无论是否终态；用于「从未进入 authenticating」断言）
    bool visited(sshclient::ssh::SshSessionState target) const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto &t : transitions_) {
            if (t.second == target) {
                return true;
            }
        }
        return false;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<std::pair<sshclient::ssh::SshSessionState, sshclient::ssh::SshSessionState>>
        transitions_;
};

// ---------------------------------------------------------------- 认证结果收集器

// N8 起供认证类集成用例使用：收集 AuthCallback 结果并等待（回调在事件循环线程
// 执行，与断言线程经互斥锁同步）
class AuthResultBox {
public:
    // 直接可转 AuthCallback（在事件循环线程执行）
    void operator()(const sshclient::ssh::AuthResult &result)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            result_ = result;
        }
        cv_.notify_all();
    }

    bool wait(std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] { return result_.has_value(); });
    }

    std::optional<sshclient::ssh::AuthResult> result() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        return result_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::optional<sshclient::ssh::AuthResult> result_;
};

// ---------------------------------------------------------------- 小工具

// 拿一个 127.0.0.1 上的空闲端口（bind:0 → getsockname → close；竞态窗口本地可忽略）
uint16_t PickFreePort()
{
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }
    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    uint16_t port = 0;
    if (::bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) == 0) {
        socklen_t len = sizeof(addr);
        if (::getsockname(fd, reinterpret_cast<struct sockaddr *>(&addr), &len) == 0) {
            port = ntohs(addr.sin_port);
        }
    }
    ::close(fd);
    return port;
}

bool FileExists(const std::string &path)
{
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0;
}

// ---------------------------------------------------------------- sshd 集成辅助

struct SshdInstance {
    pid_t pid = -1;
    uint16_t port = 0;
    std::string logPath;
};

// 定位 sshd 二进制；找不到返回空串
std::string FindSshd()
{
    const char *env = std::getenv("SSH_TESTS_SSHD");
    std::vector<std::string> candidates;
    if (env != nullptr && env[0] != '\0') {
        candidates.emplace_back(env);
    }
    const char *home = std::getenv("HOME");
    if (home != nullptr) {
        candidates.emplace_back(std::string(home) +
                                "/ohos-probe/build/host-deps/sshd/rootfs/usr/sbin/sshd");
    }
    candidates.emplace_back("/usr/sbin/sshd");
    for (const auto &path : candidates) {
        struct stat st {};
        if (::stat(path.c_str(), &st) == 0 && (st.st_mode & S_IXUSR) != 0) {
            return path;
        }
    }
    return "";
}

// sshd 运行时目录（host key、配置、日志）：优先环境变量，默认 setup-host-deps.sh 产物目录
std::string SshdRuntimeDir()
{
    const char *env = std::getenv("SSH_TESTS_SSHD_RUNTIME");
    if (env != nullptr && env[0] != '\0') {
        return env;
    }
    const char *home = std::getenv("HOME");
    if (home == nullptr) {
        return "";
    }
    return std::string(home) + "/ohos-probe/build/host-deps/sshd/runtime";
}

// 确保运行时目录可用（host key 缺失则现生成；配置缺失则按 setup-host-deps.sh 同款写一份）。
// 返回 false 表示准备失败（调用方 GTEST_SKIP）。
bool PrepareSshdRuntime(const std::string &rt)
{
    if (rt.empty()) {
        return false;
    }
    ::mkdir(rt.c_str(), 0700);
    const std::string ed25519 = rt + "/ssh_host_ed25519_key";
    if (!FileExists(ed25519)) {
        // ssh-keygen -t ed25519 -N '' -f <key>
        pid_t pid = -1;
        const char *argv[] = {"ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f",
                              ed25519.c_str(), nullptr};
        if (::posix_spawnp(&pid, "ssh-keygen", nullptr, nullptr,
                           const_cast<char *const *>(argv), environ) != 0) {
            return false;
        }
        int status = 0;
        ::waitpid(pid, &status, 0);
        if (!FileExists(ed25519)) {
            return false;
        }
    }
    const std::string config = rt + "/sshd_config";
    if (!FileExists(config)) {
        FILE *f = std::fopen(config.c_str(), "w");
        if (f == nullptr) {
            return false;
        }
        // 与 scripts/setup-host-deps.sh 生成的配置保持一致（免 root 可跑的关键项）
        std::fprintf(f,
                     "ListenAddress 127.0.0.1\n"
                     "HostKey %s/ssh_host_ed25519_key\n"
                     "UsePAM no\n"
                     "StrictModes no\n"
                     "PasswordAuthentication yes\n"
                     "PubkeyAuthentication yes\n"
                     "X11Forwarding no\n"
                     "PrintMotd no\n"
                     "LogLevel VERBOSE\n",
                     rt.c_str());
        std::fclose(f);
    }
    return true;
}

// 拼 LD_LIBRARY_PATH：免 root 解包的 sshd 依赖 rootfs 内的私有库（libwrap 等）
std::string SshdLdLibraryPath(const std::string &sshdPath)
{
    // <rootfs>/usr/sbin/sshd → <rootfs>
    const std::string marker = "/usr/sbin/sshd";
    const auto pos = sshdPath.rfind(marker);
    if (pos == std::string::npos) {
        return "";
    }
    const std::string rootfs = sshdPath.substr(0, pos);
    std::string result;
    for (const char *sub : {"/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu",
                            "/lib/aarch64-linux-gnu", "/usr/lib/aarch64-linux-gnu"}) {
        if (FileExists(rootfs + sub)) {
            if (!result.empty()) {
                result += ':';
            }
            result += rootfs + sub;
        }
    }
    return result;
}

// 以 `sshd -d`（单连接调试模式）起一个实例；失败返回 pid=-1
SshdInstance StartSshd(const std::string &sshdPath, const std::string &rt);

void StopSshd(SshdInstance &inst)
{
    if (inst.pid <= 0) {
        return;
    }
    // 按进程组杀：sshd -d 对接受的连接会 re-exec 出子进程，只杀监听进程杀不干净
    ::kill(-inst.pid, SIGTERM);
    // sshd -d 处理完一条连接会自行退出；SIGTERM 不奏效再补 SIGKILL
    for (int i = 0; i < 40; ++i) {
        int status = 0;
        if (::waitpid(inst.pid, &status, WNOHANG) == inst.pid) {
            inst.pid = -1;
            return;
        }
        std::this_thread::sleep_for(25ms);
    }
    ::kill(-inst.pid, SIGKILL);
    ::waitpid(inst.pid, nullptr, 0);
    inst.pid = -1;
}

SshdInstance StartSshd(const std::string &sshdPath, const std::string &rt)
{
    SshdInstance inst;
    inst.port = PickFreePort();
    if (inst.port == 0) {
        return inst;
    }
    inst.logPath = rt + "/sshd-" + std::to_string(inst.port) + ".log";

    const std::string portStr = std::to_string(inst.port);
    const std::string configPath = rt + "/sshd_config";

    // 复制 environ 并覆盖/追加 LD_LIBRARY_PATH（解包 sshd 的私有库目录）
    std::vector<std::string> envStrings;
    const std::string ldPath = SshdLdLibraryPath(sshdPath);
    bool ldSeen = false;
    for (char **e = environ; e != nullptr && *e != nullptr; ++e) {
        std::string entry = *e;
        if (entry.rfind("LD_LIBRARY_PATH=", 0) == 0) {
            ldSeen = true;
            if (!ldPath.empty()) {
                entry += ':' + ldPath;
            }
        }
        envStrings.push_back(std::move(entry));
    }
    if (!ldSeen && !ldPath.empty()) {
        envStrings.push_back("LD_LIBRARY_PATH=" + ldPath);
    }
    std::vector<char *> argv = {const_cast<char *>(sshdPath.c_str()),
                                const_cast<char *>("-d"),
                                const_cast<char *>("-p"),
                                const_cast<char *>(portStr.c_str()),
                                const_cast<char *>("-f"),
                                const_cast<char *>(configPath.c_str()),
                                const_cast<char *>("-E"),
                                const_cast<char *>(inst.logPath.c_str()),
                                nullptr};
    std::vector<char *> envp;
    envp.reserve(envStrings.size() + 1);
    for (auto &s : envStrings) {
        envp.push_back(s.data());
    }
    envp.push_back(nullptr);

    // fork + setsid + execve（不用 posix_spawn：setsid 旗标是 GNU 扩展，
    // -std=c++17 严格模式下 glibc 不暴露；fork 与 exec 之间只用 async-signal-safe 调用）
    inst.pid = ::fork();
    if (inst.pid == 0) {
        ::setsid();
        ::execve(sshdPath.c_str(), argv.data(), envp.data());
        ::_exit(127); // exec 失败
    }
    if (inst.pid < 0) {
        return inst;
    }

    // 等日志出现 "Server listening on"（sshd -d 就绪标志）；进程早退则失败
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (std::chrono::steady_clock::now() < deadline) {
        FILE *f = std::fopen(inst.logPath.c_str(), "r");
        if (f != nullptr) {
            char line[256];
            while (std::fgets(line, sizeof(line), f) != nullptr) {
                if (std::strstr(line, "Server listening on") != nullptr) {
                    std::fclose(f);
                    return inst;
                }
            }
            std::fclose(f);
        }
        int status = 0;
        if (::waitpid(inst.pid, &status, WNOHANG) == inst.pid) {
            inst.pid = -1; // 已退出：端口被抢/配置错误等
            return inst;
        }
        std::this_thread::sleep_for(50ms);
    }
    StopSshd(inst);
    inst.pid = -1;
    return inst;
}

// 集成测试环境探测：返回空串表示不可用（用例 GTEST_SKIP）
std::string RequireSshd(std::string *rtOut)
{
#ifndef SSH_TESTS_INTEGRATION
    (void)rtOut;
    return "";
#else
    const std::string sshd = FindSshd();
    if (sshd.empty()) {
        return "";
    }
    const std::string rt = SshdRuntimeDir();
    if (!PrepareSshdRuntime(rt)) {
        return "";
    }
    *rtOut = rt;
    return sshd;
#endif
}

// ---------------------------------------------------------------- 认证测试环境定位（N8 起）

// 认证 sshd 环境（root 常驻，UsePAM yes）：由 scripts/setup-host-deps.sh 准备，
// 材料在 $HOME/ohos-probe/build/host-deps/auth/（端口/测试用户/随机密码/密钥对；
// 密码与私钥绝不进 git 仓库）。环境变量可覆盖：SSH_TEST_AUTH_DIR /
// SSH_TEST_AUTH_PORT / SSH_TEST_USER / SSH_TEST_PASSWORD / SSH_TEST_KEY_PASSPHRASE。
struct AuthTestEnv {
    uint16_t port = 0;
    std::string user;
    std::string password;        // 测试用户密码（随机串，来自 auth/test-password）
    std::string passphrase;      // 私钥短语（随机串，来自 auth/key-passphrase）
    std::string keyNoPassphrase; // 不带短语的 ed25519 私钥字节
    std::string keyWithPassphrase; // 带短语的 ed25519 私钥字节
    std::string pubNoPassphrase;   // 对应 .pub 公钥文本
    std::string pubWithPassphrase;
};

std::string ReadFileOrEmpty(const std::string &path)
{
    FILE *f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) {
        return "";
    }
    std::string content;
    char buf[4096];
    size_t n = 0;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) {
        content.append(buf, n);
    }
    std::fclose(f);
    return content;
}

// 密码/短语文件容差处理：剥掉尾部空白/换行（手写或编辑器保存时可能带 \n）
std::string TrimTail(const std::string &s)
{
    const size_t end = s.find_last_not_of(" \t\r\n");
    return end == std::string::npos ? "" : s.substr(0, end + 1);
}

// 加载认证测试环境：环境变量优先，默认 setup-host-deps.sh 的 auth/ 产物目录；
// 缺一即返回 false（调用方 GTEST_SKIP）。并对端口做一次 TCP 探测确认 daemon 存活。
bool LoadAuthTestEnv(AuthTestEnv *out)
{
#ifndef SSH_TESTS_INTEGRATION
    (void)out;
    return false;
#else
    const char *home = std::getenv("HOME");
    const char *dirEnv = std::getenv("SSH_TEST_AUTH_DIR");
    std::string dir;
    if (dirEnv != nullptr && dirEnv[0] != '\0') {
        dir = dirEnv;
    } else if (home != nullptr) {
        dir = std::string(home) + "/ohos-probe/build/host-deps/auth";
    } else {
        return false;
    }

    const char *portEnv = std::getenv("SSH_TEST_AUTH_PORT");
    const std::string portStr =
        portEnv != nullptr && portEnv[0] != '\0' ? portEnv : TrimTail(ReadFileOrEmpty(dir + "/port"));
    if (portStr.empty()) {
        return false;
    }
    out->port = static_cast<uint16_t>(std::atoi(portStr.c_str()));
    if (out->port == 0) {
        return false;
    }

    const char *userEnv = std::getenv("SSH_TEST_USER");
    out->user = userEnv != nullptr && userEnv[0] != '\0'
                    ? userEnv
                    : TrimTail(ReadFileOrEmpty(dir + "/test-user"));
    const char *passEnv = std::getenv("SSH_TEST_PASSWORD");
    out->password = passEnv != nullptr && passEnv[0] != '\0'
                        ? passEnv
                        : TrimTail(ReadFileOrEmpty(dir + "/test-password"));
    const char *phraseEnv = std::getenv("SSH_TEST_KEY_PASSPHRASE");
    out->passphrase = phraseEnv != nullptr && phraseEnv[0] != '\0'
                          ? phraseEnv
                          : TrimTail(ReadFileOrEmpty(dir + "/key-passphrase"));
    out->keyNoPassphrase = ReadFileOrEmpty(dir + "/id_ed25519");
    out->keyWithPassphrase = ReadFileOrEmpty(dir + "/id_ed25519_pass");
    out->pubNoPassphrase = ReadFileOrEmpty(dir + "/id_ed25519.pub");
    out->pubWithPassphrase = ReadFileOrEmpty(dir + "/id_ed25519_pass.pub");

    if (out->user.empty() || out->password.empty() || out->passphrase.empty() ||
        out->keyNoPassphrase.empty() || out->keyWithPassphrase.empty() ||
        out->pubNoPassphrase.empty() || out->pubWithPassphrase.empty()) {
        return false;
    }

    // TCP 探测：daemon 挂掉时尽早 GTEST_SKIP 而不是逐个用例超时
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return false;
    }
    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(out->port);
    const bool ok = ::connect(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) == 0;
    ::close(fd);
    return ok;
#endif
}

// 连接并驱动到 authenticating；超时/失败返回 false（调用方 ASSERT）
bool ReachAuthenticating(sshclient::ssh::SshSession &session, StateRecorder &rec,
                         const AuthTestEnv &env)
{
    return session.connect("127.0.0.1", env.port, env.user) &&
           rec.waitFor(sshclient::ssh::SshSessionState::kAuthenticating, 20s);
}

// 连接 + 密码认证驱动到 established（N10 起通道测试用）；超时/失败返回 false
bool ReachEstablished(sshclient::ssh::SshSession &session, StateRecorder &rec,
                      const AuthTestEnv &env)
{
    if (!ReachAuthenticating(session, rec, env)) {
        return false;
    }
    AuthResultBox box;
    std::string password = env.password; // 受理即清零，须用副本
    return session.authenticatePassword(password, std::ref(box)) && box.wait(10s) &&
           box.result().has_value() && box.result()->success &&
           rec.waitFor(sshclient::ssh::SshSessionState::kEstablished, 5s);
}

void SkipIfNoAuthEnv(const AuthTestEnv &env, bool loaded)
{
    if (!loaded) {
        GTEST_SKIP() << "认证测试环境未就绪（跑 scripts/setup-host-deps.sh；"
                        "无 root/WSL 时本用例按约定跳过）";
    }
    (void)env;
}

// 按序比较辅助
void ExpectSequence(
    const StateRecorder &rec,
    std::vector<sshclient::ssh::SshSessionState> expected)
{
    EXPECT_EQ(rec.toSequence(), std::move(expected));
}

} // namespace
