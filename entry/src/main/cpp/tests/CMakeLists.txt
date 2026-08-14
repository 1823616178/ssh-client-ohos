# native 单元测试独立构建（任务 N4，DESIGN §9）。
#
# 与 OHOS 产物构建（../CMakeLists.txt）完全分离：那边由 ohos.toolchain.cmake
# 交叉编译出 libssh_core.so 进 HAP；这边用宿主机 clang 直接编译跑 GoogleTest。
# 入口脚本是 scripts/run-native-tests.sh（检测/下载 GoogleTest、配置、构建、运行）。
#
# 关键约定——纯逻辑与 NAPI 解耦：
#   被测代码（crypto/ term/ io/ ssh/ 下的纯逻辑，以及 bridge/ 下不含 napi 的
#   纯逻辑件：handle_table.h / data_aggregator.*）只依赖 C/C++ 标准库与
#   prebuilt 第三方库头文件，禁止 include <napi/native_api.h> / <hilog/log.h>；
#   NAPI 胶水只允许出现在 bridge/session_bridge.* 与 napi_init.cpp。
#   同一份纯逻辑源码同时编进 libssh_core.so 与本测试目标，保证两侧行为一致。
cmake_minimum_required(VERSION 3.16)
project(ssh_core_tests CXX)

# 可选 sanitizer（仅宿主机模式有意义）：SANITIZE=address 时由
# scripts/run-native-tests.sh 注入 -DSSH_TESTS_SANITIZE=address；
# 放在 FetchContent 之前，googletest 一并插桩，避免 ASan 误报漏报
set(SSH_TESTS_SANITIZE "" CACHE STRING "宿主机测试 sanitizer：空 | address")
if(SSH_TESTS_SANITIZE STREQUAL "address")
    add_compile_options(-fsanitize=address -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# GoogleTest 获取（默认 FetchContent 拉 1.15.2，URL 由 scripts/run-native-tests.sh
# 指向本地缓存 tarball；手工 cmake 时默认从 GitHub 下载）。
# -DSSH_TESTS_SYSTEM_GTEST=ON 时改用 find_package（宿主机已装 GTest 的场景）。
option(SSH_TESTS_SYSTEM_GTEST "用 find_package 找系统 GTest，而非 FetchContent 拉取" OFF)

if(SSH_TESTS_SYSTEM_GTEST)
    find_package(GTest REQUIRED)
    set(GTEST_LIBS GTest::gtest GTest::gtest_main)
else()
    include(FetchContent)
    set(GOOGLETEST_URL
        "https://github.com/google/googletest/releases/download/v1.15.2/googletest-1.15.2.tar.gz"
        CACHE STRING "googletest 源码包 URL 或本地 tarball 路径")
    set(GOOGLETEST_URL_HASH "" CACHE STRING "tarball 的 SHA256（形如 SHA256=<hex>），脚本会传入")
    if(GOOGLETEST_URL_HASH)
        FetchContent_Declare(googletest URL "${GOOGLETEST_URL}" URL_HASH "${GOOGLETEST_URL_HASH}")
    else()
        FetchContent_Declare(googletest URL "${GOOGLETEST_URL}")
    endif()
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE) # Windows MSVC 约定，对 Linux/OHOS 无害
    set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
    set(BUILD_GMOCK OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)
    set(GTEST_LIBS gtest_main)
endif()

set(CPP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)

# 被测纯逻辑源码：新增测试对象时在此追加，并同步加进 ../CMakeLists.txt 的
# NATIVE_SOURCES（同一份文件，两处编译）。
set(TESTED_SOURCES
    ${CPP_ROOT}/crypto/aad.cpp
    ${CPP_ROOT}/io/EventLoop.cpp
    ${CPP_ROOT}/io/SessionThread.cpp
    ${CPP_ROOT}/bridge/data_aggregator.cpp
    ${CPP_ROOT}/ssh/session.cpp
    ${CPP_ROOT}/ssh/hostkey.cpp
    ${CPP_ROOT}/ssh/auth.cpp
    ${CPP_ROOT}/ssh/agent.cpp
    ${CPP_ROOT}/ssh/channel.cpp
)

