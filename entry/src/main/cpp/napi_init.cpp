/**
 * NAPI 模块入口（任务 N3）：向 ArkTS 暴露原生依赖的版本查询，
 * 作为 CMake 集成与静态链接的端到端验证点。
 * 所有接口失败时返回空串，不向 ArkTS 抛异常。
 */
#include "napi/native_api.h"

#define LOG_DOMAIN 0x0001
#define LOG_TAG "ssh_core"
#include "hilog/log.h"

#include "libssh2.h"
#include "openssl/crypto.h"
#include "vterm.h"
#include "argon2.h"

#include <cstdio>

namespace {

// 安全地把 C 字符串包成 napi_string；nullptr 或失败一律返回空串
napi_value MakeString(napi_env env, const char *str)
{
    napi_value result = nullptr;
    const char *safe = (str != nullptr) ? str : "";
    if (napi_create_string_utf8(env, safe, NAPI_AUTO_LENGTH, &result) != napi_ok) {
        napi_create_string_utf8(env, "", 0, &result);
    }
    return result;
}

napi_value GetLibssh2Version(napi_env env, napi_callback_info /*info*/)
{
    // libssh2_version 要求先初始化；flags=0 表示不使用额外特性
    if (libssh2_init(0) != 0) {
        OH_LOG_ERROR(LOG_APP, "libssh2_init failed");
        return MakeString(env, "");
    }
    // req_version_num=0 表示接受任何版本，返回当前库版本串
    return MakeString(env, libssh2_version(0));
}

napi_value GetOpensslVersion(napi_env env, napi_callback_info /*info*/)
{
    return MakeString(env, OpenSSL_version(OPENSSL_VERSION));
}

napi_value GetVtermVersion(napi_env env, napi_callback_info /*info*/)
{
    // libvterm 无运行时版本查询（vterm_check_version 仅做兼容性校验），
    // 版本取自编译期宏 VTERM_VERSION_MAJOR/MINOR/PATCH
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%d.%d.%d",
                  VTERM_VERSION_MAJOR, VTERM_VERSION_MINOR, VTERM_VERSION_PATCH);
    return MakeString(env, buf);
}

napi_value GetArgon2Version(napi_env env, napi_callback_info /*info*/)
{
    // libargon2 无版本 API；argon2.h 的 ARGON2_VERSION_NUMBER 是 Argon2
    // 编码版本（0x13 = v1.3），按十六进制高低位还原为 "1.3"
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%x.%x",
                  (ARGON2_VERSION_NUMBER >> 4) & 0xF, ARGON2_VERSION_NUMBER & 0xF);
    return MakeString(env, buf);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"getLibssh2Version", nullptr, GetLibssh2Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getOpensslVersion", nullptr, GetOpensslVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVtermVersion", nullptr, GetVtermVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getArgon2Version", nullptr, GetArgon2Version, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "napi_define_properties failed");
    }
    return exports;
}

napi_module g_sshCoreModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "ssh_core",
    .nm_priv = nullptr,
    .reserved = {0},
};

} // namespace

// 编译选项含 -fvisibility=hidden，注册函数需显式导出，确保 .so 加载时构造函数执行
extern "C" __attribute__((constructor)) __attribute__((visibility("default"))) void RegisterSshCoreModule()
{
    napi_module_register(&g_sshCoreModule);
}
