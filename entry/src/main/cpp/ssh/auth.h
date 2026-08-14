/**
 * 认证：密码 / 公钥（内存私钥）/ keyboard-interactive —— 任务 N8（TASKS M1，依赖 N6/N7）。
 *
 * 职责划分：
 *   - SshSession 的认证驱动方法（authenticate* / queryAuthMethods / driveAuth 等）
 *     声明在 session.h、实现在 auth.cpp（成员函数分文件实现，避免 session.cpp 臃肿）；
 *   - 本头文件只放纯逻辑辅助，可脱离真实服务器单测：
 *       secureZero          抗编译器优化的敏感内存清零（密码/私钥/短语用完即清）；
 *       parseAuthMethodList 解析 userauth_list 的逗号分隔结果；
 *       mapAuthError        libssh2 userauth 错误码 → SshSessionError 细分映射。
 *
 * 关于 secureZero 的选型（TASKS N8 验收措辞是 explicit_bzero）：
 *   OHOS musl 没有 explicit_bzero / memset_s（N1/N2 构建期实测缺口），而项目已链
 *   OpenSSL —— OPENSSL_cleanse 就是为抗优化清零设计的（volatile 写，编译器不得消除；
 *   底层在支持的平台上还会落到汇编实现），宿主与 OHOS 两侧行为一致，ASan 下无冲突
 *   （ASan 插桩不拦截 volatile 写）。
 *
 * 纯逻辑代码：只依赖 C/C++ 标准库、OpenSSL（crypto）与 libssh2 公共头，
 * 禁止 include <napi/native_api.h> / <hilog/log.h>（桥接层是 N11）。
 */
#pragma once

#include <cstddef>
#include <string>

#include "session.h"

namespace sshclient {
namespace ssh {

// 抗编译器优化的内存清零。敏感材料（密码/私钥/短语/应答）用完必须经此清除，
// 普通 memset 可能被编译器以「死写」为由优化掉。
void secureZero(void *data, size_t len);
// std::string 重载：已用内容清零并 clear()。只覆盖 [0, size()) 区间——
// 按标准保证的可写范围操作；容量内的残留历史字节不在本函数职责内
// （调用方约定：凭据串一经赋值不再缩减复用）。
void secureZero(std::string &s);

// 解析 libssh2_userauth_list 返回的逗号分隔方式串（如
// "publickey,password,keyboard-interactive"）。逐项 trim 空白；空项忽略；
// 本端不识别的方式记入 unsupported。纯逻辑，可单测。
AuthMethodSet parseAuthMethodList(const std::string &csv);

// libssh2 userauth 系列调用的返回码 → SshSessionError 细分映射（纯逻辑，可单测）。
// 细分规则（libssh2 1.11.1 源码 pem.c/openssl.c/userauth.c 逐行确认 + 真实 sshd
// 实测复核；pin 版本升级时需复核——相关集成用例会先于映射表报错）：
//   - kPassword：一律 kAuthFailedPassword（密码错误/用户不存在都是
//     AUTHENTICATION_FAILED；PASSWORD_EXPIRED 含密码过期）；
//   - kPublicKey：
//       KEYFILE_AUTH_FAILED（PEM 私钥短语错误/短语缺失，
//         openssl.c「Wrong passphrase for private key」）→ kAuthFailedPassphrase；
//       FILE（无公钥数据时「从私钥提取公钥」阶段失败——OpenSSH 格式加密私钥的短语
//         错误会退化成这个码：openssl.c 该路径吞掉内部 KEYFILE_AUTH_FAILED；
//         垃圾私钥同码但 message 不同，二者均属「本地私钥不可用」，
//         UI 处理一致）→ kAuthFailedPassphrase；
//       PUBLICKEY_UNVERIFIED 且 message 含「Callback returned error」（带公钥数据时
//         签名阶段本地解密失败，userauth.c:1771 把 sign 回调的真实错误吞成这个码）
//         → kAuthFailedPassphrase；
//       其余（AUTHENTICATION_FAILED 服务器拒绝未授权密钥、PUBLICKEY_UNVERIFIED 的
//         服务端签名校验失败等）→ kAuthFailedKey；
//   - kKeyboardInteractive：一律 kAuthFailedInteractive；
//   传输层异常（对端断开等）由会话断线检测另行兜底，不会以认证码掩盖。
SshSessionError mapAuthError(int libssh2Error, AuthMethod method, const std::string &message);

const char *toString(AuthMethod method);

} // namespace ssh
} // namespace sshclient
