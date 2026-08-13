#!/usr/bin/env bash
# build-deps.sh —— libssh2 / libvterm / libargon2 交叉编译到 HarmonyOS NEXT（OHOS）
#
# 依赖：先运行 scripts/build-openssl.sh（libssh2 需要其产出的 libcrypto.a 与头文件）。
# 配方依据：docs/DESIGN.md §3.4（版本选型）/§3.5（cmake 参数）。
#
# 用法（在 WSL 内运行）：
#   bash scripts/build-deps.sh                  # 全部库 × 全部 ABI
#   ABIS="x86_64" bash scripts/build-deps.sh    # 只构建单个 ABI
#
# 可调环境变量（均有默认值）：
#   OHOS_NDK      OHOS NDK native 目录     默认 ~/ohos-probe/ndk/native
#   ABIS          ABI 列表                 默认 "arm64-v8a x86_64"
#   PROJECT_ROOT  项目根目录               默认取脚本上级目录
#   BUILD_ROOT    中间构建目录             默认 ~/ohos-probe/build/deps
#   DOWNLOAD_DIR  源码包缓存目录           默认 ~/ohos-probe/build/downloads（幂等复用）
#   JOBS          并行编译数               默认 nproc
#
# 产物（统一布局，见 docs/NATIVE-BUILD.md）：
#   entry/src/main/cpp/prebuilt/<abi>/lib/       libcrypto.a(由 N1 产出) libssh2.a libvterm.a libargon2.a
#   entry/src/main/cpp/prebuilt/<abi>/include/   openssl/ libssh2.h libssh2_sftp.h vterm.h vterm_keycodes.h argon2.h
#
# 幂等性：下载缓存复用（已存在且非空则跳过）；每个库每次全新解压到 BUILD_ROOT 下
# 的独立目录重新编译，可任意重跑。编译在 WSL home 进行，仅产物 cp 到 Windows 挂载目录。

set -euo pipefail

OHOS_NDK="${OHOS_NDK:-$HOME/ohos-probe/ndk/native}"
ABIS="${ABIS:-arm64-v8a x86_64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/ohos-probe/build/deps}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/ohos-probe/build/downloads}"
JOBS="${JOBS:-$(nproc)}"

LLVM_BIN="$OHOS_NDK/llvm/bin"
TOOLCHAIN="$OHOS_NDK/build/cmake/ohos.toolchain.cmake"
PREBUILT="$PROJECT_ROOT/entry/src/main/cpp/prebuilt"

# 版本（§3.4）
LIBSSH2_VER=1.11.1
LIBVTERM_VER=0.3.3
ARGON2_VER=20190702

[ -f "$TOOLCHAIN" ] || { echo "错误：找不到 OHOS 工具链文件 $TOOLCHAIN" >&2; exit 1; }
mkdir -p "$DOWNLOAD_DIR" "$BUILD_ROOT"

# ---------- 通用函数 ----------

# download <输出文件> <url1> [url2 ...]：按顺序尝试镜像，任一成功即返回
download() {
  local out="$1"; shift
  if [ -s "$out" ]; then
    echo "[缓存] $(basename "$out") 已存在，跳过下载"
    return 0
  fi
  local url
  for url in "$@"; do
    echo "[下载] $url"
    if curl -fsSL --connect-timeout 20 --max-time 600 -o "$out.tmp" "$url"; then
      mv "$out.tmp" "$out"
      return 0
    fi
    echo "  该镜像失败，尝试下一个……" >&2
  done
  rm -f "$out.tmp"
  echo "错误：所有镜像均失败：$(basename "$out")" >&2
  return 1
}

cc_of() {
  case "$1" in
    arm64-v8a) echo "$LLVM_BIN/aarch64-unknown-linux-ohos-clang" ;;
    x86_64)    echo "$LLVM_BIN/x86_64-unknown-linux-ohos-clang" ;;
    *) echo "错误：不支持的 ABI：$1" >&2; exit 1 ;;
  esac
}

# ABI → sysroot 内的 GNU 风格三元组（libz.so 等所在目录按三元组分）
triplet_of() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-ohos" ;;
    x86_64)    echo "x86_64-linux-ohos" ;;
  esac
}