# ---- N6 ssh/ 会话层的 libssh2 依赖 ----
# 宿主机：scripts/setup-host-deps.sh 产出的静态 libssh2 + 系统 OpenSSL + z
#        （仓库 prebuilt/ 是 OHOS target，宿主测试不能链）；
# 交叉（ohos-x86_64）：复用仓库 prebuilt/${OHOS_ARCH} 的头与静态库，只编不跑。
option(SSH_TESTS_INTEGRATION "编译真实 sshd 集成测试用例（运行时找不到 sshd 则 GTEST_SKIP）" ON)
set(SSH_TESTS_HOST_LIBSSH2 "$ENV{HOME}/ohos-probe/build/host-deps/libssh2"
    CACHE PATH "宿主机版 libssh2 安装前缀（scripts/setup-host-deps.sh 产物）")

if(CMAKE_CROSSCOMPILING)
    # 交叉目标无法在宿主机执行，集成用例编译但不启用（运行时更不会执行）
    set(SSH_TESTS_INTEGRATION OFF)
    set(LIBSSH2_INCLUDE_DIR ${CPP_ROOT}/prebuilt/${OHOS_ARCH}/include)
    set(LIBSSH2_LIBS
        ${CPP_ROOT}/prebuilt/${OHOS_ARCH}/lib/libssh2.a
        ${CPP_ROOT}/prebuilt/${OHOS_ARCH}/lib/libcrypto.a
        z)
else()
    if(NOT EXISTS "${SSH_TESTS_HOST_LIBSSH2}/lib/libssh2.a"
            OR NOT EXISTS "${SSH_TESTS_HOST_LIBSSH2}/include/libssh2.h")
        message(FATAL_ERROR
            "找不到宿主机版 libssh2（${SSH_TESTS_HOST_LIBSSH2}）。\n"
            "请先运行 scripts/setup-host-deps.sh（WSL 内），"
            "或用 -DSSH_TESTS_HOST_LIBSSH2=<前缀> 指定。")
    endif()
    set(LIBSSH2_INCLUDE_DIR ${SSH_TESTS_HOST_LIBSSH2}/include)
    find_package(OpenSSL REQUIRED)
    set(LIBSSH2_LIBS ${SSH_TESTS_HOST_LIBSSH2}/lib/libssh2.a OpenSSL::Crypto z)
endif()

add_executable(ssh_core_tests
    aad_test.cpp
    event_loop_test.cpp
    session_thread_test.cpp
    ssh_session_test.cpp
    hostkey_test.cpp
    auth_test.cpp
    agent_test.cpp
    channel_test.cpp
    bridge_logic_test.cpp
    reconnect_policy_test.cpp
    keepalive_test.cpp
    error_codes_test.cpp
    ${TESTED_SOURCES}
)
target_include_directories(ssh_core_tests PRIVATE ${CPP_ROOT} ${LIBSSH2_INCLUDE_DIR})
if(SSH_TESTS_INTEGRATION)
    target_compile_definitions(ssh_core_tests PRIVATE SSH_TESTS_INTEGRATION=1)
endif()

# std::thread / std::mutex 需要 pthread（OHOS musl 与宿主 Linux 均适用）
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)
# 链接顺序：被测对象 → libssh2 → crypto/z → gtest（静态库依赖者在前）
target_link_libraries(ssh_core_tests PRIVATE ${LIBSSH2_LIBS} ${GTEST_LIBS} Threads::Threads)

# 交叉编译（ohos target）时测试二进制无法在宿主机执行，不能在建后跑 --gtest_list_tests
if(NOT CMAKE_CROSSCOMPILING)
    include(GoogleTest)
    gtest_discover_tests(ssh_core_tests)
endif()
