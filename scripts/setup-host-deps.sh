#!/usr/bin/env bash
# setup-host-deps.sh —— 宿主机测试依赖一键准备（任务 N6，供 run-native-tests.sh 自动调用）
#
# 用途：native 单测里的 ssh/session.cpp 需要「宿主机版」libssh2（仓库 prebuilt/ 是
# OHOS target，宿主测试不能链）；集成测试还需要一个真实 sshd。
# 本脚本在 WSL / Linux CI 内运行，幂等，全部产物落在 $HOST_DEPS_ROOT（不进仓库）。
#
# 产物布局：
#   $HOST_DEPS_ROOT/libssh2/            宿主机版 libssh2 1.11.1（静态，链系统 OpenSSL）
#   $HOST_DEPS_ROOT/libvterm/           宿主机版 libvterm 0.3.3（静态，T1 起 term/ 单测用）
#   $HOST_DEPS_ROOT/sshd/rootfs/...     免 root 解包的 openssh-server（apt download + dpkg -x）
#   $HOST_DEPS_ROOT/sshd/runtime/       运行时目录（host key、sshd_config、日志）
#   $HOST_DEPS_ROOT/auth/               N8 认证测试环境（见下方「认证测试环境」段）
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
#
# 认证测试环境（N8）：密码/keyboard-interactive 认证需要校验系统账号口令
# （/etc/shadow + PAM），免 root 做不到，故认证用例连另一个「root 常驻 sshd」：
#   - 普通用户运行本脚本时，经 wsl.exe -u root 自举 root 段（WSL 特性，免密码）；
#     非 WSL / 自举失败时仅告警，认证集成用例 GTEST_SKIP，不影响其余测试；
#   - root 段也可手工单独执行：
#       wsl -d Ubuntu -u root -- bash <本脚本> --auth-sshd-root-step <目标用户> <HOST_DEPS_ROOT>
#   - root 段产物：测试用户 sshtest、随机测试密码与私钥短语（只写 auth/ 目录，
#     权限 600 且归还目标用户，绝不进 git 仓库）、测试密钥对（带/不带短语）、
#     最小 /etc/pam.d/sshd（缺失时才写）、root 常驻 sshd（UsePAM yes，
#     仅 127.0.0.1 高端口，端口写入 auth/port）。

set -euo pipefail

HOST_DEPS_ROOT="${HOST_DEPS_ROOT:-$HOME/ohos-probe/build/host-deps}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/ohos-probe/build/downloads}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
LIBSSH2_VER=1.11.1
LIBVTERM_VER=0.3.3

log()  { echo "[host-deps] $*"; }
warn() { echo "[host-deps] 警告：$*" >&2; }
die()  { echo "[host-deps] 错误：$*" >&2; exit 1; }

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

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

# ---------------------------------------------------------------- libvterm

