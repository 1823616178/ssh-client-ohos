/**
 * 主机密钥与 TOFU —— 任务 N7 的单测与集成测试。
 *
 * 覆盖：
 *   纯逻辑单测（不需要服务器）：
 *     - base64 无 padding 编码边界（0/1/2/3/4/6 字节输入对照已知值）
 *     - SHA256 指纹黄金向量（空串、"abc"）与格式（"SHA256:" 前缀 + 43 字符无 '='）
 *     - MD5 冒号分隔指纹黄金向量
 *     - randomart：同一摘要同一图、不同摘要不同图、11 行 × 19 列结构、
 *       起点 S（(8,4) 格）终点 E 各恰一个、边框与 ssh-keygen -lv 同款格式
 *     - checkFingerprintSha256 三态（OK / UNKNOWN / MISMATCH）
 *     - 未握手的会话 checkHostKey → MISMATCH（fail-closed）
 *   集成（SSH_TESTS_INTEGRATION 且找到 sshd 时；否则 GTEST_SKIP）：
 *     - 连接取指纹 == 从 host key .pub 文件独立算出的指纹 == ssh-keygen -l 输出
 *     - randomart 与 ssh-keygen -lv 输出的图逐字符一致
 *     - 回调传入正确指纹 → 接受 → 进入 authenticating
 *     - 回调传入伪造指纹 → 拒绝 → 不进入 authenticating，走 closing → closed，
 *       lastError() == kHostKeyMismatch（对应验收标准 HOST_KEY_MISMATCH）
 *     - checkHostKey 裸接口（blocking 原始 libssh2 会话）：OK / UNKNOWN / MISMATCH
 *
 * sshd 起停辅助与 N6 共用 sshd_testkit.h。
 */
#include <gtest/gtest.h>

#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <libssh2.h>

#include "io/SessionThread.h"
#include "ssh/hostkey.h"
#include "ssh/session.h"
#include "sshd_testkit.h"

using namespace std::chrono_literals;
using sshclient::io::SessionThread;
using sshclient::ssh::HostKeyCallback;
using sshclient::ssh::HostKeyCheckResult;
using sshclient::ssh::HostKeyDecision;
using sshclient::ssh::HostKeyInfo;
using sshclient::ssh::SshSession;
using sshclient::ssh::SshSessionError;
using sshclient::ssh::SshSessionOptions;
using sshclient::ssh::SshSessionState;

namespace {

// ---------------------------------------------------------------- 测试小工具

// base64 解码（测试输入干净：来自 .pub 文件字段；遇 '=' 提前结束）
std::vector<uint8_t> Base64Decode(const std::string &in)
{
    const auto valOf = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') {
            return c - 'A';
        }
        if (c >= 'a' && c <= 'z') {
            return c - 'a' + 26;
        }
        if (c >= '0' && c <= '9') {
            return c - '0' + 52;
        }
        if (c == '+') {
            return 62;
        }
        if (c == '/') {
            return 63;
        }
        return -1;
    };
    std::vector<uint8_t> out;
    uint32_t acc = 0;
    int nbits = 0;
    for (const char c : in) {
        if (c == '=') {
            break;
        }
        if (std::isspace(static_cast<unsigned char>(c)) != 0) {
            continue;
        }
        const int v = valOf(c);
        if (v < 0) {
            return {};
        }
        acc = ((acc << 6) | static_cast<uint32_t>(v)) & 0xFFFFFFu;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            out.push_back(static_cast<uint8_t>((acc >> nbits) & 0xFF));
        }
    }
    return out;
}

// 读 authorized_keys 格式 .pub 文件（"algo base64 comment"），返回算法名与 key blob
bool ReadPubKeyBlob(const std::string &path, std::string *alg, std::vector<uint8_t> *blob)
{
    FILE *f = std::fopen(path.c_str(), "r");
    if (f == nullptr) {
        return false;
    }
    char buf[8192];
    const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    buf[n] = '\0';
    const std::string content(buf, n);
    const size_t sp1 = content.find_first_of(" \t");
    const size_t sp2 = sp1 == std::string::npos
                           ? std::string::npos
                           : content.find_first_of(" \t", sp1 + 1);
    if (sp1 == std::string::npos || sp2 == std::string::npos) {
        return false;
    }
    *alg = content.substr(0, sp1);
    *blob = Base64Decode(content.substr(sp1 + 1, sp2 - sp1 - 1));
    return !blob->empty();
}

