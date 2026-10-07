#!/usr/bin/env bash
# run-bench.sh —— Q2 性能基准采集（设备 hdc 钩子 + 离线 dry-run 检查清单）。
#
# 场景（TASKS Q2 / DESIGN §1.2）：
#   cat_5mb              cat 一个 5 MB 文本，要求全程 ≥50 fps
#   yes_burst            yes 高频突发输出
#   host_list_100        100 主机列表加载
#   pane_4_concurrent    4 分屏并发输出，仍 ≥50 fps、峰值 RSS < 400 MB
#
# 用法：
#   bash scripts/bench/run-bench.sh
#   bash scripts/bench/run-bench.sh --out path.json
#   DEVICE_SERIAL=xxx bash scripts/bench/run-bench.sh
#
# 输出：报告 JSON（schema: scripts/bench/report-schema.json），默认 last-report.json
# 判定：bash scripts/bench/gate.sh <report> ；BENCH_REQUIRE_ALL=1 为发布前严格模式。
#
# Windows Git Bash + WSL 友好。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

OUT=""
MODE="dry-run"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
ALLOWED_STAGES="${ALLOWED_STAGES:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --device) DEVICE_SERIAL="${2:-}"; MODE="device"; shift 2 ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0 ;;
    *) echo "[bench] 未知参数：$1" >&2; exit 2 ;;
  esac
done

