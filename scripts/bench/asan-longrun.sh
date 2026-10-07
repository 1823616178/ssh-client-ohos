#!/usr/bin/env bash
# asan-longrun.sh —— Q3 内存/句柄泄漏治理：宿主 ASan/LSan + 长稳 RSS/fd 采样清单。
#
# 已知跟踪项（文档义务，非本脚本可关闭）：
#   session_bridge 在途调用 vs teardown 的极窄竞态 —— 登记给 Q3，仍未关闭。
#   位置：entry/src/main/cpp/bridge/session_bridge.cpp / session_bridge.h 头注
#   （closeSession 幂等摘表后 teardown 在独立线程执行；env cleanup 等待 g_activeTeardowns==0。
#    在途方法与 teardown 的交错窗口需长稳 + ASan 持续观察，不在本脚本内“修复”。）
#
# 用法：
#   bash scripts/bench/asan-longrun.sh              # 打印清单 + 可选跑 ASan 单测
#   RUN_ASAN=1 bash scripts/bench/asan-longrun.sh   # 通过 WSL 跑 scripts/run-native-tests.sh SANITIZE=address
#   WRITE_REPORT=1 bash scripts/bench/asan-longrun.sh  # 追加/生成泄漏采样报告骨架
#
# 环境变量：
#   RUN_ASAN=1          执行宿主 ASan 测试（默认 0：只打印清单，CI 无 WSL 也能跑）
#   WSL_DISTRO          默认 Ubuntu（与 ci-local.sh 一致）
#   LONGRUN_HOURS       长稳目标小时数，默认 8（TASKS Q3 验收）
#   RSS_GROWTH_LIMIT_PCT  8h RSS 增长上限百分比，默认 5（TASKS Q3）
#   WRITE_REPORT=1      写 scripts/bench/longrun-report.json
#
# 退出码：
#   0  清单打印完成，或 ASan 测试通过
#   1  RUN_ASAN=1 时 ASan 测试失败
#   2  环境不满足（RUN_ASAN=1 但无 wsl）

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

RUN_ASAN="${RUN_ASAN:-0}"
WRITE_REPORT="${WRITE_REPORT:-0}"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu}"
LONGRUN_HOURS="${LONGRUN_HOURS:-8}"
RSS_GROWTH_LIMIT_PCT="${RSS_GROWTH_LIMIT_PCT:-5}"

log() { echo "[asan-longrun] $*"; }

print_checklist() {
  cat <<EOF
========== Q3 长稳 / 泄漏治理清单 ==========
目标（TASKS Q3）：
  - 连续会话 ${LONGRUN_HOURS}h 后 RSS 增长 < ${RSS_GROWTH_LIMIT_PCT}%
  - fd 数量稳定（不随会话开关单调上涨）
  - ASan/LSan 干净（host 测试）

已知跟踪项（必须在 Q3 报告中显式出现，禁止静默当作已关闭）：
  [ ] session_bridge 在途调用 vs teardown 极窄竞态
      源：entry/src/main/cpp/bridge/session_bridge.cpp
      观察点：closeSession 与同步受理方法交错；env 销毁等待 g_activeTeardowns
      验证：ASan 反复 create/close + 并发 write/resize；长稳中开关会话 ≥1000 次

宿主侧（WSL/Linux，可 CI）：
  [ ] SANITIZE=address bash scripts/run-native-tests.sh
  [ ] 重复 N 次（建议 N≥20）：createSession → exec/cat → closeSession
  [ ] LSan 报告无 definite leak；ASan 无 use-after-free / data race（TSan 另跑可选）

真机侧（依赖 X0 签名，当前阻塞，脚本只给钩子）：
  [ ] hdc 采样进程 RSS：
        hdc -t <serial> shell "pid=\$(pidof <bundle>); cat /proc/\$pid/status | grep VmRSS"
  [ ] 采样 fd：
        hdc -t <serial> shell "pid=\$(pidof <bundle>); ls /proc/\$pid/fd | wc -l"
  [ ] 采样节奏建议：
        t=0 基线 → 每 30 min 记一次 → 会话开关循环中每 5 min 记一次
  [ ] 8h 曲线画 RSS/fd 随时间；增长 ≥ ${RSS_GROWTH_LIMIT_PCT}% 或 fd 单调涨 → FAIL
  [ ] 报告字段：rssStartMb / rssEndMb / rssGrowthPct / fdStart / fdEnd / notes

脚本生成的报告骨架字段（schemaVersion 1，泄漏向）：
  rssStartMb, rssEndMb, rssGrowthPct, fdStart, fdEnd, asanClean, trackedRisks[]
EOF
}