// popen 跑命令并收全部 stdout；失败返回空串（仅宿主机集成路径使用）
std::string RunCommand(const std::string &cmd)
{
    FILE *p = ::popen(cmd.c_str(), "r");
    if (p == nullptr) {
        return "";
    }
    std::string out;
    char buf[512];
    size_t n = 0;
    while ((n = std::fread(buf, 1, sizeof(buf), p)) > 0) {
        out.append(buf, n);
    }
    ::pclose(p);
    return out;
}

// 从 ssh-keygen -l 输出抓 "SHA256:..."（或 "MD5:..."）token
std::string ExtractFingerprintToken(const std::string &text, const std::string &prefix)
{
    const size_t pos = text.find(prefix);
    if (pos == std::string::npos) {
        return "";
    }
    const size_t end = text.find_first_of(" \t\r\n", pos);
    return text.substr(pos, end == std::string::npos ? end : end - pos);
}

// 从 ssh-keygen -lv 输出抓 randomart 块：首个 '+' 开头的行起到输出末尾，去尾部空白
std::string ExtractRandomartBlock(const std::string &text)
{
    const size_t pos = text.find("\n+--[");
    if (pos == std::string::npos) {
        return "";
    }
    std::string block = text.substr(pos + 1);
    while (!block.empty() &&
           (block.back() == '\n' || block.back() == '\r' || block.back() == ' ')) {
        block.pop_back();
    }
    return block;
}

// 按 '\n' 切行
std::vector<std::string> SplitLines(const std::string &text)
{
    std::vector<std::string> lines;
    size_t begin = 0;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '\n') {
            lines.push_back(text.substr(begin, i - begin));
            begin = i + 1;
        }
    }
    lines.push_back(text.substr(begin));
    return lines;
}

void EnsureLibssh2Init()
{
    static std::once_flag once;
    static int rc = -1;
    std::call_once(once, [] { rc = ::libssh2_init(0); });
    ASSERT_EQ(rc, 0);
}

// blocking 原始 libssh2 会话握手（独立于 SshSession 验证 checkHostKey 裸接口）
struct RawConnection {
    int fd = -1;
    LIBSSH2_SESSION *session = nullptr;

    RawConnection() = default;
    RawConnection(const RawConnection &) = delete;
    RawConnection &operator=(const RawConnection &) = delete;
    // 独占资源的移动语义：具名返回值离开函数时转移所有权，防双重 close/free
    RawConnection(RawConnection &&other) noexcept : fd(other.fd), session(other.session)
    {
        other.fd = -1;
        other.session = nullptr;
    }

    ~RawConnection()
    {
        if (session != nullptr) {
            ::libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "", "");
            ::libssh2_session_free(session);
        }
        if (fd >= 0) {
            ::close(fd);
        }
    }
};

RawConnection RawHandshake(uint16_t port)
{
    RawConnection conn;
    EnsureLibssh2Init();
    conn.fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (conn.fd < 0) {
        return conn;
    }
    struct sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    if (::connect(conn.fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) != 0) {
        return conn;
    }
    conn.session = ::libssh2_session_init_ex(nullptr, nullptr, nullptr, nullptr);
    if (conn.session == nullptr) {
        return conn;
    }
    ::libssh2_session_set_blocking(conn.session, 1);
    if (::libssh2_session_handshake(conn.session, conn.fd) != 0) {
        ::libssh2_session_free(conn.session);
        conn.session = nullptr;
    }
    return conn;
}

} // namespace

// ================================================================== 纯逻辑单测

