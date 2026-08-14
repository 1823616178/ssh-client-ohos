#!/usr/bin/env bash
# setup-host-deps.sh —— 宿主机测试依赖一键准备（任务 N6，供 run-native-tests.sh 自动调用）
#
# 用途：native 单测里的 ssh/session.cpp 需要「宿主机版」libssh2（仓库 prebuilt/ 是
# OHOS target，宿主测试不能链）；集成测试还需要一个真实 sshd。
# 本脚本在 WSL / Linux CI 内运行，幂等，全部产物落在 $HOST_DEPS_ROOT（不进仓库）。
#
# 产物布局：
#   $HOST_DEPS_ROOT/libssh2/            宿主机版 libssh2 1.11.1（静态，链系统 OpenSSL）
#   $HOST_DEPS_ROOT/sshd/rootfs/...     免 root 解包的 openssh-server（apt download + dpkg -x）
#   $HOST_DEPS_ROOT/sshd/runtime/       运行时目录（host key、sshd_config、日志）
#
# 用法：
#   bash scripts/setup-host-deps.sh            # 全量准备（幂等，已就绪的部分跳过）
#
# 可调环境变量：
#   HOST_DEPS_ROOT   产物根目录   默认 ~/ohos-probe/build/host-deps
#   DOWNLOAD_DIR     源码包缓存   默认 ~/ohos-probe/build/downloads（与 build-deps.sh 共用）
#   JOBS             并行编译数   默认 nproc
#
# 免 root 说明：机器 sudo 需要密码时，openssh-server 用 apt-get download + dpkg -x
# 解包到用户目录即可运行（高端口 + 自有配置 + UsePAM no，sshd -d 单连接调试模式）。
# 若连 apt 都不可用，脚本只给出警告并跳过——集成测试会 GTEST_SKIP，不会失败。

set -euo pipefail

HOST_DEPS_ROOT="${HOST_DEPS_ROOT:-$HOME/ohos-probe/build/host-deps}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/ohos-probe/build/downloads}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
LIBSSH2_VER=1.11.1

log()  { echo "[host-deps] $*"; }
warn() { echo "[host-deps] 警告：$*" >&2; }
die()  { echo "[host-deps] 错误：$*" >&2; exit 1; }

# ---------------------------------------------------------------- libssh2

setup_libssh2() {
  local prefix="$HOST_DEPS_ROOT/libssh2"
  if [ -f "$prefix/lib/libssh2.a" ] && [ -f "$prefix/include/libssh2.h" ]; then
    log "libssh2 已就绪：$prefix（跳过）"
    return
  fi

  command -v cmake >/dev/null || die "找不到 cmake（Ubuntu: apt install cmake）"
  # 链接系统 OpenSSL 开发包（Ubuntu: apt install libssl-dev；已装则直接用）
  if ! pkg-config --exists openssl 2>/dev/null && [ ! -f /usr/include/openssl/ssl.h ]; then
    die "找不到系统 OpenSSL 开发头文件（Ubuntu: sudo apt install libssl-dev）"
  fi

  mkdir -p "$DOWNLOAD_DIR" "$HOST_DEPS_ROOT/src"
  local tarball="$DOWNLOAD_DIR/libssh2-$LIBSSH2_VER.tar.gz"
  if [ ! -s "$tarball" ]; then
    log "下载 libssh2 $LIBSSH2_VER"
    curl -fsSL --connect-timeout 20 --max-time 600 -o "$tarball.tmp" \
      "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VER/libssh2-$LIBSSH2_VER.tar.gz" \
      || die "libssh2 源码下载失败；请手工放置 $tarball 后重跑"
    mv "$tarball.tmp" "$tarball"
  else
    log "复用缓存 $tarball"
  fi

  local src="$HOST_DEPS_ROOT/src/libssh2-$LIBSSH2_VER"
  local build="$HOST_DEPS_ROOT/src/libssh2-$LIBSSH2_VER-host-build"
  rm -rf "$src" "$build"
  tar xf "$tarball" -C "$HOST_DEPS_ROOT/src"

  log "配置宿主机版 libssh2（静态库 + 系统 OpenSSL）→ $prefix"
  local cc_args=()
  if command -v clang >/dev/null; then cc_args=(-DCMAKE_C_COMPILER=clang); fi
  cmake -S "$src" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCRYPTO_BACKEND=OpenSSL \
    -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF \
    -DENABLE_ZLIB_COMPRESSION=ON \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    "${cc_args[@]}"
  cmake --build "$build" -j "$JOBS"
  cmake --install "$build"
  log "libssh2 安装完成：$prefix"
}

