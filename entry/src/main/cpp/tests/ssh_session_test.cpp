/**
 * SshSession 单测与集成测试 —— 任务 N6「会话生命周期与状态机」。
 *
 * 覆盖：
 *   状态机（不需要真实服务器）：
 *     - 迁移合法性表（isLegalTransition 静态校验）
 *     - 非法迁移拒绝：idle 态 close 空操作、非 idle 重复 connect 被拒
 *     - 回调按序触发：连关闭端口 → idle→connecting→error
 *     - 连接超时机制：连 RFC 5737 黑洞地址（192.0.2.x），connectTimeout 内收敛到 error
 *     - 握手超时 / 垃圾 banner：本地哑服务器（accept 后沉默 / 发垃圾字节）
 *   集成（SSH_TESTS_INTEGRATION 且找到 sshd 时；否则 GTEST_SKIP）：
 *     - 完整握手到「待认证」（authenticating）边界
 *     - 优雅关闭：authenticating→closing→closed
 *     - 断线检测：kill 掉辅助 sshd 进程（模拟「拔线/RST」——被 kill 进程的
 *        socket 由内核 RST），断言 30 s 内进入 disconnected（实测秒级以内）
 *
 * sshd 来源（按优先级）：环境变量 SSH_TESTS_SSHD 指定的二进制 →
 * scripts/setup-host-deps.sh 解包产物（免 root）→ 系统 /usr/sbin/sshd。
 * 每个集成用例用 `sshd -d`（单连接调试模式，不 fork、处理一条连接后退出）
 * 起独立实例在 127.0.0.1 空闲高端口，用例间互不影响。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <spawn.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "io/SessionThread.h"
#include "ssh/session.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionError;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;

extern char **environ;

namespace {

// ---------------------------------------------------------------- 状态记录器

class StateRecorder {
public:
    // 直接可转 std::function 的回调入口（在事件循环线程执行）
    void operator()(SshSessionState from, SshSessionState to)
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            transitions_.emplace_back(from, to);
        }
        cv_.notify_all();
    }

    bool waitFor(SshSessionState target, std::chrono::milliseconds timeout)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [&] {
            return !transitions_.empty() && transitions_.back().second == target;
        });
    }

    // 迁移序列里所有「目标态」的有序快照（用于断言回调顺序）
    std::vector<SshSessionState> toSequence() const
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<SshSessionState> seq;
        seq.reserve(transitions_.size());
        for (const auto &t : transitions_) {
            seq.push_back(t.second);
        }
        return seq;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::vector<std::pair<SshSessionState, SshSessionState>> transitions_;
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

// 哑 TCP 服务器：accept 后按构造参数发一段字节（空 = 一字节不发，保持沉默），
// 随后保持连接直到对端关闭或 stop()。用于握手超时 / 垃圾 banner 用例。
class DeadEndServer {
public:
    explicit DeadEndServer(std::string payload) : payload_(std::move(payload)) {}
    ~DeadEndServer() { stop(); }

    bool start()
    {
        listenFd_ = ::socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd_ < 0) {
            return false;
        }
        int one = 1;
        ::setsockopt(listenFd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr {};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        if (::bind(listenFd_, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0 ||
            ::listen(listenFd_, 4) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }
        socklen_t len = sizeof(addr);
        if (::getsockname(listenFd_, reinterpret_cast<struct sockaddr *>(&addr), &len) != 0) {
            ::close(listenFd_);
            listenFd_ = -1;
            return false;
        }
        port_ = ntohs(addr.sin_port);
        thread_ = std::thread([this] { serve(); });
        return true;
    }

    uint16_t port() const { return port_; }

    void stop()
    {
        if (listenFd_ < 0 && !thread_.joinable()) {
            return;
        }
        stop_ = true;
        if (listenFd_ >= 0) {
            ::shutdown(listenFd_, SHUT_RDWR); // 唤醒 poll/accept
        }
        if (thread_.joinable()) {
            thread_.join();
        }
        if (listenFd_ >= 0) {
            ::close(listenFd_);
            listenFd_ = -1;
        }
    }

private:
    void serve()
    {
        while (!stop_.load()) {
            struct pollfd pfd {};
            pfd.fd = listenFd_;
            pfd.events = POLLIN;
            if (::poll(&pfd, 1, 100) <= 0) {
                continue; // 超时 / 被 shutdown 打断，回看 stop 标记
            }
            int conn = ::accept(listenFd_, nullptr, nullptr);
            if (conn < 0) {
                continue;
            }
            if (!payload_.empty()) {
                ssize_t n = ::write(conn, payload_.data(), payload_.size());
                (void)n;
            }
            // 保持连接：读到对端关闭（会话收尾 close fd）或 stop 为止
            char buf[512];
            while (!stop_.load()) {
                struct pollfd cfd {};
                cfd.fd = conn;
                cfd.events = POLLIN;
                if (::poll(&cfd, 1, 100) <= 0) {
                    continue;
                }
                if (::recv(conn, buf, sizeof(buf), 0) <= 0) {
                    break;
                }
            }
            ::close(conn);
        }
    }

    std::string payload_;
    int listenFd_ = -1;
    uint16_t port_ = 0;
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

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

bool FileExists(const std::string &path)
{
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0;
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

// 按序比较辅助
void ExpectSequence(const StateRecorder &rec, std::vector<SshSessionState> expected)
{
    EXPECT_EQ(rec.toSequence(), std::move(expected));
}

} // namespace

// ================================================================== 状态机单测

TEST(SshSessionStateMachineTest, TransitionTableLegality)
{
    using S = SshSessionState;
    // 合法主路径
    EXPECT_TRUE(SshSession::isLegalTransition(S::kIdle, S::kConnecting));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kConnecting, S::kHandshaking));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kHandshaking, S::kAuthenticating));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kAuthenticating, S::kEstablished));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kAuthenticating, S::kClosing));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kClosing, S::kClosed));
    // 异常路径
    EXPECT_TRUE(SshSession::isLegalTransition(S::kConnecting, S::kError));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kHandshaking, S::kError));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kAuthenticating, S::kDisconnected));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kEstablished, S::kDisconnected));
    EXPECT_TRUE(SshSession::isLegalTransition(S::kConnecting, S::kClosed));
    // 非法：跳级、回退、终态再迁移
    EXPECT_FALSE(SshSession::isLegalTransition(S::kIdle, S::kEstablished));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kIdle, S::kClosed));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kConnecting, S::kEstablished));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kAuthenticating, S::kConnecting));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kError, S::kConnecting));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kClosed, S::kConnecting));
    EXPECT_FALSE(SshSession::isLegalTransition(S::kDisconnected, S::kIdle));
}

TEST(SshSessionStateMachineTest, CloseFromIdleIsNoop)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        session.close(); // idle 态：幂等空操作，不得产生任何迁移
        std::this_thread::sleep_for(200ms); // 给 post 的任务留执行窗口
        EXPECT_EQ(session.state(), SshSessionState::kIdle);
        EXPECT_TRUE(rec.toSequence().empty());
        thread.stop();
    }
}

TEST(SshSessionStateMachineTest, DuplicateConnectRejected)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        const uint16_t port = PickFreePort(); // 刚释放的端口：必为关闭态
        ASSERT_TRUE(session.connect("127.0.0.1", port, "tester"));
        // 已受理后（任何非 idle 态）重复 connect 一律拒绝
        EXPECT_FALSE(session.connect("127.0.0.1", port, "tester"));

        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        // 终态后同样拒绝
        EXPECT_FALSE(session.connect("127.0.0.1", port, "tester"));
        thread.stop();
    }
    // 序列里只能有一条 connecting：第二次 connect 没有产生任何迁移
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kError});
}

TEST(SshSessionStateMachineTest, ConnectToClosedPortFailsFast)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        const uint16_t port = PickFreePort();
        const auto begin = std::chrono::steady_clock::now();
        ASSERT_TRUE(session.connect("127.0.0.1", port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;

        EXPECT_EQ(session.lastError(), SshSessionError::kConnectFailed);
        // 本地拒绝是即时的，应远小于默认 10 s 连接超时
        EXPECT_LT(elapsed, 5s);
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kError});
}

TEST(SshSessionStateMachineTest, ConnectToBlackholeAlwaysConvergesToError)
{
    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    std::vector<SshSessionState> seq;
    {
        SshSessionOptions opts;
        opts.connectTimeoutMs = 500;   // 收紧超时，测试别等默认 10 s
        opts.handshakeTimeoutMs = 2000;
        SshSession session(thread, opts, std::ref(rec));
        const auto begin = std::chrono::steady_clock::now();
        // 192.0.2.0/24 是 RFC 5737 TEST-NET-1：正常环境 SYN 被静默丢弃，
        // connectTimeout 到期 → error(connect_timeout)。但 WSL NAT 等环境会劫持
        // 该地址完成 TCP、随后 RST——路径不同但同样必须收敛到 error 而非卡死，
        // 这正是本用例要守的底线；环境相关分支都接受。
        ASSERT_TRUE(session.connect("192.0.2.1", 22, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 8s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;

        const SshSessionError err = session.lastError();
        EXPECT_TRUE(err == SshSessionError::kConnectTimeout ||
                    err == SshSessionError::kConnectFailed ||
                    err == SshSessionError::kHandshakeTimeout ||
                    err == SshSessionError::kHandshakeFailed)
            << "意外错误码: " << sshclient::ssh::toString(err);
        EXPECT_LT(elapsed, 8s);
        seq = rec.toSequence();
        thread.stop();
    }
    // 首迁移必为 connecting，终态必为 error（中间是否经过 handshaking 视环境而定）
    ASSERT_FALSE(seq.empty());
    EXPECT_EQ(seq.front(), SshSessionState::kConnecting);
    EXPECT_EQ(seq.back(), SshSessionState::kError);
}

TEST(SshSessionStateMachineTest, HandshakeTimeoutAgainstSilentServer)
{
    DeadEndServer server(""); // 沉默服务器：accept 后一字节不发
    ASSERT_TRUE(server.start());

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.handshakeTimeoutMs = 800;
        SshSession session(thread, opts, std::ref(rec));
        const auto begin = std::chrono::steady_clock::now();
        ASSERT_TRUE(session.connect("127.0.0.1", server.port(), "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;

        EXPECT_EQ(session.lastError(), SshSessionError::kHandshakeTimeout);
        EXPECT_GE(elapsed, 700ms); // 不能提前误触发
        EXPECT_LT(elapsed, 5s);
        thread.stop();
    }
    server.stop();
    // TCP 连接成功 → 握手超时：connecting → handshaking → error
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kError});
}

TEST(SshSessionStateMachineTest, HandshakeGarbageBannerFails)
{
    // 合法 banner 之后塞垃圾字节：算法协商/包层解析必然失败
    DeadEndServer server(std::string("SSH-2.0-TestGarbage\r\n") + std::string(256, '\xAB'));
    ASSERT_TRUE(server.start());

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSessionOptions opts;
        opts.handshakeTimeoutMs = 3000; // 兜底：即使实现选择挂起也得按时收敛
        SshSession session(thread, opts, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", server.port(), "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kError, 10s));
        EXPECT_TRUE(session.lastError() == SshSessionError::kHandshakeFailed ||
                    session.lastError() == SshSessionError::kHandshakeTimeout)
            << "意外错误码: " << sshclient::ssh::toString(session.lastError());
        thread.stop();
    }
    server.stop();
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kError});
}

// ================================================================== 集成测试（真实 sshd）

TEST(SshSessionIntegrationTest, HandshakeReachesAuthenticatingThenGracefulClose)
{
    std::string rt;
    const std::string sshd = RequireSshd(&rt);
    if (sshd.empty()) {
        GTEST_SKIP() << "找不到可用 sshd（跑 scripts/setup-host-deps.sh 或设 SSH_TESTS_SSHD）";
    }
    SshdInstance sshdInst = StartSshd(sshd, rt);
    if (sshdInst.pid <= 0) {
        GTEST_SKIP() << "sshd 启动失败（端口竞态或配置不兼容），跳过集成用例";
    }

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));

        // N6 边界：握手 + 算法协商完成，进入「待认证」
        ASSERT_TRUE(rec.waitFor(SshSessionState::kAuthenticating, 20s));
        EXPECT_EQ(session.state(), SshSessionState::kAuthenticating);
        EXPECT_EQ(session.lastError(), SshSessionError::kNone);

        // 优雅关闭：authenticating → closing → closed
        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        thread.stop();
    }
    StopSshd(sshdInst);
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kClosing,
                         SshSessionState::kClosed});
}

TEST(SshSessionIntegrationTest, ServerKilledLeadsToDisconnectedWithin30s)
{
    std::string rt;
    const std::string sshd = RequireSshd(&rt);
    if (sshd.empty()) {
        GTEST_SKIP() << "找不到可用 sshd（跑 scripts/setup-host-deps.sh 或设 SSH_TESTS_SSHD）";
    }
    SshdInstance sshdInst = StartSshd(sshd, rt);
    if (sshdInst.pid <= 0) {
        GTEST_SKIP() << "sshd 启动失败（端口竞态或配置不兼容），跳过集成用例";
    }

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kAuthenticating, 20s));

        // 模拟「拔线/RST」：SIGKILL 辅助 sshd 的整个进程组（-d 模式对接受的连接会
        // re-exec 出子进程，只杀监听进程连接还活着）——其 socket 由内核发送 RST，
        // 客户端必须按验收标准在 30 s 内进入 disconnected 而非卡死（实测毫秒级）。
        // 说明：静默黑洞（拔网线无 RST）场景的检测靠 keepalive，属 N12 范围。
        const auto begin = std::chrono::steady_clock::now();
        ASSERT_EQ(::kill(-sshdInst.pid, SIGKILL), 0);
        ::waitpid(sshdInst.pid, nullptr, 0);
        sshdInst.pid = -1;

        ASSERT_TRUE(rec.waitFor(SshSessionState::kDisconnected, 30s));
        const auto elapsed = std::chrono::steady_clock::now() - begin;
        std::fprintf(stderr, "[test] kill sshd → disconnected 耗时 %lld ms（验收线 30000 ms）\n",
                     static_cast<long long>(
                         std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count()));
        EXPECT_LT(elapsed, 30s);
        EXPECT_TRUE(session.lastError() == SshSessionError::kDisconnectedByPeer ||
                    session.lastError() == SshSessionError::kSocketError)
            << "意外错误码: " << sshclient::ssh::toString(session.lastError());
        thread.stop();
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kDisconnected});
}
