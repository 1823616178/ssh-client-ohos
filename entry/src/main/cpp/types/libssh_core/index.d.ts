/**
 * libssh_core.so 的 ArkTS 类型声明（NAPI 桥接层）。
 * 所有接口失败时返回空串，不抛异常。
 */

/** libssh2 运行时版本，如 "1.11.1" */
export const getLibssh2Version: () => string;

/** OpenSSL 版本，如 "3.5.7" */
export const getOpensslVersion: () => string;

/** libvterm 版本（编译期宏，如 "0.3.3"；libvterm 无运行时版本 API） */
export const getVtermVersion: () => string;

/** Argon2 编码版本（如 "1.3"；libargon2 无库版本 API） */
export const getArgon2Version: () => string;