TEST(HostKeyBase64Test, BoundaryLengths)
{
    const auto enc = [](std::initializer_list<uint8_t> bytes) {
        return sshclient::ssh::base64EncodeNoPadding(bytes.begin(), bytes.size());
    };
    // 0/1/2/3 字节：mod 3 全分支；期望值与标准 base64 去 padding 一致
    EXPECT_EQ(enc({}), "");
    EXPECT_EQ(enc({0x00}), "AA");
    EXPECT_EQ(enc({0xFF}), "/w");
    EXPECT_EQ(enc({0x00, 0x00}), "AAA");
    EXPECT_EQ(enc({0xFF, 0xFF}), "//8");
    EXPECT_EQ(enc({0x00, 0x00, 0x00}), "AAAA");
    EXPECT_EQ(enc({0xFF, 0xFF, 0xFF}), "////");
    // 4/6 字节与可打印串对照
    EXPECT_EQ(enc({0xDE, 0xAD, 0xBE, 0xEF}), "3q2+7w");
    const auto encStr = [](const char *s) {
        return sshclient::ssh::base64EncodeNoPadding(
            reinterpret_cast<const uint8_t *>(s), std::strlen(s));
    };
    EXPECT_EQ(encStr("f"), "Zg");
    EXPECT_EQ(encStr("fo"), "Zm8");
    EXPECT_EQ(encStr("foo"), "Zm9v");
    EXPECT_EQ(encStr("foob"), "Zm9vYg");
    EXPECT_EQ(encStr("fooba"), "Zm9vYmE");
    EXPECT_EQ(encStr("foobar"), "Zm9vYmFy");
}

TEST(HostKeyFingerprintTest, Sha256GoldenVectorsAndFormat)
{
    // 黄金向量：SHA256("") 与 SHA256("abc") 的 OpenSSH 格式指纹
    const auto fp = [](const char *s) {
        return sshclient::ssh::fingerprintSha256(reinterpret_cast<const uint8_t *>(s),
                                                 std::strlen(s));
    };
    EXPECT_EQ(fp(""), "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU");
    EXPECT_EQ(fp("abc"), "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0");

    const std::string f = fp("abc");
    EXPECT_EQ(f.rfind("SHA256:", 0), 0u);               // 前缀
    ASSERT_EQ(f.size(), 7u + 43u);                      // 32 字节 → 43 字符 base64
    EXPECT_EQ(f.find('='), std::string::npos);          // 无 padding
    for (size_t i = 7; i < f.size(); ++i) {
        const char c = f[i];
        EXPECT_TRUE(std::isalnum(static_cast<unsigned char>(c)) != 0 || c == '+' ||
                    c == '/')
            << "非法 base64 字符: " << c;
    }
}

TEST(HostKeyFingerprintTest, Md5GoldenVector)
{
    const auto fp = [](const char *s) {
        return sshclient::ssh::fingerprintMd5(reinterpret_cast<const uint8_t *>(s),
                                              std::strlen(s));
    };
    EXPECT_EQ(fp(""), "MD5:d4:1d:8c:d9:8f:00:b2:04:e9:80:09:98:ec:f8:42:7e");
    EXPECT_EQ(fp("abc"), "MD5:90:01:50:98:3c:d2:4f:b0:d6:96:3f:7d:28:e1:7f:72");
}

TEST(HostKeyRandomartTest, SameDigestSameArtDifferentDigestDifferentArt)
{
    std::vector<uint8_t> a(32);
    std::vector<uint8_t> b(32, 0xFF);
    for (size_t i = 0; i < a.size(); ++i) {
        a[i] = static_cast<uint8_t>(i);
    }
    const auto art = [](const std::vector<uint8_t> &d) {
        return sshclient::ssh::randomartFromDigest(d.data(), d.size(), "[ED25519 256]",
                                                   "SHA256");
    };
    EXPECT_EQ(art(a), art(a)); // 确定性：同一指纹同一图
    EXPECT_NE(art(a), art(b)); // 不同指纹不同图
}

