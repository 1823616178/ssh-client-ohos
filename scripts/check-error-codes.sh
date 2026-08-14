#!/usr/bin/env bash
# check-error-codes.sh —— N13 统一错误码两面对拍（CI 门禁附加步骤）
#
# 从两侧源码各自 grep 出错误码表（名字=数值），diff 比对：
#   - ArkTS 侧：entry/src/main/ets/common/SshError.ets 的 SshErrorCode 枚举
#     （X4 中文文案表锚点，单一事实来源）；
#   - native 侧：entry/src/main/cpp/ssh/error_codes.h 的 kSshErrorCode* 常量
#     （toSshErrorCode 映射所用；命名约定 kSshErrorCode<CamelCase>，去掉前缀后
#     按 CamelCase→UPPER_SNAKE 转换须与 ArkTS 枚举成员同名）。
# native 独有的 kSshErrorCodeNone=0（「无错误」保留值，bridge 不投递）不参与比对。
#
# 退出码：两侧码表一致 0；不一致 / 文件缺失 / 提取为空 1（门禁失败）。
# 用法：bash scripts/check-error-codes.sh（Git Bash 与 WSL 均可运行）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ARKTS_FILE="$PROJECT_ROOT/entry/src/main/ets/common/SshError.ets"
NATIVE_FILE="$PROJECT_ROOT/entry/src/main/cpp/ssh/error_codes.h"

log() { echo "[check-error-codes] $*"; }
die() { echo "[check-error-codes] 错误：$*" >&2; exit 1; }

[ -f "$ARKTS_FILE" ]  || die "找不到 ArkTS 码表：$ARKTS_FILE"
[ -f "$NATIVE_FILE" ] || die "找不到 native 码表：$NATIVE_FILE"

# ArkTS：枚举成员行形如「  DNS_FAILED = 101,」（两个空格缩进；末行逗号可省）
arkts_table() {
  grep -oE '^  [A-Z][A-Z0-9_]+ = [0-9]+,?' "$ARKTS_FILE" \
    | tr -d ', ' | sort
}

# native：常量行形如「kSshErrorCodeDnsFailed = 101」；
# 去前缀后 CamelCase → UPPER_SNAKE（Publickey → PUBLICKEY，与 ArkTS 命名对齐）；
# None=0 为 native 独有保留值，剔除
native_table() {
  grep -oE 'kSshErrorCode[A-Za-z0-9]+ = [0-9]+' "$NATIVE_FILE" \
    | grep -v '^kSshErrorCodeNone ' \
    | sed -E 's/^kSshErrorCode([A-Za-z0-9]+) = ([0-9]+)/\1=\2/' \
    | sed -E 's/([A-Z])/_\1/g' \
    | tr 'a-z' 'A-Z' \
    | sed -E 's/^_([A-Z0-9_]+)=([0-9]+)$/\1=\2/' \
    | sort
}

ARKTS_TABLE="$(arkts_table)"
NATIVE_TABLE="$(native_table)"

[ -n "$ARKTS_TABLE" ]  || die "从 $ARKTS_FILE 未提取到任何枚举成员（格式变了？请同步更新本脚本）"
[ -n "$NATIVE_TABLE" ] || die "从 $NATIVE_FILE 未提取到任何常量（格式变了？请同步更新本脚本）"

if [ "$ARKTS_TABLE" = "$NATIVE_TABLE" ]; then
  COUNT="$(printf '%s\n' "$ARKTS_TABLE" | wc -l)"
  log "两侧错误码表一致（$COUNT 个码）：$ARKTS_FILE ↔ $NATIVE_FILE"
  exit 0
fi

echo "[check-error-codes] 错误：两侧错误码表不一致（< ArkTS SshError.ets / > native error_codes.h）：" >&2
diff <(printf '%s\n' "$ARKTS_TABLE") <(printf '%s\n' "$NATIVE_TABLE") >&2 || true
echo "[check-error-codes] 请同步两侧码表（N13：新增/修改错误码须同时改 SshError.ets 与 error_codes.h）" >&2
exit 1
