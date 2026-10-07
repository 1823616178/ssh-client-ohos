#!/usr/bin/env python3
"""Q4 HAP package scanner.

Usage: python3 check_hap_scan.py EXTRACT_DIR ALLOWED_DOMAINS_CSV
Exit 0 = clean; 1 = findings; 2 = bad input.

Checks:
  - PEM private keys / plaintext password|token|apiKey|SYNC secrets
    (SYNC_API_URL=http... is allowed, DESIGN §6.5.1 / D10)
  - network_config.json: base cleartextTrafficPermitted must be false;
    cleartext domain-config names must be subset of allowed list
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SECRET_KEYS = (
    r"password|passwd|passphrase|pwd|apiKey|api_key|apiSecret|api_secret|"
    r"clientSecret|SYNC_SECRET|SYNC_PRIVATE_KEY|privateKey|private_key|"
    r"secret|refresh_token"
)

PATTERNS = [
    (
        "private-key-block",
        re.compile(
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"
        ),
    ),
    (
        "json-secret-kv",
        re.compile(
            r'(?i)"(?:'
            + SECRET_KEYS
            + r')"\s*:\s*"(?!\*\*\*)(?!")(?:[^"\\]|\\.)+"'
        ),
    ),
    (
        "plain-secret-kv",
        re.compile(
            r"(?i)\b(?:" + SECRET_KEYS + r")(\s*[=:]\s*)(?!\*\*\*)(?!\s*$)[^\s,;&\"']+"
        ),
    ),
]


def allowed_sync_api_url(text: str, start: int) -> bool:
    window = text[max(0, start - 40) : start + 80]
    return "SYNC_API_URL" in window and "http" in window


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: check_hap_scan.py EXTRACT_DIR ALLOWED_DOMAINS_CSV", file=sys.stderr)
        return 2
    root = Path(argv[1])
    allowed_domains = [d.strip() for d in argv[2].split(",") if d.strip()]
    if not root.is_dir():
        print(f"[check-hap] 扫描目录不存在：{root}", file=sys.stderr)
        return 2

    failures: list[str] = []
    warnings: list[str] = []
    scanned = 0

    for path in sorted(root.rglob("*")):
        if not path.is_file():
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
        try:
            rel = str(path.relative_to(root))
        except ValueError:
            rel = str(path)

        for name, pat in PATTERNS:
            for m in pat.finditer(text):
                snippet = m.group(0)
                if "SYNC_API_URL" in snippet and "http" in snippet:
                    continue
                if allowed_sync_api_url(text, m.start()):
                    continue
                if len(snippet) > 120:
                    snippet = snippet[:117] + "..."
                failures.append(f"{rel} [{name}] {snippet}")

    nc_candidates = list(root.rglob("network_config.json"))
    if not nc_candidates:
        warnings.append("HAP 内未找到 network_config.json（若构建未带 profile，需人工确认）")

    for nc in nc_candidates:
        rel = str(nc.relative_to(root))
        try:
            data = json.loads(nc.read_text(encoding="utf-8"))
        except Exception as e:
            failures.append(f"{rel} JSON 解析失败: {e}")
            continue
        nsc = data.get("network-security-config") or data.get("networkSecurityConfig") or {}
        base = nsc.get("base-config") or nsc.get("baseConfig") or {}
        if base.get("cleartextTrafficPermitted") is not False:
            failures.append(
                f"{rel} base-config.cleartextTrafficPermitted 必须为 false"
                f"（当前: {base.get('cleartextTrafficPermitted')}）"
            )
        doms: list[str] = []
        for entry in nsc.get("domain-config") or nsc.get("domainConfig") or []:
            if entry.get("cleartextTrafficPermitted") is not True:
                continue
            for d in entry.get("domains") or []:
                name = d.get("name")
                if name:
                    doms.append(name)
        for name in doms:
            if name not in allowed_domains:
                failures.append(
                    f"{rel} 放行了未授权明文域名: {name}（允许集合: {allowed_domains}）"
                )
        print(f"[check-hap] network_config {rel}: cleartext domains={doms} allowed={allowed_domains}")

    print(f"[check-hap] 扫描文件数: {scanned}")
    for w in warnings:
        print(f"[check-hap] WARN {w}")
    if failures:
        print(f"[check-hap] ❌ 发现 {len(failures)} 项风险：")
        for item in failures[:40]:
            print(f"  {item}")
        if len(failures) > 40:
            print(f"  ... 另有 {len(failures) - 40} 项")
        return 1
    print("[check-hap] ✅ HAP 自查通过：无私钥/秘密残留，network_config 域名符合白名单")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
