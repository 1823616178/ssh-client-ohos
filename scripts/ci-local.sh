#!/usr/bin/env bash
# ci-local.sh —— X3 本地一键 CI 门禁（Windows + Git Bash 中运行）
#
# 四个阶段（任一失败立即停，快速失败，并打印失败阶段）：
#   1) ArkTS lint      DevEco codelinter CLI（-e error：存在 error 级缺陷即非 0 退出）
#   2) ArkTS 单元测试   hvigorw test + 日志 grep 判真伪失败
#                      ⚠️ hvigorw test 不以退出码门禁测试失败（失败仍 BUILD SUCCESSFUL），
#                      必须 grep 日志中的 "Error in" / "FAILED" 字样，命中即判失败
#   3) native 单元测试  WSL(Ubuntu) 内跑 scripts/run-native-tests.sh（退出码可信）
#   4) assembleHap     hvigorw assembleHap（退出码可信），并校验 HAP 产物存在
#
# 用法：
#   bash scripts/ci-local.sh
#
# 可调环境变量（默认值即本机约定）：
#   DEVECO_STUDIO     DevEco Studio 安装目录   默认 /c/Program Files/Huawei/DevEco Studio
#   DEVECO_SDK_HOME   DevEco SDK 目录          默认 $DEVECO_STUDIO/sdk（hvigor 需要 Windows 风格路径）
#   JAVA_HOME         DevEco 自带 JBR          默认 $DEVECO_STUDIO/jbr
#   WSL_DISTRO        native 测试所用 WSL 发行版名，默认 Ubuntu
#
# 产物：
#   日志与汇总报告落盘 build/ci-logs/（已被根 .gitignore 的 **/build 覆盖，不入库）
# 退出码：全部通过 0；任一阶段失败 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

DEVECO_STUDIO="${DEVECO_STUDIO:-/c/Program Files/Huawei/DevEco Studio}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-C:\Program Files\Huawei\DevEco Studio\sdk}"
export JAVA_HOME="${JAVA_HOME:-$DEVECO_STUDIO/jbr}"
export PATH="$JAVA_HOME/bin:$PATH"
HVIGORW_JS="$DEVECO_STUDIO/tools/hvigor/bin/hvigorw.js"
CODELINTER_JS="$DEVECO_STUDIO/plugins/codelinter/run/index.js"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu}"

LOG_DIR="$PROJECT_ROOT/build/ci-logs"
REPORT="$LOG_DIR/ci-report.txt"
mkdir -p "$LOG_DIR"

log()  { echo "[ci] $*"; }
die()  { echo "[ci] 错误：$*" >&2; exit 1; }

# ---------- 前置检测：路径与工具 ----------
[ -f "$HVIGORW_JS" ]    || die "找不到 hvigorw.js：$HVIGORW_JS（请确认已安装 DevEco Studio，或设 DEVECO_STUDIO 指向其安装目录）"
[ -f "$CODELINTER_JS" ] || die "找不到 codelinter CLI：$CODELINTER_JS（DevEco Studio 安装不完整，缺 plugins/codelinter）"
[ -d "$JAVA_HOME" ]     || die "找不到 JBR：$JAVA_HOME（DevEco Studio 安装不完整，缺 jbr）"
command -v node >/dev/null || die "找不到 node（Git Bash 应能通过 PATH 找到 Node.js）"
command -v wsl  >/dev/null || die "找不到 wsl 命令（native 单元测试需要 WSL2 + Ubuntu，请先安装 WSL）"
wsl -d "$WSL_DISTRO" -- true 2>/dev/null || die "WSL 发行版 '$WSL_DISTRO' 不可用（可用 wsl -l -v 查看；或用 WSL_DISTRO=<名字> 指定）"

