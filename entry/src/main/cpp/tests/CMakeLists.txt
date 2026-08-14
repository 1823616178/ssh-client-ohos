# native 单元测试独立构建（任务 N4，DESIGN §9）。
#
# 与 OHOS 产物构建（../CMakeLists.txt）完全分离：那边由 ohos.toolchain.cmake
# 交叉编译出 libssh_core.so 进 HAP；这边用宿主机 clang 直接编译跑 GoogleTest。
# 入口脚本是 scripts/run-native-tests.sh（检测/下载 GoogleTest、配置、构建、运行）。
#
# 关键约定——纯逻辑与 NAPI 解耦：
#   被测代码（crypto/ term/ io/ ssh/ 下的纯逻辑）只依赖 C/C++ 标准库与
#   prebuilt 第三方库头文件，禁止 include <napi/native_api.h> / <hilog/log.h>；
#   NAPI 胶水只允许出现在 bridge/ 与 napi_init.cpp。
#   同一份纯逻辑源码同时编进 libssh_core.so 与本测试目标，保证两侧行为一致。
cmake_minimum_required(VERSION 3.16)
project(ssh_core_tests CXX)

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
)

add_executable(ssh_core_tests
    aad_test.cpp
    ${TESTED_SOURCES}
)
target_include_directories(ssh_core_tests PRIVATE ${CPP_ROOT})
target_link_libraries(ssh_core_tests PRIVATE ${GTEST_LIBS})

# 交叉编译（ohos target）时测试二进制无法在宿主机执行，不能在建后跑 --gtest_list_tests
if(NOT CMAKE_CROSSCOMPILING)
    include(GoogleTest)
    gtest_discover_tests(ssh_core_tests)
endif()