OUT="${OUT:-$SCRIPT_DIR/last-report.json}"
case "$OUT" in
  /*|[A-Za-z]:*|[A-Za-z]:/*) : ;;
  *) OUT="$PROJECT_ROOT/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"

log()  { echo "[bench] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

HDC=""
if have hdc; then
  HDC=hdc
elif [ -n "${HDC_PATH:-}" ] && [ -f "$HDC_PATH" ]; then
  HDC="$HDC_PATH"
fi

if [ "$MODE" = "device" ] && [ -z "$HDC" ]; then
  log "警告：请求 device 模式但找不到 hdc，回退 dry-run"
  MODE="dry-run"
fi
if [ -n "$HDC" ] && [ "$MODE" = "dry-run" ] && [ -n "$DEVICE_SERIAL" ]; then
  MODE="device"
fi
if [ "$MODE" = "device" ] && [ -z "$DEVICE_SERIAL" ] && [ -n "$HDC" ]; then
  DEVICE_SERIAL="$("$HDC" list targets 2>/dev/null | head -1 | tr -d '\r')"
  if [ -z "$DEVICE_SERIAL" ]; then
    MODE="dry-run"
  fi
fi

stage_enabled() {
  local id="$1"
  if [ -z "$ALLOWED_STAGES" ]; then
    return 0
  fi
  case ",$ALLOWED_STAGES," in
    *",$id,"*) return 0 ;;
    *) return 1 ;;
  esac
}

checklist_cat_5mb() {
  cat <<'EOF'
  1) 设备上安装调试 HAP 并启动 SSH 客户端
  2) 连接测试主机，确保 /tmp/bench-5mb.txt 存在：
       dd if=/dev/urandom of=/tmp/bench-5mb.txt bs=1M count=5
  3) 终端会话中执行：cat /tmp/bench-5mb.txt
  4) 全程观察/采集帧率（≥50 fps）与峰值 RSS（<400 MB）
  5) hdc 采样 RSS 示例：
       hdc -t <serial> shell "ps -A | grep -i ssh"
  6) 将 fpsAvg / fpsP1 / rssPeakMb 回填到报告 JSON 对应场景
EOF
}

checklist_yes_burst() {
  cat <<'EOF'
  1) 同一会话执行：yes 'BENCH-BURST-LINE' （数秒后 Ctrl+C）
  2) 记录突发期间 fpsAvg / fpsP1 与 rssPeakMb
  3) 确认 UI 不冻结、输入仍可抢占（DESIGN §1.2）
  4) 回填报告 JSON
EOF
}

checklist_host_list_100() {
  cat <<'EOF'
  1) 预置 ≥100 条主机配置
  2) 冷启动进入 HostListPage，记录首帧时间与滚动流畅度
  3) LazyForEach 滚动一圈，记录 rssPeakMb
  4) 回填报告 JSON（host_list_100）
EOF
}

checklist_pane_4() {
  cat <<'EOF'
  1) 在 lg 断点（>840vp）下开 4 个窗格，各自建立会话
  2) 四窗格同时 cat / yes 输出
  3) 采集联合帧率：全应用单一 displaySync（D14）下仍须 ≥50 fps
  4) 记录峰值 RSS，必须 <400 MB
  5) 回填报告 JSON（pane_4_concurrent）
EOF
}

device_hooks() {
  local id="$1"
  log "场景 $id：hdc 目标=$DEVICE_SERIAL（钩子就绪，数值需外部采集回填）"
  if [ "${HDC_BENCH_RUNNER:-0}" = "1" ] && [ -n "${BENCH_RUNNER_CMD:-}" ]; then
    log "调用外部采集器：$BENCH_RUNNER_CMD $id"
    # shellcheck disable=SC2086
    $BENCH_RUNNER_CMD "$id" || log "外部采集器返回非 0"
    return
  fi
  log "可复制 hdc："
  echo "  hdc -t $DEVICE_SERIAL shell \"ps -A | grep -i ssh\""
}

SCENARIO_IDS="cat_5mb yes_burst host_list_100 pane_4_concurrent"
LINES_FILE="$(mktemp "${TMPDIR:-/tmp}/bench-lines.XXXXXX")"
trap 'rm -f "$LINES_FILE"' EXIT
: > "$LINES_FILE"

for id in $SCENARIO_IDS; do
  if ! stage_enabled "$id"; then
    log "跳过场景 $id（ALLOWED_STAGES 过滤）"
    printf '%s\n' "$id|skipped|skipped by ALLOWED_STAGES" >> "$LINES_FILE"
    continue
  fi
  log "===== 场景 $id ====="
  case "$id" in
    cat_5mb)           checklist_cat_5mb ;;
    yes_burst)         checklist_yes_burst ;;
    host_list_100)     checklist_host_list_100 ;;
    pane_4_concurrent) checklist_pane_4 ;;
  esac
  if [ "$MODE" = "device" ]; then
    device_hooks "$id"
    printf '%s\n' "$id|device|awaiting metrics via hdc/human" >> "$LINES_FILE"
  else
    log "dry-run：未采集 $id 实测数值（设备验收依赖 X0 签名后真机）"
    printf '%s\n' "$id|dry-run|offline checklist only" >> "$LINES_FILE"
  fi
done

BUILD_ID=""
HAP_CANDIDATE="$(ls "$PROJECT_ROOT/entry/build/default/outputs/default/"*.hap 2>/dev/null | head -1 || true)"
if [ -n "$HAP_CANDIDATE" ] && [ -f "$HAP_CANDIDATE" ]; then
  BUILD_ID="$HAP_CANDIDATE"
fi

if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  log "错误：需要 python3 或 python 组装 JSON" >&2
  exit 1
fi

"$PY" - "$OUT" "$LINES_FILE" "$MODE" "$DEVICE_SERIAL" "$BUILD_ID" <<'PY'
import json
import sys
from datetime import datetime, timezone

out, lines_path, mode, device, build = sys.argv[1:6]
scenarios = []
with open(lines_path, "r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        sid, status, notes = raw.split("|", 2)
        # device 模式尚未回填数值 → status 仍为 dry-run（gate requireAll 会失败，符合预期）
        st = "skipped" if status == "skipped" else "dry-run"
        scenarios.append({
            "id": sid,
            "status": st,
            "fpsAvg": None,
            "fpsP1": None,
            "rssPeakMb": None,
            "durationMs": None,
            "notes": notes,
        })

report = {
    "schemaVersion": 1,
    "generatedAt": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
    "environment": {
        "mode": mode,
        "device": device if device else None,
        "build": build if build else None,
        "script": "scripts/bench/run-bench.sh",
    },
    "scenarios": scenarios,
    "gate": {
        "minFps": 50,
        "maxRssMb": 400,
        "result": "skipped",
        "failures": [],
    },
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"[bench] 报告已写入 {out}")
PY

log "模式：$MODE"
log "报告：$OUT"
if [ "$MODE" = "dry-run" ]; then
  log "下一步：设备就绪后 DEVICE_SERIAL=<serial> bash scripts/bench/run-bench.sh"
  log "       回填实测数值后：BENCH_REQUIRE_ALL=1 bash scripts/bench/gate.sh $OUT"
fi
exit 0
