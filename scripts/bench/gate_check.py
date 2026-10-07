#!/usr/bin/env python3
"""Q2 bench gate: evaluate report JSON against DESIGN §1.2 thresholds.

Usage: python3 gate_check.py REPORT MIN_FPS MAX_RSS_MB REQUIRE_ALL STRICT_DRY
Exit 0 pass, 1 fail, 2 bad usage/input.
Semantics locked with entry/src/test/BenchMetrics.ets.
"""
from __future__ import annotations

import json
import sys

REQUIRED = ["cat_5mb", "yes_burst", "host_list_100", "pane_4_concurrent"]


def is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def main(argv: list[str]) -> int:
    if len(argv) < 6:
        print("usage: gate_check.py REPORT MIN_FPS MAX_RSS_MB REQUIRE_ALL STRICT_DRY", file=sys.stderr)
        return 2
    report, min_fps_s, max_rss_s, require_all_s, strict_dry_s = argv[1:6]
    try:
        min_fps = float(min_fps_s)
        max_rss = float(max_rss_s)
    except ValueError:
        print("[bench-gate] 阈值必须是数字", file=sys.stderr)
        return 2
    require_all = require_all_s == "1"
    strict_dry = strict_dry_s == "1"

    try:
        with open(report, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[bench-gate] JSON 解析失败: {e}", file=sys.stderr)
        return 2

    if not isinstance(data, dict) or data.get("schemaVersion") != 1:
        print("[bench-gate] 报告 schemaVersion 必须为 1", file=sys.stderr)
        return 2
    scenarios = data.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        print("[bench-gate] 报告缺少 scenarios[]", file=sys.stderr)
        return 2

    failures: list[str] = []
    seen: set[str] = set()
    measured_count = 0

    for s in scenarios:
        sid = s.get("id", "<missing>")
        status = s.get("status", "")
        fps = s.get("fpsAvg")
        rss = s.get("rssPeakMb")
        seen.add(sid)
        measured = is_num(fps) or is_num(rss)

        if status in ("dry-run", "skipped"):
            print(f"[bench-gate] {sid}: {status}（未实测）")
            if strict_dry or require_all:
                failures.append(f"{sid}: {status} 在 requireAll/strict 下不允许（缺少实测）")
            continue

        if not measured:
            if require_all:
                failures.append(f"{sid}: 缺少实测 fps/rss")
            else:
                print(f"[bench-gate] {sid}: status={status} 但无数值，跳过门禁")
            continue

        measured_count += 1
        if is_num(fps):
            if fps < min_fps:
                failures.append(f"{sid}: fpsAvg={fps} < {min_fps}")
        elif require_all:
            failures.append(f"{sid}: 缺少 fpsAvg")

        if is_num(rss):
            if rss >= max_rss:
                failures.append(f"{sid}: rssPeakMb={rss} >= {max_rss}")
        elif require_all:
            failures.append(f"{sid}: 缺少 rssPeakMb")

    if require_all:
        for rid in REQUIRED:
            if rid not in seen:
                failures.append(f"缺少场景: {rid}")

    print(f"[bench-gate] 阈值: minFps={min_fps} maxRssMb={max_rss} requireAll={require_all}")
    print(f"[bench-gate] 报告: {report}")
    print(f"[bench-gate] 可门禁实测场景数: {measured_count}")

    if failures:
        for item in failures:
            print(f"[bench-gate] FAIL {item}")
        print("[bench-gate] 门禁结果: FAIL")
        return 1
    print("[bench-gate] 门禁结果: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