TEST(HostKeyRandomartTest, ShapeMarkersBordersAndCharset)
{
    std::vector<uint8_t> digest(32);
    for (size_t i = 0; i < digest.size(); ++i) {
        digest[i] = static_cast<uint8_t>(i * 7 + 3);
    }
    const std::string art = sshclient::ssh::randomartFromDigest(
        digest.data(), digest.size(), "[ED25519 256]", "SHA256");
    const std::vector<std::string> lines = SplitLines(art);

    // 结构：1 行上边框 + 9 行图 + 1 行下边框；每行 19 列
    ASSERT_EQ(lines.size(), 11u);
    // 边框与 OpenSSH 逐字符一致（左偏补齐："[" 左 (17-len)/2 个 '-'）
    EXPECT_EQ(lines[0], "+--[ED25519 256]--+");
    EXPECT_EQ(lines[10], "+----[SHA256]-----+");
    const std::string charset = " .o+=*BOX@%&#/^SE";
    int countS = 0;
    int countE = 0;
    for (size_t row = 1; row <= 9; ++row) {
        ASSERT_EQ(lines[row].size(), 19u);
        EXPECT_EQ(lines[row].front(), '|');
        EXPECT_EQ(lines[row].back(), '|');
        for (size_t col = 1; col <= 17; ++col) {
            const char c = lines[row][col];
            EXPECT_NE(charset.find(c), std::string::npos) << "图外字符: " << c;
            countS += c == 'S' ? 1 : 0;
            countE += c == 'E' ? 1 : 0;
        }
    }
    // 终点 E 恰一个；起点 S 在 (8,4) 格（图行 4、列 8 → lines[5][9]），
    // 若蠕虫终点恰好回到起点则被 E 覆盖（与 OpenSSH 同语义）
    EXPECT_EQ(countE, 1);
    if (countS == 1) {
        EXPECT_EQ(lines[5][9], 'S');
    } else {
        EXPECT_EQ(lines[5][9], 'E');
    }
}

TEST(HostKeyCheckTest, PureFingerprintThreeStates)
{
    using sshclient::ssh::checkFingerprintSha256;
    EXPECT_EQ(checkFingerprintSha256("SHA256:abc", "SHA256:abc"), HostKeyCheckResult::kOk);
    EXPECT_EQ(checkFingerprintSha256("SHA256:abc", ""), HostKeyCheckResult::kUnknown);
    EXPECT_EQ(checkFingerprintSha256("SHA256:abc", "SHA256:abd"),
              HostKeyCheckResult::kMismatch);
    EXPECT_EQ(checkFingerprintSha256("", "SHA256:abc"), HostKeyCheckResult::kMismatch);
}

TEST(HostKeyCheckTest, SessionWithoutHandshakeFailsClosed)
{
    EnsureLibssh2Init();
    LIBSSH2_SESSION *session = ::libssh2_session_init_ex(nullptr, nullptr, nullptr, nullptr);
    ASSERT_NE(session, nullptr);
    // 未握手：取不到主机密钥，fail-closed → MISMATCH（无法自证身份即不可信）
    EXPECT_EQ(sshclient::ssh::extractHostKey(session), std::nullopt);
    EXPECT_EQ(sshclient::ssh::checkHostKey(session, "SHA256:anything"),
              HostKeyCheckResult::kMismatch);
    ::libssh2_session_free(session);
}

// ================================================================== 集成测试（真实 sshd）

