/**
 * S2 黄金向量（docs/SYNC-PROTOCOL.md §9 / DESIGN §9）。
 *
 * 输入写死。密文与 ciphertextHash 由本实现首次跑通后登记，此后永不修改。
 * 任何重构必须继续命中这些字节，否则老用户保险库解不开。
 *
 * 2026-08-16 重录一次：AAD 域与恢复密钥前缀改为对齐桌面端 ssh-tool 命名空间
 * （ssh-client-ohos/* + SCO1 → ssh-port-mapper/* + SPM1），两端共用同一保险库。
 * 新值由桌面端自己的 hash-wasm Argon2id + Node crypto 独立算出，作跨实现对拍：
 *   - kVaultKeyHex 与重录前完全一致（Argon2 不参与 AAD）；
 *   - kCiphertextHex 前 19 字节（明文长度）与重录前一致，仅 16 字节 GCM tag 变化，
 *     符合「只改 AAD」的预期。
 * 此后同样永不修改。
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace sshclient {
namespace crypto {
namespace golden {

inline constexpr char kPassword[] = "s2-golden-password";
inline constexpr std::uint8_t kSalt[16] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
};
inline constexpr std::uint8_t kNonce[12] = {
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B,
};
inline constexpr char kPlaintext[] = "s2-golden-plaintext";
inline constexpr char kVaultId[] = "vault-golden";
inline constexpr char kSchemaVersion[] = "1";
inline constexpr char kKeyVersion[] = "1";

inline constexpr std::uint8_t kRecoveryRaw[32] = {
    0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
};

// ---- 登记值（2026-08-16 对齐桌面端命名空间后重录并冻结，禁止修改）----
inline constexpr char kVaultKeyHex[] =
    "86b05fc972d63bcc7c33b0df2420f23484adbab54b923533983ec93b9783a7ec";
inline constexpr char kCiphertextHex[] =
    "636005c373efaad17c396e443e30b26fde0c00ab78b6442183407832d6f8acb47fe631";
inline constexpr char kCiphertextHash[] =
    "7642985e1b19ef5784767564e06c2dce7c3ca7322acbf33865c1de03bf9a73c8";
inline constexpr char kRecoveryKey[] =
    "SPM1-ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8-EF4ED88BE4A3";
inline constexpr char kRecoveryKekHex[] =
    "3f564907fd98e07730ff9bb5d79dcab819bb80c11c2d0cba51c723edb83220a5";

} // namespace golden
} // namespace crypto
} // namespace sshclient
