#!/usr/bin/env bash
# gate.sh —— Q2 性能门禁：对照 DESIGN §1.2 指标校验基准报告 JSON。
#
# 门禁阈值（可用环境变量覆盖，默认即 TASKS Q2 / DESIGN §1.2）：
#   BENCH_MIN_FPS     场景平均帧率下限，默认 50
#   BENCH_MAX_RSS_MB  峰值 RSS 上限（MB），默认 400
#   BENCH_REQUIRE_ALL=1  时四个场景都必须有实测数值（否则失败）；
#                       默认 0：只门禁「有实测数值」的场景，dry-run/skipped 只记录
#   BENCH_STRICT_DRY=1   dry-run/skipped 一律失败
#
# 用法：
#   bash scripts/bench/gate.sh [report.json]
#   默认报告：scripts/bench/last-report.json（不存在则用 sample-report.json 自检）
#
# 退出码：
#   0  通过
#   1  报告低于阈值 / requireAll 下场景缺失或未实测
#   2  用法错误（报告文件不可读 / 无 python）
#
# 判定逻辑：scripts/bench/gate_check.py（与 entry/src/test/BenchMetrics.ets 对齐）
# Windows Git Bash + WSL 友好。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BENCH_MIN_FPS="${BENCH_MIN_FPS:-50}"
BENCH_MAX_RSS_MB="${BENCH_MAX_RSS_MB:-400}"
BENCH_REQUIRE_ALL="${BENCH_REQUIRE_ALL:-0}"
BENCH_STRICT_DRY="${BENCH_STRICT_DRY:-0}"

REPORT="${1:-}"
if [ -z "$REPORT" ]; then
  if [ -f "$SCRIPT_DIR/last-report.json" ]; then
    REPORT="$SCRIPT_DIR/last-report.json"
  else
    REPORT="$SCRIPT_DIR/sample-report.json"
    echo "[bench-gate] 未指定报告，使用 sample-report.json 自检" >&2
  fi
fi
case "$REPORT" in
  /*|[A-Za-z]:*|[A-Za-z]:/*) : ;;
  *) REPORT="$PROJECT_ROOT/$REPORT" ;;
esac
if [ ! -f "$REPORT" ]; then
  echo "[bench-gate] 错误：报告不可读：$REPORT" >&2
  exit 2
fi

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "[bench-gate] 错误：需要 python3 或 python" >&2
  exit 2
fi

echo "[bench-gate] 阈值：BENCH_MIN_FPS=$BENCH_MIN_FPS BENCH_MAX_RSS_MB=$BENCH_MAX_RSS_MB BENCH_REQUIRE_ALL=$BENCH_REQUIRE_ALL"
echo "[bench-gate] 报告：$REPORT"

"$PY" "$SCRIPT_DIR/gate_check.py" \
  "$REPORT" "$BENCH_MIN_FPS" "$BENCH_MAX_RSS_MB" "$BENCH_REQUIRE_ALL" "$BENCH_STRICT_DRY"
rc=$?
if [ $rc -eq 0 ]; then
  echo "[bench-gate] ✅ 门禁通过"
  exit 0
fi
echo "[bench-gate] ❌ 门禁失败（rc=$rc）" >&2
exit 1
