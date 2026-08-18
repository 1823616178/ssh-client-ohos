/**
 * 同步协议常量（任务 S1，docs/SYNC-PROTOCOL.md 的 ArkTS 唯一出处）。
 *
 * S3/S5/S6/S7 只准从本文件 import，禁止再写这些字面量。
 * native 对应文件：cpp/crypto/sync_params.h（域字符串由 aad.hpp 引用）。
 * 数值/字符串与 SYNC-PROTOCOL.md §2 / §4 / §7 逐项对齐；单测核对。
 */

/** 本客户端读写的文档 schema 版本 */
export const SCHEMA_VERSION: number = 1;

/** 服务端允许的 schemaVersion 上限（信封外壳） */
export const SCHEMA_VERSION_MAX: number = 1000;

/** Argon2id 内存（KiB） */
export const ARGON2_MEMORY_KIB: number = 65536;
/** Argon2id 迭代轮数 */
export const ARGON2_ITERATIONS: number = 3;
/** Argon2id 并行度 */
export const ARGON2_PARALLELISM: number = 1;
/** Argon2id 输出字节数（Vault key） */
export const ARGON2_HASH_LEN: number = 32;
/** Argon2id salt 字节数 */
export const KDF_SALT_LEN: number = 16;

/** 信封 algorithm 字面量（服务端精确匹配） */
export const AES_ALGORITHM: string = 'AES-256-GCM';
/** AES-GCM nonce 字节数 */
export const AES_NONCE_LEN: number = 12;
/** AES-GCM tag 字节数（拼在密文尾） */
export const AES_TAG_LEN: number = 16;

// 以下域字符串与恢复密钥前缀沿用桌面端 ssh-tool 的命名空间，两端共用同一个保险库。
// 详见 cpp/crypto/sync_params.h 的同段说明。

/** 恢复 KEK 的 HKDF info */
export const HKDF_INFO_RECOVERY_KEK: string = 'ssh-port-mapper/recovery-kek/v1';
/** HKDF 输出字节数 */
export const HKDF_OUT_LEN: number = 32;

/** 文档加密 AAD 域 */
export const AAD_DOMAIN_SYNC_DOCUMENT: string = 'ssh-port-mapper/sync-document/v1';
/** 密码包裹 Vault key AAD 域 */
export const AAD_DOMAIN_VAULT_KEY_PASSWORD: string = 'ssh-port-mapper/vault-key/password/v1';
/** 恢复包裹 Vault key AAD 域 */
export const AAD_DOMAIN_VAULT_KEY_RECOVERY: string = 'ssh-port-mapper/vault-key/recovery/v1';

/** 恢复密钥前缀 */
export const RECOVERY_KEY_PREFIX: string = 'SPM1';
/** 恢复密钥 raw 段 base64url 字符数（32 字节无填充） */
export const RECOVERY_KEY_RAW_B64URL_LEN: number = 43;
/** 恢复密钥校验十六进制大写位数 */
export const RECOVERY_KEY_CHECK_HEX_LEN: number = 12;

/** ciphertextHash 小写十六进制长度 */
export const CIPHERTEXT_HASH_HEX_LEN: number = 64;

/** 单份文档体积上限（字节） */
export const DOCUMENT_MAX_BYTES: number = 2097152;
/** 单条私钥上限（字节） */
export const PRIVATE_KEY_MAX_BYTES: number = 262144;
/** 主机条数上限 */
export const HOST_COUNT_MAX: number = 5000;

/** 保存后触发同步的防抖（毫秒） */
export const SAVE_DEBOUNCE_MS: number = 3000;

/** If-Match 里 revision 的前缀（含引号规则由 S3 组装） */
export const REVISION_ETAG_PREFIX: string = 'revision-';

/** 云端尚无文档时的乐观锁起点 */
export const REVISION_INITIAL: number = 0;

/** 同步相位名（S6 状态机；本文件只登记合法字面量） */
export type SyncPhaseName =
  'signed_out' | 'disabled' | 'locked' | 'idle' | 'syncing' | 'synced' |
  'offline' | 'conflict' | 'error' | 'auth_error';

export const SYNC_PHASE_NAMES: SyncPhaseName[] = [
  'signed_out', 'disabled', 'locked', 'idle', 'syncing', 'synced',
  'offline', 'conflict', 'error', 'auth_error'
];