run_asan_tests() {
  if ! command -v wsl >/dev/null 2>&1; then
    # WSL/Light：若已在 Linux/WSL 内部，直接本地跑
    if [ "$(uname -s 2>/dev/null)" = "Linux" ] && [ -f "$PROJECT_ROOT/scripts/run-native-tests.sh" ]; then
      log "在 Linux 环境内直接运行 ASan 测试"
      SANITIZE=address bash "$PROJECT_ROOT/scripts/run-native-tests.sh"
      return $?
    fi
    log "错误：RUN_ASAN=1 需要 Windows 上的 wsl 或 Linux 环境"
    return 2
  fi
  local proj
  # MSYS /c/foo → WSL /mnt/c/foo
  case "$PROJECT_ROOT" in
    /[a-zA-Z]/*)
      local drive="${PROJECT_ROOT:1:1}"
      drive="$(echo "$drive" | tr 'A-Z' 'a-z')"
      proj="/mnt/${drive}${PROJECT_ROOT:2}" ;;
    *)
      proj="$PROJECT_ROOT" ;;
  esac
  log "WSL($WSL_DISTRO) 运行 SANITIZE=address native 测试"
  wsl -d "$WSL_DISTRO" -- bash -lc "SANITIZE=address bash '$proj/scripts/run-native-tests.sh'"
}

write_report_skeleton() {
  local out="$SCRIPT_DIR/longrun-report.json"
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local PY
    PY=$(command -v python3 2>/dev/null || command -v python)
    "$PY" - "$out" "$LONGRUN_HOURS" "$RSS_GROWTH_LIMIT_PCT" <<'PY'
import json, sys
from datetime import datetime, timezone
out, hours, limit = sys.argv[1:4]
report = {
  "schemaVersion": 1,
  "kind": "q3-longrun-leak",
  "generatedAt": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
  "targetHours": int(hours),
  "rssGrowthLimitPct": float(limit),
  "environment": {"mode": "dry-run", "device": None},
  "rssStartMb": None,
  "rssEndMb": None,
  "rssGrowthPct": None,
  "fdStart": None,
  "fdEnd": None,
  "asanClean": None,
  "scenarios": [
    {"id": "host_asan", "status": "dry-run", "notes": "RUN_ASAN=1 时填写"},
    {"id": "device_longrun", "status": "dry-run", "notes": f"真机 {hours}h；阻塞于 X0 签名"}
  ],
  "trackedRisks": [
    {
      "id": "session_bridge_teardown_race",
      "status": "open",
      "description": "session_bridge 在途调用 vs teardown 极窄竞态（登记给 Q3，仍未关闭）",
      "sources": [
        "entry/src/main/cpp/bridge/session_bridge.cpp",
        "entry/src/main/cpp/bridge/session_bridge.h"
      ]
    }
  ],
  "notes": "骨架报告：用实测 RSS/fd/ASan 结果覆盖 null 字段后再跑 gate 相关检查",
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"[asan-longrun] 泄漏报告骨架 → {out}")
PY
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const [out, hours, limit] = process.argv.slice(1);
const report = {
  schemaVersion: 1,
  kind: "q3-longrun-leak",
  generatedAt: new Date().toISOString(),
  targetHours: Number(hours),
  rssGrowthLimitPct: Number(limit),
  environment: { mode: "dry-run", device: null },
  rssStartMb: null, rssEndMb: null, rssGrowthPct: null,
  fdStart: null, fdEnd: null, asanClean: null,
  scenarios: [
    { id: "host_asan", status: "dry-run", notes: "RUN_ASAN=1 时填写" },
    { id: "device_longrun", status: "dry-run", notes: "真机长稳；阻塞于 X0" }
  ],
  trackedRisks: [{
    id: "session_bridge_teardown_race",
    status: "open",
    description: "session_bridge 在途调用 vs teardown 极窄竞态（登记给 Q3）",
    sources: ["entry/src/main/cpp/bridge/session_bridge.cpp", "entry/src/main/cpp/bridge/session_bridge.h"]
  }],
  notes: "骨架报告：覆盖 null 字段后提交"
};
fs.writeFileSync(out, JSON.stringify(report, null, 2) + "\n");
console.log("[asan-longrun] 泄漏报告骨架 → " + out);
' "$SCRIPT_DIR/longrun-report.json" "$LONGRUN_HOURS" "$RSS_GROWTH_LIMIT_PCT"
  else
    log "警告：无 python/node，跳过报告骨架"
  fi
}

print_checklist

RC=0
if [ "$RUN_ASAN" = "1" ]; then
  if run_asan_tests; then
    log "✅ 宿主 ASan 测试通过"
  else
    RC=$?
    log "❌ 宿主 ASan 测试失败（rc=$RC）"
  fi
else
  log "未执行 ASan（RUN_ASAN=0）。在 WSL 内执行：RUN_ASAN=1 bash scripts/bench/asan-longrun.sh"
fi

if [ "$WRITE_REPORT" = "1" ] || [ "$RUN_ASAN" != "1" ]; then
  write_report_skeleton
fi

exit $RC
