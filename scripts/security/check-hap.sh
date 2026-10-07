#!/usr/bin/env bash
# check-hap.sh —— Q4 HAP 解包自查：密钥/口令残留 + network_config 域名白名单 + 无 SYNC 秘密。
#
# 用法：
#   bash scripts/security/check-hap.sh [path/to/xxx.hap]
#   不传参数时自动查找 entry/build/default/outputs/default/*.hap
#   HAP_DIR_ONLY=1 时对已解包目录扫描（参数为目录）
#
# 检查项（判定逻辑 scripts/security/check_hap_scan.py）：
#   1) HAP 内不得出现 PEM 私钥 / 明文 password|token|apiKey / SYNC 秘密
#   2) network_config.json：全局 cleartext=false；明文域名 ⊆ ALLOWED_SYNC_DOMAINS
#   3) SYNC_API_URL（纯 URL）允许（DESIGN §6.5.1 / D10）
#
# 退出码：
#   0  通过（或 dry-run 无 HAP）
#   1  发现风险
#   2  用法/解压错误
#
# Windows Git Bash + WSL：依赖 unzip 或 python zipfile。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HAP_PATH="${1:-}"
SCAN_DIR_ONLY="${HAP_DIR_ONLY:-0}"
ALLOWED_SYNC_DOMAINS="${ALLOWED_SYNC_DOMAINS:-123.161.179.32}"

log() { echo "[check-hap] $*"; }
die() { echo "[check-hap] 错误：$*" >&2; exit 2; }

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  die "需要 python3 或 python"
fi

WORKDIR=""
CLEANUP=0
cleanup() {
  if [ "$CLEANUP" = "1" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

if [ "$SCAN_DIR_ONLY" = "1" ] && [ -n "$HAP_PATH" ] && [ -d "$HAP_PATH" ]; then
  WORKDIR="$HAP_PATH"
  log "扫描已解包目录：$WORKDIR"
else
  if [ -z "$HAP_PATH" ]; then
    HAP_PATH="$(ls "$PROJECT_ROOT/entry/build/default/outputs/default/"*.hap 2>/dev/null | head -1 || true)"
  fi
  case "$HAP_PATH" in
    /*|[A-Za-z]:*|[A-Za-z]:/*) : ;;
    "") : ;;
    *) HAP_PATH="$PROJECT_ROOT/$HAP_PATH" ;;
  esac

  if [ -z "$HAP_PATH" ] || [ ! -f "$HAP_PATH" ]; then
    log "未找到 HAP 产物（X0 签名/assembleHap 可能未跑）"
    log "dry-run 清单（Q4 HAP 自查）："
    cat <<EOF
  1) bash scripts/ci-local.sh 的阶段 4 或 hvigor assembleHap 产出 HAP
  2) bash scripts/security/check-hap.sh entry/build/default/outputs/default/entry-default-unsigned.hap
  3) 确认 network_config 仅放行：$ALLOWED_SYNC_DOMAINS
  4) 确认无 PEM 私钥、无 SYNC 秘密字段（SYNC_API_URL 允许）
  5) 真机侧补充：hdc 沙箱导出 SharedPreferences/数据库再跑 check-logs.sh
EOF
    exit 0
  fi

  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hap-scan.XXXXXX")"
  CLEANUP=1
  log "解包 HAP：$HAP_PATH → $WORKDIR"
  if command -v unzip >/dev/null 2>&1; then
    unzip -qq -o "$HAP_PATH" -d "$WORKDIR" || die "unzip 失败：$HAP_PATH"
  else
    "$PY" -c "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "$HAP_PATH" "$WORKDIR" || die "python zipfile 解压失败"
  fi
fi

[ -d "$WORKDIR" ] || die "扫描目录不存在：$WORKDIR"
"$PY" "$SCRIPT_DIR/check_hap_scan.py" "$WORKDIR" "$ALLOWED_SYNC_DOMAINS"
exit $?