TEST(HostKeyIntegrationTest, FingerprintMatchesPubFileAndSshKeygen)
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

    // 独立基线 1：.pub 文件（authorized_keys 格式）的 key blob 直接算指纹
    const std::string pubPath = rt + "/ssh_host_ed25519_key.pub";
    std::string alg;
    std::vector<uint8_t> blob;
    ASSERT_TRUE(ReadPubKeyBlob(pubPath, &alg, &blob));
    EXPECT_EQ(alg, "ssh-ed25519");
    const std::string expectedFp =
        sshclient::ssh::fingerprintSha256(blob.data(), blob.size());

    // 独立基线 2：OpenSSH 官方工具输出
    const std::string keygenL = RunCommand("ssh-keygen -lf '" + pubPath + "'");
    const std::string keygenFp = ExtractFingerprintToken(keygenL, "SHA256:");
    ASSERT_FALSE(keygenFp.empty()) << "ssh-keygen 输出无 SHA256 指纹: " << keygenL;
    EXPECT_EQ(keygenFp, expectedFp);
    std::fprintf(stderr, "[test] 基线指纹（ssh-keygen -l）: %s\n[test] 基线指纹（.pub 直算）: %s\n",
                 keygenFp.c_str(), expectedFp.c_str());

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    std::optional<HostKeyInfo> info;
    {
        // 不设回调：默认策略首连放行（TOFU 开发语义）并报告指纹
        SshSession session(thread, {}, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kAuthenticating, 20s));
        info = session.hostKeyInfo();
        thread.stop();
    }
    StopSshd(sshdInst);

    // 被测实现的指纹与两条独立基线一致
    ASSERT_TRUE(info.has_value());
    EXPECT_EQ(info->keyType, "ssh-ed25519");
    EXPECT_EQ(info->rawKey, blob);
    EXPECT_EQ(info->fingerprintSha256, expectedFp);
    std::fprintf(stderr, "[test] 连接实测指纹（extractHostKey）: %s\n",
                 info->fingerprintSha256.c_str());

    // MD5 对照（老习惯展示位）
    const std::string keygenMd5 =
        ExtractFingerprintToken(RunCommand("ssh-keygen -E md5 -lf '" + pubPath + "'"), "MD5:");
    EXPECT_EQ(info->fingerprintMd5, keygenMd5);

    // randomart 与 ssh-keygen -lv 输出的图逐字符一致
    const std::string keygenArt =
        ExtractRandomartBlock(RunCommand("ssh-keygen -lvf '" + pubPath + "'"));
    ASSERT_FALSE(keygenArt.empty());
    std::fprintf(stderr, "[test] 被测实现 randomart:\n%s\n[test] ssh-keygen -lv randomart:\n%s\n",
                 info->randomart.c_str(), keygenArt.c_str());
    EXPECT_EQ(info->randomart, keygenArt);
}

TEST(HostKeyIntegrationTest, CallbackAcceptsCorrectFingerprint)
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

    std::string alg;
    std::vector<uint8_t> blob;
    ASSERT_TRUE(ReadPubKeyBlob(rt + "/ssh_host_ed25519_key.pub", &alg, &blob));
    const std::string expectedFp =
        sshclient::ssh::fingerprintSha256(blob.data(), blob.size());

    // 模拟上层「known_hosts 里有正确指纹」：回调比对 → OK → 接受
    std::mutex cbMutex;
    std::optional<HostKeyCheckResult> cbResult;
    std::optional<HostKeyInfo> cbInfo;
    SshSessionOptions opts;
    opts.hostKeyCallback = [&](const HostKeyInfo &info) {
        std::lock_guard<std::mutex> lock(cbMutex);
        cbResult = sshclient::ssh::checkFingerprintSha256(info.fingerprintSha256, expectedFp);
        cbInfo = info;
        return *cbResult == HostKeyCheckResult::kOk ? HostKeyDecision::kAccept
                                                    : HostKeyDecision::kReject;
    };

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    {
        SshSession session(thread, opts, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));
        ASSERT_TRUE(rec.waitFor(SshSessionState::kAuthenticating, 20s));
        EXPECT_EQ(session.lastError(), SshSessionError::kNone);
        session.close();
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 5s));
        thread.stop();
    }
    StopSshd(sshdInst);

    {
        std::lock_guard<std::mutex> lock(cbMutex);
        ASSERT_TRUE(cbResult.has_value());
        EXPECT_EQ(*cbResult, HostKeyCheckResult::kOk);
        ASSERT_TRUE(cbInfo.has_value());
        EXPECT_EQ(cbInfo->fingerprintSha256, expectedFp);
    }
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kAuthenticating, SshSessionState::kClosing,
                         SshSessionState::kClosed});
}

