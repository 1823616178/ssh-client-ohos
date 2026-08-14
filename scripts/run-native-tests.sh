#!/usr/bin/env bash
# run-native-tests.sh —— native 单元测试入口（任务 N4，DESIGN §9）
#
# 在 npm/hvigor 之外独立构建并运行 entry/src/main/cpp/tests/ 下的 GoogleTest，
# CI 直接调用本脚本即可：退出码 0 = 全部通过，非 0 = 配置/构建/测试任一失败。
#
# 用法（WSL / Linux CI 内）：
#   bash scripts/run-native-tests.sh                     # 宿主机 clang 构建并运行全部测试
#   SANITIZE=address bash scripts/run-native-tests.sh    # 宿主机 + AddressSanitizer（独立构建目录）
#   TARGET=ohos-x86_64 bash scripts/run-native-tests.sh  # 交叉编译 x86_64-linux-ohos，只编不跑
# Windows 侧驱动：
#   wsl -d Ubuntu -- bash /mnt/c/Users/lx182/DevEcoStudioProjects/ssh_client_ohos/scripts/run-native-tests.sh
#
# 可调环境变量（默认值即本机约定）：
#   TARGET           host（默认）| ohos-x86_64
#   BUILD_ROOT       构建目录根    默认 entry/src/main/cpp/tests/build（已被 .gitignore 的 **/build 覆盖）
#   DOWNLOAD_DIR     源码包缓存    默认 ~/ohos-probe/build/downloads（与 build-deps.sh 共用）
#   GOOGLETEST_SRC   本地 googletest 源码树或 tarball 路径；设置后跳过一切下载
#   SYSTEM_GTEST     ON 时用 find_package 找系统 GTest（需宿主机已装），默认 OFF 走 FetchContent
#   OHOS_NDK         OHOS NDK native 目录（仅 TARGET=ohos-x86_64 用），默认 ~/ohos-probe/ndk/native
#   SANITIZE         宿主机 sanitizer：空（默认）| address（走独立构建目录 host-asan，不含交叉目标）
#   JOBS             并行编译数    默认 nproc
#   CC / CXX         宿主机编译器  默认优先 clang/clang++（与 OHOS 工具链同族），缺失回退 gcc/g++
#
# GoogleTest 获取策略（版本 1.15.2，按优先级）：
#   1. GOOGLETEST_SRC 指定的本地路径；
#   2. DOWNLOAD_DIR 缓存的 tarball（存在即复用，幂等）；
#   3. curl 下载 GitHub release；失败回退 gitee 镜像 git clone（公司网络拦 GitHub 时用）；
#      两者都不通时给出明确报错与手工放置路径。
#   另外 SYSTEM_GTEST=ON 时完全跳过下载，用 find_package(GTest REQUIRED)。

set -euo pipefail

TARGET="${TARGET:-host}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
CPP_DIR="$PROJECT_ROOT/entry/src/main/cpp"
BUILD_ROOT="${BUILD_ROOT:-$CPP_DIR/tests/build}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/ohos-probe/build/downloads}"
SYSTEM_GTEST="${SYSTEM_GTEST:-OFF}"
SANITIZE="${SANITIZE:-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
GTEST_VER=1.15.2

log() { echo "[native-tests] $*"; }
die() { echo "[native-tests] 错误：$*" >&2; exit 1; }

command -v cmake >/dev/null || die "找不到 cmake（Ubuntu: apt install cmake）"

# 宿主机编译器：优先 clang（与 OHOS NDK 的 llvm 同族），缺失回退 gcc
if [ "$TARGET" = "host" ] && [ -z "${CC:-}" ]; then
  if command -v clang >/dev/null; then
    CC=clang; CXX=clang++
  elif command -v gcc >/dev/null; then
    CC=gcc; CXX=g++
  else
    die "找不到 clang 或 gcc（Ubuntu: apt install clang）"
  fi
  export CC CXX
fi

