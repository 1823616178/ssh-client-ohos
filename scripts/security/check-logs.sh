#!/usr/bin/env bash
# check-logs.sh —— Q4 日志脱敏自查：在样例日志目录中搜索密码/token/私钥等明文。
#
# 用法：
#   bash scripts/security/check-logs.sh [log_dir]
#   默认：LOG_DIR 环境变量，否则 build/ci-logs（若不存在则 dry-run 清单）
#
# 判定逻辑：scripts/security/check_logs_scan.py（与 Logger.sanitize 对齐，
# 已脱敏 *** 不算命中）。
#
# 退出码：
#   0  无明文敏感命中（或目录不存在 → dry-run 清单）
#   1  发现疑似明文敏感字段
#   2  用法/环境错误
#
# Windows Git Bash + WSL 友好。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOG_DIR="${1:-${LOG_DIR:-}}"
if [ -z "$LOG_DIR" ]; then
  LOG_DIR="$PROJECT_ROOT/build/ci-logs"
fi
case "$LOG_DIR" in
  /*|[A-Za-z]:*|[A-Za-z]:/*) : ;;
  *) LOG_DIR="$PROJECT_ROOT/$LOG_DIR" ;;
esac

log() { echo "[check-logs] $*"; }

if [ ! -d "$LOG_DIR" ]; then
  log "目录不存在：$LOG_DIR"
  log "dry-run 清单（Q4 日志脱敏）："
  cat <<'EOF'
  1) 从真机沙箱导出应用日志：hdc file recv <app_log_dir> build/sample-logs
     （路径依赖安装包名与 hilog 落盘位置；无设备时用本地 hvigor/ci 日志或人工样例）
  2) 保证样例目录含：连接失败日志、同步 API 日志、认证日志、调试 dump
  3) bash scripts/security/check-logs.sh build/sample-logs
  4) 命中项必须是 sanitize() 未覆盖的形态 → 补 Logger.ets 规则后重跑
  5) 通过标准：0 命中；红队样例（故意塞 password/token/PEM）必须能被检出
EOF
  exit 0
fi

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  log "错误：需要 python3 或 python"
  exit 2
fi

log "扫描目录：$LOG_DIR"
"$PY" "$SCRIPT_DIR/check_logs_scan.py" "$LOG_DIR"
exit $?