# ---------- libssh2（CMake + ohos.toolchain.cmake，OpenSSL 后端）----------
build_libssh2() {
  local abi="$1"
  local tarball="$DOWNLOAD_DIR/libssh2-$LIBSSH2_VER.tar.gz"
  # 主站 + GitHub release 镜像
  download "$tarball" \
    "https://www.libssh2.org/download/libssh2-$LIBSSH2_VER.tar.gz" \
    "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VER/libssh2-$LIBSSH2_VER.tar.gz"

  local src_dir="$BUILD_ROOT/$abi/libssh2-$LIBSSH2_VER"
  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar xzf "$tarball" -C "$BUILD_ROOT/$abi"

  # 本 ABI 的 OpenSSL prebuilt（libcrypto.a + include/openssl）
  local ssl_root="$PREBUILT/$abi"
  [ -f "$ssl_root/lib/libcrypto.a" ] || {
    echo "错误：缺 $ssl_root/lib/libcrypto.a，请先运行 scripts/build-openssl.sh" >&2; exit 1; }

  # -DCMAKE_POSITION_INDEPENDENT_CODE=ON：静态库最终链进 libssh_core.so，必须 PIC
  # -DBUILD_STATIC_LIBS=ON / BUILD_SHARED_LIBS=OFF：只要静态库
  # -DENABLE_ZLIB_COMPRESSION=ON：zlib 用 NDK sysroot 自带的（DESIGN §3.4）
  # -DOPENSSL_CRYPTO_LIBRARY / -DOPENSSL_INCLUDE_DIR 显式指定：
  #   ohos.toolchain.cmake 设了 CMAKE_FIND_ROOT_PATH_MODE_LIBRARY/INCLUDE ONLY，
  #   FindOpenSSL 的 OPENSSL_ROOT_DIR 提示会被限制在 NDK 目录内而找不到项目里的
  #   prebuilt；直接把两个结果变量写进 cache 后 find_library/find_path 变为空操作。
  #   libssh2 只链接 OpenSSL::Crypto（不碰 libssl），与 OpenSSL 侧的 no-ssl 裁剪一致。
  # -DZLIB_INCLUDE_DIR / -DZLIB_LIBRARY 同理：sysroot 里的 zlib.h / libz.so 不在
  #   find_path 的默认后缀命中范围，也显式写进 cache。
  cmake -S "$src_dir" -B "$src_dir/build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DOHOS_ARCH="$abi" -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_CRYPTO_LIBRARY="$ssl_root/lib/libcrypto.a" \
    -DOPENSSL_INCLUDE_DIR="$ssl_root/include" \
    -DZLIB_INCLUDE_DIR="$OHOS_NDK/sysroot/usr/include" \
    -DZLIB_LIBRARY="$OHOS_NDK/sysroot/usr/lib/$(triplet_of "$abi")/libz.so" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF \
    -DENABLE_ZLIB_COMPRESSION=ON
  cmake --build "$src_dir/build" -j"$JOBS"

  mkdir -p "$PREBUILT/$abi/lib" "$PREBUILT/$abi/include"
  cp -a "$src_dir/build/src/libssh2.a" "$PREBUILT/$abi/lib/"
  cp -a "$src_dir/include/libssh2.h" "$src_dir/include/libssh2_sftp.h" "$src_dir/include/libssh2_publickey.h" \
    "$PREBUILT/$abi/include/"
  echo "[完成] libssh2 $LIBSSH2_VER → $abi"
}

