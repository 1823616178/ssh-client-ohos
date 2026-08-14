/**
 * 主机密钥提取、指纹与 TOFU 校验 —— 任务 N7（DESIGN §7.1，依赖 N6 的 SshSession）。
 *
 * 职责边界（重要）：
 *   本项目的 known_hosts 持久化在 ArkTS 侧 SQLite（DESIGN §5.1 relationalStore），
 *   native 层不落盘、不编排存储。因此这里只提供纯逻辑与查询接口：
 *     - 从已完成握手的 LIBSSH2_SESSION 提取主机密钥（extractHostKey）；
 *     - 计算 OpenSSH 同款 SHA256/MD5 指纹与 Drunken Bishop randomart；
 *     - 与上层传入的已知指纹做三态比对（checkHostKey / checkFingerprintSha256）。
 *   存储与「首连弹窗 → 入库 → 重连」的编排由上层（C4/S11 方向）负责。
 *
 * 为什么不用 libssh2_knownhost_*（TASKS N7 交付物中列为可选的那套 API）：
 *   那套 API 面向 OpenSSH known_hosts 文件格式（readfile/writefile、主机名
 *   SHA1 哈希化存储），比对对象是「主机名 → 原始密钥字节」，既不产出也不消费
 *   SHA256 指纹串；而我们的存储在 ArkTS SQLite、键是 host:port、值就是
 *   SHA256 指纹。套它反而要多维护一份内存集合并做格式换算，故直接比对指纹
 *   字符串（定长 base64，比较即逐字节相等判定），语义更简单且无信息损失。
 *
 * 「不继续握手」的落地语义（对应 TASKS N7 验收措辞）：
 *   libssh2 的设计决定了握手完成后才能取主机密钥（libssh2_session_hostkey），
 *   所以校验点物理上位于握手之后、认证之前。指纹不匹配时的行为是：
 *   不进入 authenticating、以 SSH_DISCONNECT_HOST_KEY_NOT_VERIFIABLE 主动断开
 *   （状态走 closing → closed），并向调用方返回 kHostKeyMismatch 错误码。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库、OpenSSL EVP（摘要）与 libssh2 公共头，
 * 禁止 include <napi/native_api.h> / <hilog/log.h>（桥接层是 N11）。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <vector>

// 前向声明 libssh2 会话结构，避免把 <libssh2.h> 漏进公共头（与 session.h 同约定）
struct _LIBSSH2_SESSION;

namespace sshclient {
namespace ssh {

// 主机密钥三态校验结果
enum class HostKeyCheckResult {
    kOk,       // 与已知指纹一致
    kUnknown,  // 无已知指纹可比（首连 TOFU 语义）
    kMismatch, // 与已知指纹不一致；密钥提取失败也归此类（fail-closed）
};

// 一台主机当前出示的密钥全貌（全部字段由 extractHostKey 填充）
struct HostKeyInfo {
    std::string keyType;           // blob 内嵌算法名，如 "ssh-ed25519"
    std::vector<uint8_t> rawKey;   // 原始主机密钥字节（SSH 公钥 blob，known_hosts 可存它的 base64）
    std::string fingerprintSha256; // "SHA256:<base64 无 padding>"，与 ssh-keygen -l 输出一致
    std::string fingerprintMd5;    // "MD5:aa:bb:..."（冒号分隔，老习惯兼容，仅供参考展示）
    std::string randomart;         // Drunken Bishop 随机艺术图（含边框，ssh-keygen -lv 同款）
};

// ---------------------------------------------------------------- 纯逻辑原语
// 以下函数不触碰 libssh2，可独立单测；输入为任意字节串。

// base64 标准字母表编码，去掉尾部 '=' padding（OpenSSH 指纹的编码形式）
std::string base64EncodeNoPadding(const uint8_t *data, size_t len);

// SHA256(data) → "SHA256:<base64 无 padding>"；失败（OpenSSL 异常）返回空串
std::string fingerprintSha256(const uint8_t *data, size_t len);

// MD5(data) → "MD5:aa:bb:..."；仅供老用户习惯对照，安全判定一律用 SHA256
std::string fingerprintMd5(const uint8_t *data, size_t len);

// Drunken Bishop randomart：与 OpenSSH sshkey.c 的 fingerprint_randomart 逐字节对齐
// （17×9 格子、起点 (8,4)、每字节 4 步 2bit LSB 优先、访问计数上限 14、
//   起点标 S 终点标 E、边框 "+--[TITLE]--+" / "+----[HASH]-----+" 左偏补齐）。
// digest 为指纹摘要字节（SHA256 时为 32 字节）；title 形如 "[ED25519 256]"，
// hashName 形如 "SHA256"。输出 11 行、行间 '\n' 分隔，末行无换行。
std::string randomartFromDigest(const uint8_t *digest, size_t digestLen,
                                const std::string &title, const std::string &hashName);

// ---------------------------------------------------------------- 会话级接口

// 提取会话当前主机密钥。session 必须已完成握手（libssh2 语义：握手后密钥才可用），
// 否则返回 nullopt。
std::optional<HostKeyInfo> extractHostKey(struct _LIBSSH2_SESSION *session);

// 纯逻辑三态比对：expected 为空串 → kUnknown（首连）；与 actual 完全相等 → kOk；
// 其余 → kMismatch。两侧都应是 fingerprintSha256() 产出的 "SHA256:..." 格式。
HostKeyCheckResult checkFingerprintSha256(const std::string &actual,
                                          const std::string &expected);

// 会话级三态比对（TASKS N7 要求的 checkHostKey 形态）：内部 extractHostKey +
// checkFingerprintSha256；infoOut 非空时回传密钥全貌（供上层展示对比视图）。
// 提取失败（未握手等）返回 kMismatch —— 无法自证身份的会话一律按不可信处理。
HostKeyCheckResult checkHostKey(struct _LIBSSH2_SESSION *session,
                                const std::string &expectedFingerprintSha256,
                                HostKeyInfo *infoOut = nullptr);

// 上层注入的 TOFU 决策回调：SshSession 握手成功后、进入 authenticating 前，
// 在事件循环线程同步调用。必须快速返回 —— UI 弹窗确认属于异步交互，
// 上层应走「先 kReject 断开 → 用户确认 → 指纹入库 → 重新连接」的编排，
// 不得在回调内阻塞等待用户输入。
enum class HostKeyDecision {
    kAccept, // 接受该主机密钥，继续进入 authenticating
    kReject, // 拒绝：会话以 kHostKeyMismatch 错误码走 closing → closed 断开
};
using HostKeyCallback = std::function<HostKeyDecision(const HostKeyInfo &info)>;

const char *toString(HostKeyCheckResult result);

} // namespace ssh
} // namespace sshclient
