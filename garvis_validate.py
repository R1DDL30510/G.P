"""Cross-platform validation script for the GARVIS stack."""
import json
import os
import socket
import subprocess
import time
import shutil
from pathlib import Path

import requests
import yaml

BASE_DIR = Path(__file__).resolve().parent
ROUTER_YAML = BASE_DIR / "router" / "router.yaml"
EXPECTED_PORTS = [11434, 11435, 11436, 11437, 28100]
HTTP_TIMEOUT = 4
LOG_DIR = BASE_DIR / "logs"
LOG_DIR.mkdir(exist_ok=True)

report = {
    "meta": {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "base_dir": str(BASE_DIR),
    },
    "results": [],
    "summary": {},
}


def add_result(name, status, data=None):
    report["results"].append({"name": name, "status": status, "data": data or {}})


def port_listening(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


# core paths
paths = [BASE_DIR / "router" / "logs", BASE_DIR / "evaluator", BASE_DIR / "start_all.sh"]
missing = [str(p) for p in paths if not p.exists()]
add_result(
    "core paths present",
    "pass" if not missing else "fail",
    {"checked": [str(p) for p in paths], "missing": missing},
)

# ollama CLI
ollama = shutil.which("ollama")
if not ollama:
    add_result("ollama in PATH", "fail", {"path": None})
else:
    try:
        ver = (
            subprocess.check_output([ollama, "--version"], timeout=10)
            .decode()
            .strip()
        )
        add_result("ollama in PATH", "pass", {"path": ollama, "version": ver})
    except subprocess.TimeoutExpired:
        add_result(
            "ollama in PATH",
            "warn",
            {"path": ollama, "note": "version call timed out"},
        )

# expected ports
port_details = []
missing_ports = []
for port in EXPECTED_PORTS:
    ok = port_listening(port)
    port_details.append({"port": port, "listening": ok})
    if not ok:
        missing_ports.append(port)
add_result(
    "expected ports listening",
    "pass" if not missing_ports else "fail",
    {"details": port_details, "missing": missing_ports},
)

# HTTP endpoints
endpoints = [
    ("gpu0", f"http://127.0.0.1:11434/api/tags"),
    ("gpu1", f"http://127.0.0.1:11435/api/tags"),
    ("cpu", f"http://127.0.0.1:11436/api/tags"),
    ("eval", f"http://127.0.0.1:11437/api/tags"),
]
http_data = []
bad = []
for key, url in endpoints:
    try:
        r = requests.get(url, timeout=HTTP_TIMEOUT)
        ok = r.status_code == 200
        http_data.append({"key": key, "url": url, "ok": ok, "code": r.status_code})
        if not ok:
            bad.append(key)
    except Exception as e:
        http_data.append({"key": key, "url": url, "ok": False, "error": str(e)})
        bad.append(key)
add_result(
    "HTTP endpoints reachable",
    "pass" if not bad else "warn",
    {"details": http_data},
)

# router.yaml consistency
if not ROUTER_YAML.exists():
    add_result(
        "router.yaml present",
        "fail",
        {"path": str(ROUTER_YAML)},
    )
else:
    with open(ROUTER_YAML, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    issues = []
    eps = list(cfg.get("endpoints", {}).keys())
    inv = list(cfg.get("inventory", {}).keys())
    for alias in inv:
        meta = cfg["inventory"].get(alias, {})
        ep_key = meta.get("endpoint")
        if ep_key not in eps:
            issues.append(f"inventory '{alias}' endpoint '{ep_key}' not in endpoints")
        if "real_model" not in meta.get("params", {}):
            issues.append(f"inventory '{alias}' missing params.real_model")
    status_cfg = "pass" if not issues else "fail"
    add_result(
        "router.yaml consistency",
        status_cfg,
        {"issues": issues, "endpoints": eps, "inventory": inv},
    )

# summary
pass_count = sum(1 for r in report["results"] if r["status"] == "pass")
warn_count = sum(1 for r in report["results"] if r["status"] == "warn")
fail_count = sum(1 for r in report["results"] if r["status"] == "fail")
report["summary"] = {"pass": pass_count, "warn": warn_count, "fail": fail_count}

report_path = LOG_DIR / f"validate_{time.strftime('%Y%m%d_%H%M%S')}.json"
with open(report_path, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)

print(json.dumps(report, ensure_ascii=False, indent=2))
print(f"JSON report: {report_path}")