# MSYS 路径转 WSL 路径：/c/Users/foo → /mnt/c/Users/foo
to_wsl_path() {
  local p="$1"
  case "$p" in
    /[a-zA-Z]/*)
      # 只小写盘符，路径其余部分保持原样（WSL 文件系统大小写敏感）
      local drive
      drive="$(echo "${p:1:1}" | tr 'A-Z' 'a-z')"
      echo "/mnt/$drive${p:2}" ;;
    *) die "无法把路径 '$p' 转换为 WSL 路径（期望 /c/... 形式）" ;;
  esac
}
WSL_PROJECT_ROOT="$(to_wsl_path "$PROJECT_ROOT")"

# ---------- 阶段框架：计时 + 汇总 + 快速失败 ----------
TOTAL_STAGES=4
CURRENT_STAGE=0
SUMMARY_LINES=()

print_summary() {
  local verdict="$1"
  {
    echo ""
    echo "================ CI 门禁汇总 ================"
    printf "%-4s %-22s %-10s %s\n" "阶段" "名称" "结果" "耗时"
    for line in "${SUMMARY_LINES[@]}"; do
      echo "$line"
    done
    echo "总体结果：$verdict"
    echo "日志目录：$LOG_DIR"
    echo "报告文件：$REPORT"
    echo "============================================"
  } | tee "$REPORT"
}

# run_stage <中文名> <函数>：执行阶段函数，计时；失败则打印汇总并以 1 退出
run_stage() {
  local name="$1" func="$2"
  CURRENT_STAGE=$((CURRENT_STAGE + 1))
  log "===== 阶段 $CURRENT_STAGE/$TOTAL_STAGES：$name ====="
  local start=$SECONDS
  if "$func"; then
    local dur=$((SECONDS - start))
    SUMMARY_LINES+=("$(printf "%-4s %-22s %-10s %ss" "$CURRENT_STAGE" "$name" "✅ 通过" "$dur")")
    log "阶段 $CURRENT_STAGE 通过（${dur}s）"
  else
    local dur=$((SECONDS - start))
    SUMMARY_LINES+=("$(printf "%-4s %-22s %-10s %ss" "$CURRENT_STAGE" "$name" "❌ 失败" "$dur")")
    echo "" >&2
    echo "[ci] ❌ 门禁失败于阶段 $CURRENT_STAGE：$name（日志：$LOG_DIR/stage${CURRENT_STAGE}.log）" >&2
    print_summary "❌ 失败（阶段 $CURRENT_STAGE：$name）"
    exit 1
  fi
}

run_hvigor() {
  node "$HVIGORW_JS" "$@" --mode module -p product=default --no-daemon
}

# ---------- 阶段 1：ArkTS lint ----------
stage_lint() {
  node "$CODELINTER_JS" -c code-linter.json5 -e error -o "$LOG_DIR/codelinter-report.txt" . \
    > "$LOG_DIR/stage1.log" 2>&1
}

# ---------- 阶段 2：ArkTS 单元测试 ----------
stage_arkts_test() {
  local logfile="$LOG_DIR/stage2.log"
  run_hvigor test > "$logfile" 2>&1 || return 1
  # ⚠️ hvigorw test 的退出码不可信：测试失败仍可能 BUILD SUCCESSFUL。
  # 必须 grep 日志判真伪失败（已知失败标志："Error in"、"FAILED"）。
  if grep -qE "Error in|FAILED" "$logfile"; then
    echo "[ci] hvigor 退出码为 0 但日志中发现测试失败标志：" >&2
    grep -E "Error in|FAILED" "$logfile" | head -20 >&2
    return 1
  fi
}

# ---------- 阶段 3：native 单元测试（WSL） ----------
stage_native_test() {
  # 注意：必须 bash -lc 包一层，/mnt/c 路径不能直接传给 wsl（会被 MSYS 路径转换弄坏）
  wsl -d "$WSL_DISTRO" -- bash -lc "bash '$WSL_PROJECT_ROOT/scripts/run-native-tests.sh'" \
    > "$LOG_DIR/stage3.log" 2>&1
}

# ---------- 阶段 4：assembleHap ----------
stage_assemble() {
  local logfile="$LOG_DIR/stage4.log"
  run_hvigor assembleHap > "$logfile" 2>&1 || return 1
  local hap
  hap="$(ls entry/build/default/outputs/default/*.hap 2>/dev/null | head -1)"
  if [ -z "$hap" ]; then
    echo "[ci] assembleHap 成功但未找到 HAP 产物：entry/build/default/outputs/default/*.hap" >&2
    return 1
  fi
  HAP_PATH="$PROJECT_ROOT/$hap"
  log "HAP 产物：$HAP_PATH"
}

# ---------- 主流程 ----------
log "项目根目录：$PROJECT_ROOT"
log "日志目录：$LOG_DIR"
: > "$REPORT"

run_stage "ArkTS lint（codelinter）"      stage_lint
run_stage "ArkTS 单元测试（hvigor test）"  stage_arkts_test
run_stage "native 单元测试（WSL/gtest）"   stage_native_test
run_stage "assembleHap"                  stage_assemble

print_summary "✅ 全部通过"
exit 0
