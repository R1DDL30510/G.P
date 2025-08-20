#!/usr/bin/env python3
"""Generate router configuration from template with hardware placeholders."""
from __future__ import annotations

import argparse
import os
import subprocess
from pathlib import Path
from string import Template


def _detect_gpus() -> list[dict[str, str]]:
    """Return list of GPUs with name and VRAM in GB."""
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total",
                "--format=csv,noheader",
            ],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return []

    gpus = []
    for line in out.strip().splitlines():
        try:
            name, mem = [p.strip() for p in line.split(",", 1)]
            # memory reported like "8192 MiB"
            mem_mb = int(mem.split()[0])
            mem_gb = str(int(mem_mb / 1024))
            gpus.append({"name": name, "vram": mem_gb})
        except Exception:
            continue
    return gpus


def render(template: Path, output: Path) -> None:
    gpus = _detect_gpus()

    env = {
        "CPU_NAME": os.environ.get("CPU_NAME", "CPU"),
        "CPU_VRAM": os.environ.get("CPU_VRAM", "0"),
    }
    # ensure placeholders for at least two GPUs
    for idx in range(max(2, len(gpus))):
        if idx < len(gpus):
            env[f"GPU{idx}_NAME"] = gpus[idx]["name"]
            env[f"GPU{idx}_VRAM"] = gpus[idx]["vram"]
        else:
            env[f"GPU{idx}_NAME"] = os.environ.get(f"GPU{idx}_NAME", f"GPU{idx}")
            env[f"GPU{idx}_VRAM"] = os.environ.get(f"GPU{idx}_VRAM", "0")

    tpl = Template(template.read_text())
    rendered = tpl.safe_substitute(env)
    output.write_text(rendered)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("template", type=Path, help="Template router.yaml path")
    ap.add_argument("output", type=Path, help="Output config path")
    args = ap.parse_args()
    render(args.template, args.output)