TEST(HostKeyIntegrationTest, ForgedFingerprintRejectedBeforeAuthenticating)
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

    // 伪造指纹（known_hosts 里存的是旧/错值）：与真实主机密钥必然不同
    const std::string forged = sshclient::ssh::fingerprintSha256(
        reinterpret_cast<const uint8_t *>("forged-host-key"), sizeof("forged-host-key") - 1);

    std::mutex cbMutex;
    std::optional<HostKeyCheckResult> cbResult;
    SshSessionOptions opts;
    opts.hostKeyCallback = [&](const HostKeyInfo &info) {
        std::lock_guard<std::mutex> lock(cbMutex);
        cbResult = sshclient::ssh::checkFingerprintSha256(info.fingerprintSha256, forged);
        return *cbResult == HostKeyCheckResult::kOk ? HostKeyDecision::kAccept
                                                    : HostKeyDecision::kReject;
    };

    SessionThread thread;
    ASSERT_TRUE(thread.start());
    StateRecorder rec;
    std::optional<HostKeyInfo> info;
    SshSessionError err = SshSessionError::kNone;
    std::string errMsg;
    {
        SshSession session(thread, opts, std::ref(rec));
        ASSERT_TRUE(session.connect("127.0.0.1", sshdInst.port, "tester"));
        // 拒绝路径终态是 closed（closing → closed 优雅断开）
        ASSERT_TRUE(rec.waitFor(SshSessionState::kClosed, 10s));
        err = session.lastError();
        errMsg = session.lastErrorMessage();
        info = session.hostKeyInfo(); // 被拒后仍可取，供对比视图
        thread.stop();
    }
    StopSshd(sshdInst);

    // 验收标准：指纹变更 → HOST_KEY_MISMATCH 方向错误码，且不进入认证
    EXPECT_EQ(err, SshSessionError::kHostKeyMismatch)
        << "意外错误码: " << sshclient::ssh::toString(err);
    EXPECT_FALSE(errMsg.empty());
    EXPECT_FALSE(rec.visited(SshSessionState::kAuthenticating));
    {
        std::lock_guard<std::mutex> lock(cbMutex);
        ASSERT_TRUE(cbResult.has_value());
        EXPECT_EQ(*cbResult, HostKeyCheckResult::kMismatch);
    }
    // hostKeyInfo() 留档真实指纹（上层对比视图展示「实际 vs 预期」用）
    ASSERT_TRUE(info.has_value());
    EXPECT_NE(info->fingerprintSha256, forged);
    std::fprintf(stderr, "[test] 指纹不匹配被拒：实际 %s vs 伪造基线 %s → %s\n",
                 info->fingerprintSha256.c_str(), forged.c_str(),
                 sshclient::ssh::toString(err));
    ExpectSequence(rec, {SshSessionState::kConnecting, SshSessionState::kHandshaking,
                         SshSessionState::kClosing, SshSessionState::kClosed});
}

TEST(HostKeyIntegrationTest, CheckHostKeyRawBlockingSessionThreeStates)
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

    std::string alg;
    std::vector<uint8_t> blob;
    ASSERT_TRUE(ReadPubKeyBlob(rt + "/ssh_host_ed25519_key.pub", &alg, &blob));
    const std::string expectedFp =
        sshclient::ssh::fingerprintSha256(blob.data(), blob.size());

    RawConnection conn = RawHandshake(sshdInst.port);
    ASSERT_NE(conn.session, nullptr) << "blocking 握手失败";

    HostKeyInfo info;
    // 三态全覆盖：正确 → OK；空基线 → UNKNOWN（首连）；伪造 → MISMATCH
    EXPECT_EQ(sshclient::ssh::checkHostKey(conn.session, expectedFp, &info),
              HostKeyCheckResult::kOk);
    EXPECT_EQ(info.fingerprintSha256, expectedFp);
    EXPECT_EQ(sshclient::ssh::checkHostKey(conn.session, ""), HostKeyCheckResult::kUnknown);
    const std::string forged = expectedFp.substr(0, expectedFp.size() - 2) +
                               (expectedFp.back() == 'A' ? "B" : "A");
    EXPECT_EQ(sshclient::ssh::checkHostKey(conn.session, forged),
              HostKeyCheckResult::kMismatch);
    StopSshd(sshdInst);
}
