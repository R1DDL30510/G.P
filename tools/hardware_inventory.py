#!/usr/bin/env python3
"""Hardware inventory utility.

Detects available GPUs and CPU, updates ``router/router.yaml`` with the
corresponding ``hardware`` entries and creates model directories for each
device under the repository root.  The script can be executed standalone or
called from other scripts (e.g. ``start_all.sh``).
"""
from __future__ import annotations

import platform
import subprocess
from pathlib import Path
from typing import Dict


def _detect_gpus() -> Dict[str, Dict[str, int]]:
    """Return a mapping of gpu keys to name and VRAM (in GB)."""
    gpus: Dict[str, Dict[str, int]] = {}
    try:
        out = subprocess.check_output(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total",
                "--format=csv,noheader",
            ],
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return gpus

    for idx, line in enumerate(out.strip().splitlines()):
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        name, mem = parts[:2]
        try:
            vram_gb = int(int(mem.split()[0]) / 1024)
        except ValueError:
            vram_gb = 0
        gpus[f"gpu{idx}"] = {"name": name, "vram_gb": vram_gb}
    return gpus


def _detect_cpu() -> Dict[str, Dict[str, int]]:
    name = platform.processor() or platform.machine() or "CPU"
    return {"cpu": {"name": name, "vram_gb": 0}}


def _update_router_yaml(hardware: Dict[str, Dict[str, int]], router_path: Path) -> None:
    """Replace the ``hardware`` block in ``router.yaml`` with ``hardware``."""
    if router_path.exists():
        lines = router_path.read_text().splitlines(keepends=True)
    else:
        lines = []

    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith("hardware:"):
            start = i
            break

    block = ["hardware:\n"]
    for key, info in hardware.items():
        block.append(
            f"  {key}: {{name: {info['name']}, vram_gb: {info['vram_gb']}}}\n"
        )
    block.append("\n")

    if start is not None:
        end = start + 1
        while end < len(lines) and (
            lines[end].startswith(" ")
            or lines[end].strip() == ""
            or lines[end].lstrip().startswith("#")
        ):
            end += 1
        lines[start:end] = block
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.extend(block)

    router_path.write_text("".join(lines))


def _create_model_dirs(hardware: Dict[str, Dict[str, int]], root_dir: Path) -> None:
    for key in hardware.keys():
        if key.startswith("gpu"):
            dir_path = root_dir / f"OllamaGPU{key[3:]}"
        else:
            dir_path = root_dir / "OllamaCPU"
        (dir_path / "manifests").mkdir(parents=True, exist_ok=True)


def main() -> None:
    root_dir = Path(__file__).resolve().parents[1]
    router_path = root_dir / "router" / "router.yaml"

    hardware: Dict[str, Dict[str, int]] = {}
    hardware.update(_detect_gpus())
    hardware.update(_detect_cpu())

    _update_router_yaml(hardware, router_path)
    _create_model_dirs(hardware, root_dir)

    print(
        f"Detected {len([k for k in hardware if k.startswith('gpu')])} GPU(s) and "
        f"CPU {hardware['cpu']['name']}"
    )


if __name__ == "__main__":
    main()
