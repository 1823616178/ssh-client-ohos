#!/usr/bin/env bash
# Q1 —— 多算法 sshd 集成测试环境（Docker / 可选）。
#
# 用途：在宿主机 free-root sshd 之外，补一份「多算法加固」sshd，供 N 系列集成用例
# 验证 libssh2 与 chacha20/aes-gcm 等算法协商路径。默认不强制启用：无 Docker 时脚本
# 打印说明并以 0 退出，CI 不因缺 Docker 而红。
#
# 用法：
#   bash scripts/docker-sshd.sh up     # 构建并启动（host 端口 2222）
#   bash scripts/docker-sshd.sh down
#   bash scripts/docker-sshd.sh status
#
# 环境变量：
#   SSH_TEST_DOCKER_PORT  默认 2222
#   SSH_TEST_DOCKER_IMAGE 默认 ssh-client-ohos-test-sshd

set -euo pipefail

PORT="${SSH_TEST_DOCKER_PORT:-2222}"
IMAGE="${SSH_TEST_DOCKER_IMAGE:-ssh-client-ohos-test-sshd}"
NAME="ssh-client-ohos-sshd-test"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="$DIR/docker-sshd"

log() { echo "[q1-sshd] $*"; }

if ! command -v docker >/dev/null 2>&1; then
  log "本机无 docker：跳过多算法 sshd 环境（宿主机 free-root sshd + run-native-tests.sh 仍可用）"
  exit 0
fi

case "${1:-status}" in
  up)
    docker build -t "$IMAGE" "$CTX"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker run -d --name "$NAME" -p "${PORT}:22" "$IMAGE"
    log "sshd 已启动：127.0.0.1:${PORT}（用户 test / 密码 test，请仅本机测试用）"
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    log "已停止并删除容器 $NAME"
    ;;
  status)
    if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
      log "运行中：$NAME"
      docker port "$NAME" || true
    else
      log "未运行（bash scripts/docker-sshd.sh up 启动）"
    fi
    ;;
  *)
    echo "用法: $0 {up|down|status}" >&2
    exit 2
    ;;
esac