# ---------------------------------------------------------------- sshd（免 root）

setup_sshd() {
  local sshd_root="$HOST_DEPS_ROOT/sshd"
  local sshd_bin="$sshd_root/rootfs/usr/sbin/sshd"

  if [ ! -x "$sshd_bin" ] || [ ! -f "$sshd_root/rootfs/lib/x86_64-linux-gnu/libwrap.so.0" ]; then
    log "下载 openssh-server（apt-get download，免 root）"
    local debs="$sshd_root/debs"
    mkdir -p "$debs"
    # Ubuntu 的 sshd 链了 libwrap（TCP wrappers），系统未装时一并解包，
    # 启动时以 LD_LIBRARY_PATH 指向 rootfs 内的私有库目录
    if ! (cd "$debs" && apt-get download openssh-server openssh-sftp-server libwrap0); then
      warn "apt-get download openssh-server 失败——集成测试将 GTEST_SKIP（不影响其余用例）"
      return 0
    fi
    rm -rf "$sshd_root/rootfs"
    mkdir -p "$sshd_root/rootfs"
    local d
    for d in "$debs"/*.deb; do dpkg -x "$d" "$sshd_root/rootfs"; done
  fi
  [ -x "$sshd_bin" ] || { warn "sshd 解包后仍不可用，集成测试将 GTEST_SKIP"; return 0; }

  # 私有库目录（libwrap 等解包产物），拼 LD_LIBRARY_PATH 验证二进制可加载
  local libdirs=""
  local ld
  for ld in "$sshd_root/rootfs/lib/x86_64-linux-gnu" "$sshd_root/rootfs/usr/lib/x86_64-linux-gnu" \
            "$sshd_root/rootfs/lib/aarch64-linux-gnu" "$sshd_root/rootfs/usr/lib/aarch64-linux-gnu"; do
    [ -d "$ld" ] && libdirs="$libdirs:$ld"
  done
  if LD_LIBRARY_PATH="${libdirs#:}" ldd "$sshd_bin" 2>/dev/null | grep -q "not found"; then
    warn "sshd 存在未满足的动态库依赖——集成测试将 GTEST_SKIP"
    LD_LIBRARY_PATH="${libdirs#:}" ldd "$sshd_bin" | grep "not found" >&2
    return 0
  fi
  log "sshd 已就绪：$sshd_bin（LD_LIBRARY_PATH=${libdirs#:}）"

  # 运行时目录：host key + 配置（幂等；host key 已存在则保留，避免指纹漂移）
  local rt="$sshd_root/runtime"
  mkdir -p "$rt"
  [ -f "$rt/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$rt/ssh_host_ed25519_key"
  [ -f "$rt/ssh_host_rsa_key" ]     || ssh-keygen -q -t rsa -b 3072 -N '' -f "$rt/ssh_host_rsa_key"
  chmod 600 "$rt"/ssh_host_*_key

  # 固定配置；端口由启动时 -p 指定（测试按实例起在空闲高端口）。
  # 免 root 运行的关键项：UsePAM no（读不了 shadow）、StrictModes no（家目录属主不校验）。
  cat > "$rt/sshd_config" <<EOF
# 测试专用 sshd 配置（scripts/setup-host-deps.sh 生成，集成测试用 sshd -d 单连接模式启动）
ListenAddress 127.0.0.1
HostKey $rt/ssh_host_ed25519_key
HostKey $rt/ssh_host_rsa_key
UsePAM no
StrictModes no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
PrintMotd no
LogLevel VERBOSE
EOF
  log "sshd 运行时目录就绪：$rt"
}

setup_libssh2
setup_sshd
log "完成。宿主测试构建将自动使用 $HOST_DEPS_ROOT/libssh2；"
log "sshd 二进制：$HOST_DEPS_ROOT/sshd/rootfs/usr/sbin/sshd（缺失时集成测试 GTEST_SKIP）。"
