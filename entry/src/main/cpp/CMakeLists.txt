cmake_minimum_required(VERSION 3.16)
project(ssh_client_ohos CXX)

# libssh_core.so：原生层唯一产物（DESIGN §3.5）。
# 目录规划（按 TASKS N4~N8 逐步填充，新增源文件加入下方显式列表即生效）：
#   bridge/   NAPI 桥接层（方法分发、线程切换）
#   ssh/      libssh2 会话/通道封装
#   term/     libvterm 终端仿真封装
#   crypto/   argon2 私钥口令派生
#   io/       socket 异步 IO
set(NATIVE_SOURCES
    napi_init.cpp
    # bridge/
    # ssh/
    ssh/session.cpp
    ssh/hostkey.cpp
    # term/
    # crypto/
    crypto/aad.cpp
    # io/
    io/EventLoop.cpp
    io/SessionThread.cpp
)

add_library(ssh_core SHARED ${NATIVE_SOURCES})

# 预编译静态依赖（scripts/build-deps.sh 交叉编译产物，全部 -fPIC），
# 按当前 ABI（OHOS_ARCH 由 ohos.toolchain.cmake 注入）选择 prebuilt 目录。
set(PREBUILT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${OHOS_ARCH})

foreach(lib IN ITEMS ssh2 vterm argon2 crypto)
    add_library(prebuilt_${lib} STATIC IMPORTED)
    set_target_properties(prebuilt_${lib} PROPERTIES
        IMPORTED_LOCATION ${PREBUILT_DIR}/lib/lib${lib}.a)
endforeach()

target_include_directories(ssh_core PRIVATE ${PREBUILT_DIR}/include)

# 链接顺序：依赖者在前。libssh2 依赖 libcrypto 与 z；vterm/argon2 独立；
# ace_napi.z 为 NAPI 运行时，hilog_ndk.z 供后续日志封装使用。
target_link_libraries(ssh_core PRIVATE
    prebuilt_ssh2
    prebuilt_vterm
    prebuilt_argon2
    prebuilt_crypto
    z
    ace_napi.z
    hilog_ndk.z
)

# 预编译静态库的对象未带 -fvisibility=hidden，OpenSSL 等符号默认全量导出，
# 既污染动态符号表又可能被进程中同名库 interpose；用 version script 收敛导出。
target_link_options(ssh_core PRIVATE
    -Wl,--gc-sections
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/libssh_core.map"
)
