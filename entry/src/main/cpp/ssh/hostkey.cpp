#include "hostkey.h"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <libssh2.h>
#include <openssl/evp.h>

namespace sshclient {
namespace ssh {

namespace {

// ---------------------------------------------------------------- 摘要原语

constexpr size_t kSha256Len = 32;
constexpr size_t kMd5Len = 16;

bool sha256Raw(const uint8_t *data, size_t len, uint8_t out[kSha256Len])
{
    unsigned int mdLen = 0;
    return ::EVP_Digest(data, len, out, &mdLen, ::EVP_sha256(), nullptr) == 1 &&
           mdLen == kSha256Len;
}

// ---------------------------------------------------------------- SSH blob 解析

// 读 SSH wire format 的 length-prefixed string（uint32 大端长度 + 字节串）；
// 越界/畸形返回 false，成功时 *off 前进到串尾
bool readBlobString(const std::vector<uint8_t> &blob, size_t *off,
                    const uint8_t **ptr, size_t *len)
{
    if (*off + 4 > blob.size()) {
        return false;
    }
    const uint8_t *p = blob.data() + *off;
    const uint32_t l = (static_cast<uint32_t>(p[0]) << 24) |
                       (static_cast<uint32_t>(p[1]) << 16) |
                       (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
    if (*off + 4 + l > blob.size()) {
        return false;
    }
    *ptr = p + 4;
    *len = l;
    *off += 4 + l;
    return true;
}

// 取 blob 内嵌的算法名（首个 string）；畸形返回空串
std::string blobAlgorithmName(const std::vector<uint8_t> &blob)
{
    size_t off = 0;
    const uint8_t *ptr = nullptr;
    size_t len = 0;
    if (!readBlobString(blob, &off, &ptr, &len) || len == 0 || len > 64) {
        return "";
    }
    for (size_t i = 0; i < len; ++i) {
        const uint8_t c = ptr[i];
        const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                        c == '-' || c == '.' || c == '_' || c == '@' || c == '+';
        if (!ok) {
            return "";
        }
    }
    return std::string(reinterpret_cast<const char *>(ptr), len);
}

// blob 算法名提取失败时，按 libssh2 的主机密钥类型枚举兜底
const char *keyTypeNameFromLibssh2(int type)
{
    switch (type) {
    case LIBSSH2_HOSTKEY_TYPE_RSA:       return "ssh-rsa";
    case LIBSSH2_HOSTKEY_TYPE_DSS:       return "ssh-dss";
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256";
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384";
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521";
    case LIBSSH2_HOSTKEY_TYPE_ED25519:   return "ssh-ed25519";
    default:                             return "unknown";
    }
}

// RSA blob（string alg, string e, string n）的模数位数；解析失败返回 0
unsigned rsaModulusBits(const std::vector<uint8_t> &blob)
{
    size_t off = 0;
    const uint8_t *ptr = nullptr;
    size_t len = 0;
    if (!readBlobString(blob, &off, &ptr, &len)) { // alg
        return 0;
    }
    if (!readBlobString(blob, &off, &ptr, &len)) { // e
        return 0;
    }
    if (!readBlobString(blob, &off, &ptr, &len) || len == 0) { // n（mpint）
        return 0;
    }
    // mpint：最高位置 1 时有 0x00 前导字节；剥掉全部前导零
    while (len > 1 && ptr[0] == 0) {
        ++ptr;
        --len;
    }
    unsigned firstBits = 0;
    for (uint8_t b = ptr[0]; b != 0; b >>= 1) {
        ++firstBits;
    }
    return static_cast<unsigned>((len - 1) * 8) + firstBits;
}

// randomart 标题（对齐 OpenSSH 的 "[TYPE SIZE]"，TYPE 用短名）；
// 取不到位数时退化为 "[TYPE]"；整体超长截断到 16 字符（OpenSSH 标题缓冲区语义）
std::string randomartTitle(const std::string &keyType, const std::vector<uint8_t> &rawKey)
{
    std::string shortName;
    unsigned bits = 0;
    if (keyType == "ssh-ed25519") {
        shortName = "ED25519";
        bits = 256;
    } else if (keyType.rfind("ecdsa-sha2-nistp", 0) == 0) {
        shortName = "ECDSA";
        bits = static_cast<unsigned>(std::atoi(keyType.c_str() + 16));
    } else if (keyType == "ssh-rsa") {
        shortName = "RSA";
        bits = rsaModulusBits(rawKey);
    } else if (keyType == "ssh-dss") {
        shortName = "DSA";
        bits = 1024;
    } else {
        // 未知算法：大写化算法名兜底（仅展示用途）
        shortName = keyType.empty() ? "UNKNOWN" : keyType;
        for (auto &c : shortName) {
            c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        }
    }
    std::string title = "[" + shortName;
    if (bits > 0) {
        title += " " + std::to_string(bits);
    }
    title += "]";
    if (title.size() > 16) {
        title.resize(16);
    }
    return title;
}

} // namespace

// ---------------------------------------------------------------- 纯逻辑原语

std::string base64EncodeNoPadding(const uint8_t *data, size_t len)
{
    static const char kTable[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    size_t i = 0;
    for (; i + 3 <= len; i += 3) {
        const uint32_t v = (static_cast<uint32_t>(data[i]) << 16) |
                           (static_cast<uint32_t>(data[i + 1]) << 8) |
                           static_cast<uint32_t>(data[i + 2]);
        out.push_back(kTable[(v >> 18) & 63]);
        out.push_back(kTable[(v >> 12) & 63]);
        out.push_back(kTable[(v >> 6) & 63]);
        out.push_back(kTable[v & 63]);
    }
    const size_t rem = len - i;
    if (rem == 1) {
        const uint32_t v = static_cast<uint32_t>(data[i]) << 16;
        out.push_back(kTable[(v >> 18) & 63]);
        out.push_back(kTable[(v >> 12) & 63]);
    } else if (rem == 2) {
        const uint32_t v = (static_cast<uint32_t>(data[i]) << 16) |
                           (static_cast<uint32_t>(data[i + 1]) << 8);
        out.push_back(kTable[(v >> 18) & 63]);
        out.push_back(kTable[(v >> 12) & 63]);
        out.push_back(kTable[(v >> 6) & 63]);
    }
    return out;
}

std::string fingerprintSha256(const uint8_t *data, size_t len)
{
    uint8_t digest[kSha256Len];
    if (!sha256Raw(data, len, digest)) {
        return "";
    }
    return "SHA256:" + base64EncodeNoPadding(digest, kSha256Len);
}

std::string fingerprintMd5(const uint8_t *data, size_t len)
{
    uint8_t digest[kMd5Len];
    unsigned int mdLen = 0;
    if (::EVP_Digest(data, len, digest, &mdLen, ::EVP_md5(), nullptr) != 1 ||
        mdLen != kMd5Len) {
        return "";
    }
    std::string out = "MD5:";
    char hex[4];
    for (size_t i = 0; i < kMd5Len; ++i) {
        std::snprintf(hex, sizeof(hex), "%s%02x", i > 0 ? ":" : "", digest[i]);
        out += hex;
    }
    return out;
}

std::string randomartFromDigest(const uint8_t *digest, size_t digestLen,
                                const std::string &title, const std::string &hashName)
{
    // 与 OpenSSH sshkey.c fingerprint_randomart() 逐字节对齐的 Drunken Bishop：
    //   增强串 " .o+=*BOX@%&#/^SE"（len = strlen - 1 = 16），访问计数上限 len-2 = 14，
    //   起点格强制 15（'S'），终点格强制 16（'E'），渲染取 min(field, 16)。
    static const char kAugmentation[] = " .o+=*BOX@%&#/^SE";
    constexpr int kSizeX = 17; // FLDSIZE_X = 2*8+1
    constexpr int kSizeY = 9;  // FLDSIZE_Y = 8+1
    constexpr uint8_t kMarkE = sizeof(kAugmentation) - 2; // 16
    constexpr uint8_t kMarkS = kMarkE - 1;                // 15
    constexpr uint8_t kVisitCap = kMarkE - 2;             // 14

    uint8_t field[kSizeY][kSizeX] = {};
    int x = kSizeX / 2; // 起点 (8, 4)：x 为列，y 为行
    int y = kSizeY / 2;
    for (size_t i = 0; i < digestLen; ++i) {
        unsigned int input = digest[i];
        for (int b = 0; b < 4; ++b) { // 每字节 4 步，2bit LSB 优先
            x += (input & 0x1) != 0 ? 1 : -1;
            y += (input & 0x2) != 0 ? 1 : -1;
            x = x < 0 ? 0 : (x > kSizeX - 1 ? kSizeX - 1 : x); // 撞墙则该向量分量忽略
            y = y < 0 ? 0 : (y > kSizeY - 1 ? kSizeY - 1 : y);
            if (field[y][x] < kVisitCap) {
                ++field[y][x];
            }
            input >>= 2;
        }
    }
    field[kSizeY / 2][kSizeX / 2] = kMarkS; // 先标起点
    field[y][x] = kMarkE;                   // 后标终点（同格时覆盖为 E，与 OpenSSH 一致）

    // 边框：'+' + 左偏补齐 '-' + 标题 + '-' 补足 17 列 + '+'（对齐 OpenSSH 边框算法）
    const auto borderLine = [](std::string inner) {
        if (inner.size() > kSizeX) {
            inner.resize(kSizeX); // 防御：调用方标题超长（OpenSSH 此时整张图失败）
        }
        std::string line = "+";
        const size_t left = (kSizeX - inner.size()) / 2;
        line.append(left, '-');
        line.append(inner);
        line.append(kSizeX - left - inner.size(), '-');
        line.push_back('+');
        return line;
    };

    std::string out = borderLine(title);
    out.push_back('\n');
    for (int row = 0; row < kSizeY; ++row) {
        out.push_back('|');
        for (int col = 0; col < kSizeX; ++col) {
            const uint8_t v = field[row][col];
            out.push_back(kAugmentation[v > kMarkE ? kMarkE : v]);
        }
        out.append("|\n");
    }
    out += borderLine("[" + hashName + "]"); // 末行无换行（同 OpenSSH 返回值）
    return out;
}

// ---------------------------------------------------------------- 会话级接口

std::optional<HostKeyInfo> extractHostKey(struct _LIBSSH2_SESSION *session)
{
    if (session == nullptr) {
        return std::nullopt;
    }
    size_t keyLen = 0;
    int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    // libssh2 语义：握手完成后主机密钥才可用；未完成握手返回 nullptr
    const char *key = ::libssh2_session_hostkey(session, &keyLen, &keyType);
    if (key == nullptr || keyLen == 0) {
        return std::nullopt;
    }

    HostKeyInfo info;
    const auto *bytes = reinterpret_cast<const uint8_t *>(key);
    info.rawKey.assign(bytes, bytes + keyLen);
    info.keyType = blobAlgorithmName(info.rawKey);
    if (info.keyType.empty()) {
        info.keyType = keyTypeNameFromLibssh2(keyType); // blob 畸形时按 libssh2 枚举兜底
    }
    info.fingerprintSha256 = fingerprintSha256(bytes, keyLen);
    if (info.fingerprintSha256.empty()) {
        return std::nullopt; // OpenSSL 异常：宁可失败也不给出空指纹
    }
    info.fingerprintMd5 = fingerprintMd5(bytes, keyLen);

    // randomart 画的是「指纹摘要」而非密钥本体（与 ssh-keygen -lv 的输入一致）
    uint8_t digest[kSha256Len];
    if (!sha256Raw(bytes, keyLen, digest)) {
        return std::nullopt;
    }
    info.randomart =
        randomartFromDigest(digest, kSha256Len, randomartTitle(info.keyType, info.rawKey),
                            "SHA256");
    return info;
}

HostKeyCheckResult checkFingerprintSha256(const std::string &actual,
                                          const std::string &expected)
{
    if (expected.empty()) {
        return HostKeyCheckResult::kUnknown; // 首连：无基线可比
    }
    return actual == expected ? HostKeyCheckResult::kOk : HostKeyCheckResult::kMismatch;
}

HostKeyCheckResult checkHostKey(struct _LIBSSH2_SESSION *session,
                                const std::string &expectedFingerprintSha256,
                                HostKeyInfo *infoOut)
{
    std::optional<HostKeyInfo> info = extractHostKey(session);
    if (!info.has_value()) {
        return HostKeyCheckResult::kMismatch; // fail-closed：取不到密钥无法自证身份
    }
    if (infoOut != nullptr) {
        *infoOut = *info;
    }
    return checkFingerprintSha256(info->fingerprintSha256, expectedFingerprintSha256);
}

const char *toString(HostKeyCheckResult result)
{
    switch (result) {
    case HostKeyCheckResult::kOk:       return "ok";
    case HostKeyCheckResult::kUnknown:  return "unknown";
    case HostKeyCheckResult::kMismatch: return "mismatch";
    }
    return "unknown_result";
}

} // namespace ssh
} // namespace sshclient