# ---------- libvterm（手写 Makefile 项目，直接编译全部 .c 再 ar 打包，最稳）----------
build_libvterm() {
  local abi="$1"
  local tarball="$DOWNLOAD_DIR/libvterm-$LIBVTERM_VER.tar.gz"
  download "$tarball" \
    "https://www.leonerd.org.uk/code/libvterm/libvterm-$LIBVTERM_VER.tar.gz" \
    "https://launchpad.net/libvterm/trunk/v$LIBVTERM_VER/+download/libvterm-$LIBVTERM_VER.tar.gz"

  local src_dir="$BUILD_ROOT/$abi/libvterm-$LIBVTERM_VER"
  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar xzf "$tarball" -C "$BUILD_ROOT/$abi"

  local cc; cc="$(cc_of "$abi")"
  local obj_dir="$src_dir/obj"
  mkdir -p "$obj_dir"
  local f
  for f in "$src_dir"/src/*.c; do
    "$cc" -O2 -fPIC -std=c99 -I"$src_dir/include" -I"$src_dir/src" \
      -c "$f" -o "$obj_dir/$(basename "${f%.c}").o"
  done
  "$LLVM_BIN/llvm-ar" rcs "$obj_dir/libvterm.a" "$obj_dir"/*.o
  "$LLVM_BIN/llvm-ranlib" "$obj_dir/libvterm.a"

  mkdir -p "$PREBUILT/$abi/lib" "$PREBUILT/$abi/include"
  cp -a "$obj_dir/libvterm.a" "$PREBUILT/$abi/lib/"
  cp -a "$src_dir/include/vterm.h" "$src_dir/include/vterm_keycodes.h" "$PREBUILT/$abi/include/"
  echo "[完成] libvterm $LIBVTERM_VER → $abi"
}

# ---------- libargon2（上游 Makefile，CC/CFLAGS 由命令行注入；AR 用 shim 换成 llvm-ar）----------
build_libargon2() {
  local abi="$1"
  local tarball="$DOWNLOAD_DIR/argon2-$ARGON2_VER.tar.gz"
  download "$tarball" \
    "https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/$ARGON2_VER.tar.gz"

  local src_dir="$BUILD_ROOT/$abi/phc-winner-argon2-$ARGON2_VER"
  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar xzf "$tarball" -C "$BUILD_ROOT/$abi"

  # Makefile 里 ar 是硬编码（`ar rcs`），做一个 ar → llvm-ar 的 shim 目录放到 PATH 最前，
  # 保证归档器与目标架构一致
  local shim="$BUILD_ROOT/$abi/.shim"
  mkdir -p "$shim"
  ln -sf "$LLVM_BIN/llvm-ar" "$shim/ar"

  # CFLAGS 命令行注入（会覆盖 Makefile 里的 +=，线程支持 -pthread 由我们显式给出；
  # OHOS musl 有 pthread，不需要 NO_THREADS=1）
  # OPTTARGET=generic：交叉 clang 不认 -march=native，OPTTEST 自动失败回退到
  # 可移植实现 ref.c——ARM 上 upstream 本来也只有 ref 实现，x86_64 同样走 ref，
  # 保证两个 ABI 行为一致（保险库 KDF 的正确性优先于这点性能差异）
  local cc; cc="$(cc_of "$abi")"
  PATH="$shim:$PATH" make -C "$src_dir" libargon2.a -j"$JOBS" \
    CC="$cc" OPTTARGET=generic \
    CFLAGS="-std=c89 -O3 -Wall -Iinclude -Isrc -pthread -fPIC"

  mkdir -p "$PREBUILT/$abi/lib" "$PREBUILT/$abi/include"
  cp -a "$src_dir/libargon2.a" "$PREBUILT/$abi/lib/"
  cp -a "$src_dir/include/argon2.h" "$PREBUILT/$abi/include/"
  echo "[完成] libargon2 $ARGON2_VER → $abi"
}

# ---------- 主流程 ----------
for abi in $ABIS; do
  echo "=============================================================="
  echo "  构建依赖 → $abi"
  echo "=============================================================="
  mkdir -p "$BUILD_ROOT/$abi"
  build_libssh2 "$abi"
  build_libvterm "$abi"
  build_libargon2 "$abi"
done

# ---------- 构建后自检 ----------
# 1) 每个产物用 llvm-readelf 确认目标架构
# 2) 链接冒烟测试：用 OHOS 交叉编译器把 libssh2.a + libcrypto.a 链成一个 .so，
#    链接器会按需解析归档成员——能链过即证明除 libc/libz 系统符号外无未定义符号
#    （比逐个比对 nm 输出更可靠的判据）
echo
echo "================ 自检 ================"
fail=0
for abi in $ABIS; do
  case "$abi" in
    arm64-v8a) want="AArch64" ;;
    x86_64)    want="X86-64" ;;
  esac
  for lib in libcrypto.a libssh2.a libvterm.a libargon2.a; do
    f="$PREBUILT/$abi/lib/$lib"
    if [ ! -f "$f" ]; then echo "[FAIL] $abi 缺 $lib"; fail=1; continue; fi
    mach="$("$LLVM_BIN/llvm-readelf" -h "$f" 2>/dev/null | grep -m1 Machine || true)"
    echo "[$abi] $lib  $mach"
    echo "$mach" | grep -q "$want" || { echo "[FAIL] $abi/$lib 架构不符（期望 $want）"; fail=1; }
  done

  echo "[$abi] 链接冒烟测试（libssh2.a + libcrypto.a + -lz → .so）"
  link_dir="$(mktemp -d)"
  cat > "$link_dir/t.c" <<'EOF'
#include <libssh2.h>
#include <openssl/evp.h>
/* 引用两个库的入口符号，强迫链接器解析依赖闭包 */
int smoke(void) {
  (void)EVP_sha256();
  return libssh2_init(0);
}
EOF
  if "$(cc_of "$abi")" -shared -fPIC -Wl,--no-undefined \
      -I"$PREBUILT/$abi/include" \
      "$link_dir/t.c" \
      "$PREBUILT/$abi/lib/libssh2.a" "$PREBUILT/$abi/lib/libcrypto.a" \
      -lz -o "$link_dir/smoke.so" 2> "$link_dir/err.log"; then
    echo "  链接成功：$("$LLVM_BIN/llvm-readelf" -h "$link_dir/smoke.so" | grep -m1 Machine)"
    echo "  NEEDED: $("$LLVM_BIN/llvm-readelf" -d "$link_dir/smoke.so" | grep NEEDED || echo 无)"
  else
    echo "[FAIL] $abi 链接失败：" >&2
    cat "$link_dir/err.log" >&2
    fail=1
  fi
  rm -rf "$link_dir"
done
[ "$fail" -eq 0 ] || { echo "自检未通过" >&2; exit 1; }
echo "自检通过。"
