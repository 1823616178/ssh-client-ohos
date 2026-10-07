#!/usr/bin/env bash
# scripts/sshd-multi/up.sh —— Q1 多算法 Docker sshd 启动/探活（可选集成环境）
#
# 无 docker 时 SKIP 并以 0 退出（主门禁不因缺 docker 变红）。
# 有 docker 时：compose up → 等待 2222 端口就绪 → 打印连接环境变量。
#
# 用法：
#   bash scripts/sshd-multi/up.sh           # 启动（不等待就绪）
#   bash scripts/sshd-multi/up.sh --wait    # 启动并等待端口（ci-local CI_DOCKER_SSHD）
#   bash scripts/sshd-multi/up.sh down
#   bash scripts/sshd-multi/up.sh status
#
# 环境变量：
#   SSH_TEST_DOCKER_PORT   默认 2222（与 docker-compose.yml 端口映射一致）
#   SSH_TEST_USER          默认 test
#   SSH_TEST_PASSWORD      默认 testpass
#
# x86_64 模拟器用例：仍 blocked on device/SDK（OHOS musl 二进制不能在 WSL 直接跑；
# 见 scripts/run-native-tests.sh TARGET=ohos-x86_64 与 docs/QUALITY-GATES.md §3/§5）。

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${SSH_TEST_DOCKER_PORT:-2222}"
USER_NAME="${SSH_TEST_USER:-test}"
USER_PASS="${SSH_TEST_PASSWORD:-testpass}"
MODE="${1:-up}"
WAIT=0
if [ "${1:-}" = "--wait" ]; then
  MODE=up
  WAIT=1
fi

log() { echo "[sshd-multi] $*"; }

if [ "$MODE" = "status" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    log "无 docker：环境不可用（SKIP）"
    exit 0
  fi
  docker compose -f "$DIR/docker-compose.yml" ps 2>/dev/null || docker ps --filter name=ssh-ohos-test
  exit 0
fi

if [ "$MODE" = "down" ]; then
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "$DIR/docker-compose.yml" down --remove-orphans 2>/dev/null || true
  fi
  log "已停止"
  exit 0
fi

# ---- up ----
if ! command -v docker >/dev/null 2>&1; then
  log "本机无 docker：SKIP 多算法 sshd（宿主机 free-root sshd + run-native-tests.sh 仍覆盖主路径）"
  log "x86_64 模拟器用例仍 blocked on device/SDK，不在本脚本范围内"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  log "docker daemon 不可用：SKIP"
  exit 0
fi

# 密钥目录可选（容器挂载 ro；不存在时 compose 挂载可能失败，先建占位）
mkdir -p "$DIR/keys"
if [ ! -f "$DIR/keys/README" ]; then
  echo "Place OpenSSH host keys here (optional). Container regenerates if empty." > "$DIR/keys/README"
fi

log "启动 sshd-multi（port $PORT）…"
if docker compose version >/dev/null 2>&1; then
  (cd "$DIR" && docker compose -f docker-compose.yml up -d) || {
    log "compose up 失败"
    exit 1
  }
else
  (cd "$DIR" && docker-compose -f docker-compose.yml up -d) || {
    log "docker-compose up 失败"
    exit 1
  }
fi

if [ "$WAIT" = "1" ]; then
  log "等待 127.0.0.1:$PORT 就绪（最多 30s）…"
  ok=0
  for _ in $(seq 1 30); do
    if (echo >/dev/tcp/127.0.0.1/"$PORT") >/dev/null 2>&1; then
      ok=1
      break
    fi
    # /dev/tcp 在部分 shell 不可用：回退 bash -c nc 或 timeout+python
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
      ok=1
      break
    fi
    sleep 1
  done
  if [ "$ok" != "1" ]; then
    log "端口 $PORT 在 30s 内未就绪"
    docker compose -f "$DIR/docker-compose.yml" logs --tail 40 2>/dev/null || true
    exit 1
  fi
  log "sshd 已就绪"
fi

cat <<EOF
[sshd-multi] 连接参数（宿主机 native 测试）：
  SSH_TEST_HOST=127.0.0.1
  SSH_TEST_PORT=$PORT
  SSH_TEST_USER=$USER_NAME
  SSH_TEST_PASSWORD=$USER_PASS
  bash scripts/run-native-tests.sh
EOF
exit 0
