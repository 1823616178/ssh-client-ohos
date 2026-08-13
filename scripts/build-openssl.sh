#!/usr/bin/env bash
# build-openssl.sh —— OpenSSL 3.5 交叉编译到 HarmonyOS NEXT（OHOS）
#
# 配方来源：docs/DESIGN.md §3.7（已实测通过：OpenSSL 3.5.7 → aarch64-linux-ohos，
# make EXIT=0，0 错误 0 补丁）；裁剪项与版本选择依据 §3.4/§3.5。
#
# 用法（在 WSL 内运行）：
#   bash scripts/build-openssl.sh                  # 构建全部 ABI（arm64-v8a + x86_64）
#   ABIS="x86_64" bash scripts/build-openssl.sh    # 只构建单个 ABI
#
# 可调环境变量（均有默认值，无需手工设置）：
#   OPENSSL_SRC   OpenSSL 源码目录        默认 ~/ohos-probe/openssl-3.5.7
#   OHOS_NDK      OHOS NDK native 目录    默认 ~/ohos-probe/ndk/native
#   ABIS          要构建的 ABI 列表       默认 "arm64-v8a x86_64"
#   PROJECT_ROOT  项目根目录              默认取脚本所在目录的上级
#                 （WSL 内访问 Windows 项目目录写作 /mnt/c/...）
#   BUILD_ROOT    中间构建/安装目录       默认 ~/ohos-probe/build/openssl
#   JOBS          并行编译数              默认 nproc
#
# 产物：$PROJECT_ROOT/entry/src/main/cpp/prebuilt/<abi>/
#   lib/libcrypto.a         静态库（no-ssl，只要 crypto，见 DESIGN §3.4）
#   include/openssl/*.h     头文件（按 ABI 分开，configuration.h 与架构相关）
#
# 幂等性：每次运行都删除并重建对应 ABI 的中间构建目录（全新 Configure），
# 因此可以无脑重跑；源码目录、NDK 只读不动。编译在 WSL home（BUILD_ROOT）里做，
# 只把最终产物 cp 到 Windows 挂载目录——后者写文件慢，不适合当构建目录。

set -euo pipefail

# ---------- 参数 ----------
OPENSSL_SRC="${OPENSSL_SRC:-$HOME/ohos-probe/openssl-3.5.7}"
OHOS_NDK="${OHOS_NDK:-$HOME/ohos-probe/ndk/native}"
ABIS="${ABIS:-arm64-v8a x86_64}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/ohos-probe/build/openssl}"
JOBS="${JOBS:-$(nproc)}"

LLVM_BIN="$OHOS_NDK/llvm/bin"

# ---------- 前置检查 ----------
[ -x "$OPENSSL_SRC/Configure" ] || { echo "错误：找不到 OpenSSL 源码 $OPENSSL_SRC" >&2; exit 1; }
[ -d "$OHOS_NDK/sysroot" ]      || { echo "错误：OHOS_NDK 无效：$OHOS_NDK（缺 sysroot）" >&2; exit 1; }

# 若源码树里残留旧的 in-tree 配置（本机的 openssl-3.5.7 曾被原地构建过），
# 残留的 Makefile/configdata.pm 会让 out-of-source Configure 报 "files missing"。
# 先 distclean 还原源码树；已干净时跳过。
if [ -f "$OPENSSL_SRC/Makefile" ] || [ -f "$OPENSSL_SRC/configdata.pm" ]; then
  echo "检测到源码树内的旧构建配置，执行 make distclean ..."
  (cd "$OPENSSL_SRC" && make distclean >/dev/null 2>&1) || true
fi

# ---------- ABI → Configure target / 编译器 映射 ----------
# arm64-v8a → linux-aarch64（§3.7 已实测）
# x86_64    → linux-x86_64 + x86_64-unknown-linux-ohos-clang（NDK llvm/bin 自带）
configure_target_of() {
  case "$1" in
    arm64-v8a) echo "linux-aarch64" ;;
    x86_64)    echo "linux-x86_64" ;;
    *) echo "错误：不支持的 ABI：$1（只支持 arm64-v8a / x86_64）" >&2; exit 1 ;;
  esac
}
cc_of() {
  case "$1" in
    arm64-v8a) echo "$LLVM_BIN/aarch64-unknown-linux-ohos-clang" ;;
    x86_64)    echo "$LLVM_BIN/x86_64-unknown-linux-ohos-clang" ;;
  esac
}

# ---------- 单个 ABI 的构建 ----------
build_one() {
  local abi="$1"
  local target cc build_dir install_dir dest
  target="$(configure_target_of "$abi")"
  cc="$(cc_of "$abi")"
  build_dir="$BUILD_ROOT/build/$abi"
  install_dir="$BUILD_ROOT/install/$abi"
  dest="$PROJECT_ROOT/entry/src/main/cpp/prebuilt/$abi"

  [ -x "$cc" ] || { echo "错误：编译器不存在：$cc" >&2; exit 1; }

  echo "=============================================================="
  echo "  ABI        : $abi"
  echo "  Configure  : $target"
  echo "  CC         : $cc"
  echo "  build 目录 : $build_dir"
  echo "  产物目录   : $dest"
  echo "=============================================================="

  # 幂等：全新 Configure，避免旧配置污染
  rm -rf "$build_dir" "$install_dir"
  mkdir -p "$build_dir"

  # §3.7 的实测配方：CC/AR/RANLIB/STRIP 用环境变量传给 Configure。
  # 裁剪项（§3.4：只要 libcrypto）：
  #   no-shared            只要静态库
  #   no-ssl               不编 libssl（libssh2 只需要 libcrypto）
  #   no-tests no-apps     不编测试与 openssl 命令行（OHOS 沙箱也用不上）
  #   no-docs no-legacy no-engine no-dso no-comp no-ssl3 no-weak-ssl-ciphers
  #                        砍掉 legacy provider、引擎、动态加载、压缩、旧协议
  # 末尾的 -fPIC：静态库最终要链进 libssh_core.so，目标文件必须位置无关。
  (
    cd "$build_dir"
    export CC="$cc"
    export AR="$LLVM_BIN/llvm-ar"
    export RANLIB="$LLVM_BIN/llvm-ranlib"
    export STRIP="$LLVM_BIN/llvm-strip"
    "$OPENSSL_SRC/Configure" "$target" \
      no-shared no-ssl no-tests no-apps no-docs no-legacy no-engine no-dso \
      no-comp no-ssl3 no-weak-ssl-ciphers \
      --prefix="$install_dir" \
      -fPIC
    make -j"$JOBS"
    make install_sw
  )

  # 拷贝产物到项目 prebuilt（Windows 挂载目录，只写最终产物）
  mkdir -p "$dest/lib" "$dest/include"
  cp -a "$install_dir/lib64/libcrypto.a" "$dest/lib/" 2>/dev/null \
    || cp -a "$install_dir/lib/libcrypto.a" "$dest/lib/"
  rm -rf "$dest/include/openssl"
  cp -a "$install_dir/include/openssl" "$dest/include/openssl"

  echo "[完成] $abi → $dest/lib/libcrypto.a"
}

for abi in $ABIS; do
  build_one "$abi"
done

echo "全部 ABI 构建完成。"