# T1 起 term/ 单测需要宿主机版 libvterm（与 prebuilt/ 同版本 0.3.3，Makefile 项目，
# 直接编译全部 .c 再 ar 打包——与 scripts/build-deps.sh 的交叉编译同款做法）。
setup_libvterm() {
  local prefix="$HOST_DEPS_ROOT/libvterm"
  if [ -f "$prefix/lib/libvterm.a" ] && [ -f "$prefix/include/vterm.h" ]; then
    log "libvterm 已就绪：$prefix（跳过）"
    return
  fi

  mkdir -p "$DOWNLOAD_DIR" "$HOST_DEPS_ROOT/src"
  local tarball="$DOWNLOAD_DIR/libvterm-$LIBVTERM_VER.tar.gz"
  if [ ! -s "$tarball" ]; then
    log "下载 libvterm $LIBVTERM_VER"
    curl -fsSL --connect-timeout 20 --max-time 600 -o "$tarball.tmp" \
      "https://www.leonerd.org.uk/code/libvterm/libvterm-$LIBVTERM_VER.tar.gz" \
      || curl -fsSL --connect-timeout 20 --max-time 600 -o "$tarball.tmp" \
      "https://launchpad.net/libvterm/trunk/v$LIBVTERM_VER/+download/libvterm-$LIBVTERM_VER.tar.gz" \
      || die "libvterm 源码下载失败；请手工放置 $tarball 后重跑"
    mv "$tarball.tmp" "$tarball"
  else
    log "复用缓存 $tarball"
  fi

  local src="$HOST_DEPS_ROOT/src/libvterm-$LIBVTERM_VER"
  rm -rf "$src"
  tar xzf "$tarball" -C "$HOST_DEPS_ROOT/src"

  local cc
  if command -v clang >/dev/null; then cc=clang
  elif command -v gcc >/dev/null; then cc=gcc
  else die "找不到 clang 或 gcc（Ubuntu: apt install clang）"
  fi

  local obj_dir="$src/obj-host"
  mkdir -p "$obj_dir"
  local f
  for f in "$src"/src/*.c; do
    "$cc" -O2 -fPIC -std=c99 -I"$src/include" -I"$src/src" \
      -c "$f" -o "$obj_dir/$(basename "${f%.c}").o"
  done
  ar rcs "$obj_dir/libvterm.a" "$obj_dir"/*.o

  mkdir -p "$prefix/lib" "$prefix/include"
  cp -a "$obj_dir/libvterm.a" "$prefix/lib/"
  cp -a "$src/include/vterm.h" "$src/include/vterm_keycodes.h" "$prefix/include/"
  log "libvterm 安装完成：$prefix（编译器 $cc）"
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

# ---------------------------------------------------------------- 认证测试环境（N8，需 root）

# 生成 20 字符随机串（base64 字母表去掉 /+= 与换行；测试专用，不做长期凭据）
gen_secret() {
  local s=""
  while [ ${#s} -lt 20 ]; do
    s="$s$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')"
  done
  printf %s "${s:0:20}"
}

# root 段：参数 <目标用户（产物归还对象，即跑测试的普通用户）> <HOST_DEPS_ROOT>。
# 幂等；密码/短语只写入 auth/ 目录（600 + 归还目标用户），绝不进仓库。
auth_sshd_root_step() {
  local target_user="$1" root="$2"
  [ "$(id -u)" -eq 0 ] || die "--auth-sshd-root-step 需要 root 运行"
  local sshd_bin="$root/sshd/rootfs/usr/sbin/sshd"
  [ -x "$sshd_bin" ] || die "免 root sshd 未就绪：$sshd_bin（先以普通用户跑本脚本完成解包）"
  command -v useradd >/dev/null || die "找不到 useradd"
  command -v ss >/dev/null || die "找不到 ss（iproute2，Ubuntu 默认自带）"
  id "$target_user" >/dev/null 2>&1 || die "目标用户 $target_user 不存在"

  local auth_dir="$root/auth"
  mkdir -p "$auth_dir"

  # sshd 特权分离用户与目录（Debian/Ubuntu 构建的硬性要求，缺失则启动即失败）
  if ! id sshd >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin sshd
    log "已创建特权分离用户 sshd"
  fi
  mkdir -p /run/sshd

  # PAM：密码与 keyboard-interactive 认证经 pam_unix 校验 /etc/shadow。
  # 系统已有 /etc/pam.d/sshd（装了 openssh-server）则沿用，否则写最小栈
  if [ ! -f /etc/pam.d/sshd ]; then
    cat > /etc/pam.d/sshd <<'EOF'
# 测试用最小 PAM 栈（scripts/setup-host-deps.sh 因 N8 认证测试需要写入；
# 若之后安装 openssh-server，包管理器会以其自带版本替换/共存）
auth     required pam_unix.so
account  required pam_unix.so
password required pam_unix.so
session  required pam_unix.so
EOF
    log "已写入最小 /etc/pam.d/sshd"
  fi

  # 测试用户与随机密码（幂等：密码文件已存在则复用，chpasswd 每次对齐以自愈）
  local test_user=sshtest
  if ! id "$test_user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$test_user"
    log "已创建测试用户 $test_user"
  fi
  if [ ! -s "$auth_dir/test-password" ]; then
    gen_secret > "$auth_dir/test-password"
    log "已生成随机测试密码（$auth_dir/test-password，绝不进仓库）"
  fi
  echo "$test_user:$(cat "$auth_dir/test-password")" | chpasswd
  printf %s "$test_user" > "$auth_dir/test-user"

  # 测试密钥对：不带短语 / 带短语各一（短语随机生成，同样只落 auth/ 目录）。
  # 短语经 ssh-keygen 命令行传入，ps 瞬时可见——测试环境专用，可接受。
  if [ ! -s "$auth_dir/key-passphrase" ]; then
    gen_secret > "$auth_dir/key-passphrase"
  fi
  local passphrase
  passphrase="$(cat "$auth_dir/key-passphrase")"
  [ -f "$auth_dir/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$auth_dir/id_ed25519"
  [ -f "$auth_dir/id_ed25519_pass" ] || \
    ssh-keygen -q -t ed25519 -N "$passphrase" -f "$auth_dir/id_ed25519_pass"

  # authorized_keys：两个测试公钥都授权给测试用户（StrictModes 要求的权限/属主）
  local home_dir
  home_dir="$(getent passwd "$test_user" | cut -d: -f6)"
  [ -n "$home_dir" ] || die "取不到 $test_user 的家目录"
  mkdir -p "$home_dir/.ssh"
  cat "$auth_dir/id_ed25519.pub" "$auth_dir/id_ed25519_pass.pub" \
    > "$home_dir/.ssh/authorized_keys"
  chmod 700 "$home_dir/.ssh"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  chown -R "$test_user:$(id -gn "$test_user")" "$home_dir/.ssh"

  # 认证 sshd 自有 host key（与免 root 实例隔离，指纹互不影响）
  [ -f "$auth_dir/ssh_host_ed25519_key" ] || \
    ssh-keygen -q -t ed25519 -N '' -f "$auth_dir/ssh_host_ed25519_key"
  chmod 600 "$auth_dir/ssh_host_ed25519_key"

  # 端口：沿用 port 文件（保持稳定，测试侧零配置）；被占且非本 sshd 占用时换新
  local port=""
  [ -s "$auth_dir/port" ] && port="$(cat "$auth_dir/port")"
  local cur_pid=""
  [ -s "$auth_dir/sshd.pid" ] && cur_pid="$(cat "$auth_dir/sshd.pid")"
  if [ -n "$port" ] && ss -ltn | grep -q ":$port "; then
    if [ -z "$cur_pid" ] || [ ! -d "/proc/$cur_pid" ]; then
      port="" # 端口被别的进程占用且本 sshd 已死：重新选
    fi
  fi
  if [ -z "$port" ]; then
    local p
    for p in $(seq 29222 29262); do
      ss -ltn | grep -q ":$p " || { port="$p"; break; }
    done
    [ -n "$port" ] || die "29222-29262 段无空闲端口可供认证 sshd 监听"
    printf %s "$port" > "$auth_dir/port"
  fi

  cat > "$auth_dir/sshd_config" <<EOF
# 认证测试专用 sshd 配置（scripts/setup-host-deps.sh 生成；root 常驻模式，供 N8 集成测试）
ListenAddress 127.0.0.1
Port $port
HostKey $auth_dir/ssh_host_ed25519_key
UsePAM yes
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
AllowUsers $test_user
PidFile $auth_dir/sshd.pid
X11Forwarding no
PrintMotd no
LogLevel VERBOSE
EOF

  # 常驻 sshd（daemon 模式，每连接 fork；与免 root 的 sshd -d 单连接模式不同）
  if [ -n "$cur_pid" ] && [ -d "/proc/$cur_pid" ]; then
    log "认证 sshd 已在运行（pid $cur_pid，端口 $port）"
  else
    rm -f "$auth_dir/sshd.pid"
    local libdirs="" ld
    for ld in "$root/sshd/rootfs/lib/x86_64-linux-gnu" "$root/sshd/rootfs/usr/lib/x86_64-linux-gnu" \
              "$root/sshd/rootfs/lib/aarch64-linux-gnu" "$root/sshd/rootfs/usr/lib/aarch64-linux-gnu"; do
      [ -d "$ld" ] && libdirs="$libdirs:$ld"
    done
    LD_LIBRARY_PATH="${libdirs#:}" "$sshd_bin" -f "$auth_dir/sshd_config" -E "$auth_dir/sshd.log"
    local i
    for i in $(seq 1 40); do
      ss -ltn | grep -q ":$port " && break
      sleep 0.25
    done
    if ! ss -ltn | grep -q ":$port "; then
      tail -20 "$auth_dir/sshd.log" >&2 || true
      die "认证 sshd 启动失败（日志 $auth_dir/sshd.log）"
    fi
    log "认证 sshd 已启动（端口 $port，日志 $auth_dir/sshd.log）"
  fi

  # 产物归还普通用户：测试进程（非 root）要读密码/短语/私钥
  chown -R "$target_user:$(id -gn "$target_user")" "$auth_dir"
  chmod 600 "$auth_dir/test-password" "$auth_dir/key-passphrase" \
            "$auth_dir/id_ed25519" "$auth_dir/id_ed25519_pass"
  log "认证测试环境就绪：用户 $test_user，端口 $port，材料目录 $auth_dir"
}

# 非 root 入口：健康检查后按需自举 root 段；失败只告警（认证用例 GTEST_SKIP）
setup_auth_sshd() {
  local auth_dir="$HOST_DEPS_ROOT/auth"
  # 健康检查：端口文件 + pid 存活（/proc/<pid> 目录任意用户可读），全满足则零开销跳过
  if [ -s "$auth_dir/port" ] && [ -s "$auth_dir/sshd.pid" ] && \
     [ -d "/proc/$(cat "$auth_dir/sshd.pid" 2>/dev/null)" ]; then
    log "认证 sshd 已就绪（端口 $(cat "$auth_dir/port")，跳过）"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    # 整脚本以 root 运行时直接执行（HOST_DEPS_ROOT 须由调用方显式传入并展开，
    # root 的 HOME 与普通用户不同，不能用默认值猜）
    auth_sshd_root_step "${SUDO_USER:-root}" "$HOST_DEPS_ROOT"
    return 0
  fi

  # 普通用户：经 wsl.exe 自举 root 段（WSL 特性：wsl.exe -u root 免密码）
  if command -v wsl.exe >/dev/null 2>&1 && [ -n "${WSL_DISTRO_NAME:-}" ]; then
    log "准备认证测试环境（wsl.exe -u root 自举；失败则认证集成用例 GTEST_SKIP）"
    if wsl.exe -d "$WSL_DISTRO_NAME" -u root -- bash "$SELF_PATH" --auth-sshd-root-step \
         "$(id -un)" "$HOST_DEPS_ROOT"; then
      return 0
    fi
    warn "认证 sshd root 准备步骤执行失败——认证集成测试将 GTEST_SKIP"
    return 0
  fi
  warn "无 root 权限且非 WSL 环境：跳过认证 sshd 准备（认证集成测试将 GTEST_SKIP）"
  warn "可手工以 root 补齐：bash $SELF_PATH --auth-sshd-root-step $(id -un) $HOST_DEPS_ROOT"
}

# root 段直调（wsl.exe 自举 / 手工）：只跑认证准备，不动 libssh2/sshd 解包
# （否则会以 root 在普通用户的 HOST_DEPS_ROOT 下重建产物，属主混乱）
if [ "${1:-}" = "--auth-sshd-root-step" ]; then
  shift
  auth_sshd_root_step "$@"
  exit 0
fi

setup_libssh2
setup_libvterm
setup_sshd
setup_auth_sshd
log "完成。宿主测试构建将自动使用 $HOST_DEPS_ROOT/libssh2；"
log "sshd 二进制：$HOST_DEPS_ROOT/sshd/rootfs/usr/sbin/sshd（缺失时集成测试 GTEST_SKIP）；"
log "认证 sshd：$HOST_DEPS_ROOT/auth/（缺失时认证集成测试 GTEST_SKIP）。"
