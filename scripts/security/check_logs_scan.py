#!/usr/bin/env python3
"""Q4 log redaction scanner.

Usage: python3 check_logs_scan.py LOG_DIR
Exit 0 = no plaintext secrets; 1 = hits; 2 = bad input.
Aligned with entry/src/main/ets/common/utils/Logger.ets sanitize rules:
***-redacted values are NOT hits.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

KEYS = (
    r"password|passwd|passphrase|pwd|token|accessToken|refreshToken|"
    r"privateKey|private_key|secret"
)

PATTERNS = [
    (
        "private-key-block",
        re.compile(
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"
        ),
    ),
    (
        "json-kv-plaintext",
        re.compile(
            r'(?i)"(?:' + KEYS + r')"\s*:\s*"(?!\*\*\*)(?:[^"\\]|\\.)+"'
        ),
    ),
    (
        "authorization-plaintext",
        re.compile(r"(?i)\bauthorization\s*[=:]\s*(?!\*\*\*)\S+"),
    ),
    (
        "bearer-plaintext",
        re.compile(r"(?i)\bBearer\s+(?!\*\*\*)\S+"),
    ),
    (
        "plain-kv-plaintext",
        re.compile(
            r"(?i)\b(?:" + KEYS + r")(\s*[=:]\s*)(?!\*\*\*)(?!\s*$)[^\s,;&\"']+"
        ),
    ),
]

TEXT_EXT = {".log", ".txt", ".json", ".xml", ".out", ".err", ".md", ".ets", ".js", ".ts", ".cfg", ".conf", ""}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: check_logs_scan.py LOG_DIR", file=sys.stderr)
        return 2
    root = Path(argv[1])
    if not root.is_dir():
        print(f"[check-logs] 目录不存在：{root}", file=sys.stderr)
        return 2

    hits: list[tuple[str, int, str, str]] = []
    scanned = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() not in TEXT_EXT and path.suffix != "":
            continue
        try:
            raw = path.read_bytes()
        except Exception:
            continue
        if b"\x00" in raw[:4096]:
            continue
        try:
            text = raw.decode("utf-8", errors="replace")
        except Exception:
            continue
        scanned += 1
        for name, pat in PATTERNS:
            for m in pat.finditer(text):
                snippet = m.group(0)
                if len(snippet) > 120:
                    snippet = snippet[:117] + "..."
                line_no = text[: m.start()].count("\n") + 1
                try:
                    rel = str(path.relative_to(root))
                except ValueError:
                    rel = str(path)
                hits.append((rel, line_no, name, snippet))

    print(f"[check-logs] 扫描文件数: {scanned}")
    if not hits:
        print("[check-logs] ✅ 未发现明文敏感字段")
        return 0

    print(f"[check-logs] ❌ 发现 {len(hits)} 处疑似明文敏感字段：")
    for rel, line_no, name, snippet in hits[:50]:
        print(f"  {rel}:{line_no} [{name}] {snippet}")
    if len(hits) > 50:
        print(f"  ... 另有 {len(hits) - 50} 处")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