# 组装 GTEST_CMAKE_ARGS（数组）：决定 FetchContent 用哪份 googletest 源码
GTEST_CMAKE_ARGS=()
ensure_gtest() {
  if [ "$SYSTEM_GTEST" = "ON" ]; then
    log "SYSTEM_GTEST=ON：由 CMake find_package(GTest REQUIRED) 查找系统安装"
    GTEST_CMAKE_ARGS=(-DSSH_TESTS_SYSTEM_GTEST=ON)
    return
  fi

  if [ -n "${GOOGLETEST_SRC:-}" ]; then
    log "使用 GOOGLETEST_SRC=$GOOGLETEST_SRC"
    if [ -d "$GOOGLETEST_SRC" ]; then
      GTEST_CMAKE_ARGS=(-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$GOOGLETEST_SRC")
    else
      GTEST_CMAKE_ARGS=(-DGOOGLETEST_URL="$GOOGLETEST_SRC")
    fi
    return
  fi

  mkdir -p "$DOWNLOAD_DIR"
  local tarball="$DOWNLOAD_DIR/googletest-$GTEST_VER.tar.gz"
  if [ ! -s "$tarball" ]; then
    log "下载 googletest $GTEST_VER（GitHub release）"
    if curl -fsSL --connect-timeout 20 --max-time 600 -o "$tarball.tmp" \
        "https://github.com/google/googletest/releases/download/v$GTEST_VER/googletest-$GTEST_VER.tar.gz"; then
      mv "$tarball.tmp" "$tarball"
    else
      rm -f "$tarball.tmp"
      log "GitHub 下载失败，回退 gitee 镜像（git clone）"
      local mirror="$DOWNLOAD_DIR/googletest-$GTEST_VER-src"
      rm -rf "$mirror"
      git clone --depth 1 --branch "v$GTEST_VER" \
        https://gitee.com/mirrors/googletest.git "$mirror" \
        || die "googletest 获取失败：GitHub 与 gitee 均不可达。请手工下载 googletest-$GTEST_VER.tar.gz 放到 $DOWNLOAD_DIR/（或设 GOOGLETEST_SRC），重跑本脚本"
      GTEST_CMAKE_ARGS=(-DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$mirror")
      return
    fi
  else
    log "复用缓存 $tarball"
  fi

  # 实测哈希随 tarball 传给 CMake URL_HASH，防下载截断/污染进入构建
  local hash
  hash="$(sha256sum "$tarball" | cut -d' ' -f1)"
  GTEST_CMAKE_ARGS=(-DGOOGLETEST_URL="$tarball" -DGOOGLETEST_URL_HASH="SHA256=$hash")
}

ensure_gtest

case "$TARGET" in
  host)
    BUILD_DIR="$BUILD_ROOT/host"
    # N6：ssh/ 会话层单测需要宿主机版 libssh2（prebuilt/ 是 OHOS target，不能链）；
    # 集成测试另需测试用 sshd。setup-host-deps.sh 幂等补齐两者，产物不进仓库。
    HOST_DEPS_ROOT="${HOST_DEPS_ROOT:-$HOME/ohos-probe/build/host-deps}"
    if [ ! -f "$HOST_DEPS_ROOT/libssh2/lib/libssh2.a" ]; then
      log "宿主版 libssh2 缺失，运行 scripts/setup-host-deps.sh 补齐"
      bash "$PROJECT_ROOT/scripts/setup-host-deps.sh"
    fi
    HOST_LIBSSH2_CMAKE_ARGS=(-DSSH_TESTS_HOST_LIBSSH2="$HOST_DEPS_ROOT/libssh2")
    SAN_CMAKE_ARGS=()
    if [ -n "$SANITIZE" ]; then
      [ "$SANITIZE" = "address" ] || die "未知 SANITIZE='$SANITIZE'（可选：address）"
      BUILD_DIR="$BUILD_ROOT/host-asan" # 与普通构建分离，互不污染缓存
      SAN_CMAKE_ARGS=(-DSSH_TESTS_SANITIZE=address)
    fi
    log "配置（宿主机，CC=$CC CXX=$CXX，gtest $GTEST_VER${SANITIZE:+，sanitizer=$SANITIZE}）→ $BUILD_DIR"
    cmake -S "$CPP_DIR/tests" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Debug \
      "${GTEST_CMAKE_ARGS[@]}" "${HOST_LIBSSH2_CMAKE_ARGS[@]}" "${SAN_CMAKE_ARGS[@]}"
    log "构建（-j$JOBS）"
    cmake --build "$BUILD_DIR" -j "$JOBS"
    log "运行全部测试（junit XML → $BUILD_DIR/test-results.xml）"
    # 退出码原样向上传递：set -e 下测试失败则脚本非 0 退出
    "$BUILD_DIR/ssh_core_tests" --gtest_output="xml:$BUILD_DIR/test-results.xml"
    log "全部测试通过。报告：$BUILD_DIR/test-results.xml"
    ;;

  ohos-x86_64)
    [ -z "$SANITIZE" ] || die "SANITIZE 仅支持宿主机模式（交叉目标无对应 sanitizer 运行时）"
    OHOS_NDK="${OHOS_NDK:-$HOME/ohos-probe/ndk/native}"
    TOOLCHAIN="$OHOS_NDK/build/cmake/ohos.toolchain.cmake"
    [ -f "$TOOLCHAIN" ] || die "找不到 OHOS 工具链文件 $TOOLCHAIN（设 OHOS_NDK 指向 NDK native 目录）"
    BUILD_DIR="$BUILD_ROOT/ohos-x86_64"
    log "配置（交叉编译 OHOS_ARCH=x86_64，只编不跑）→ $BUILD_DIR"
    cmake -S "$CPP_DIR/tests" -B "$BUILD_DIR" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" -DOHOS_ARCH=x86_64 \
      -DCMAKE_BUILD_TYPE=Release "${GTEST_CMAKE_ARGS[@]}"
    log "构建（-j$JOBS）"
    cmake --build "$BUILD_DIR" -j "$JOBS"
    log "交叉编译通过：$BUILD_DIR/ssh_core_tests"
    log "已知限制：x86_64-linux-ohos 二进制依赖 OHOS musl 运行时，WSL/Linux 宿主机无法直接执行；"
    log "如需运行请投到 x86_64 模拟器/真机（hdc + 手动执行），宿主机验证以 TARGET=host 为准。"
    ;;

  *)
    die "未知 TARGET='$TARGET'（可选：host | ohos-x86_64）"
    ;;
esac
