#!/usr/bin/env python3
"""Collect hardware inventory information.

This script gathers CPU and GPU details from the current machine to help with
routing and model configuration. Information is collected using native tools
when available (``nvidia-smi`` for NVIDIA GPUs and ``rocm-smi`` for AMD GPUs).
On Windows, ``wmic`` is used as a fallback for CPU and GPU information, while
Linux systems fall back to ``lspci``.

The collected data is printed as JSON or written to ``--output``.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, List


def _run(cmd: List[str]) -> str:
    """Run *cmd* and return its stdout as text, ignoring errors."""
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
    except Exception:
        return ""


def get_cpu_info() -> Dict[str, Any]:
    """Return basic CPU information."""
    info: Dict[str, Any] = {
        "architecture": platform.machine(),
    }

    # Logical thread count
    threads = os.cpu_count()
    if threads is not None:
        info["threads"] = threads

    if platform.system() == "Windows":
        cpu_out = _run(["wmic", "cpu", "get", "Name,NumberOfCores", "/format:csv"])
        for line in cpu_out.splitlines():
            line = line.strip()
            if not line or line.startswith("Node"):
                continue
            parts = line.split(",")
            if len(parts) >= 3:
                info["name"] = parts[1].strip()
                try:
                    info["cores"] = int(parts[2].strip())
                except ValueError:
                    pass
                break

        mem_out = _run(
            [
                "wmic",
                "computersystem",
                "get",
                "totalphysicalmemory",
                "/format:value",
            ]
        )
        match = re.search(r"TotalPhysicalMemory=(\d+)", mem_out)
        if match:
            info["memory_gb"] = round(int(match.group(1)) / 1024 / 1024 / 1024, 2)
        return info

    lscpu = _run(["lscpu"])
    if lscpu:
        sockets = cores_per_socket = None
        for line in lscpu.splitlines():
            if "Model name" in line:
                info["name"] = line.split(":", 1)[1].strip()
            elif "Socket(s):" in line:
                try:
                    sockets = int(line.split(":", 1)[1])
                except ValueError:
                    pass
            elif "Core(s) per socket:" in line:
                try:
                    cores_per_socket = int(line.split(":", 1)[1])
                except ValueError:
                    pass
        if sockets is not None and cores_per_socket is not None:
            info["cores"] = sockets * cores_per_socket

    meminfo = _run(["grep", "MemTotal", "/proc/meminfo"])
    if meminfo:
        match = re.search(r"(\d+)", meminfo)
        if match:
            mem_kb = int(match.group(1))
            info["memory_gb"] = round(mem_kb / 1024 / 1024, 2)

    return info


def parse_nvidia_smi(output: str) -> List[Dict[str, Any]]:
    """Parse ``nvidia-smi`` CSV output."""
    gpus: List[Dict[str, Any]] = []
    for line in output.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) != 3:
            continue
        idx, name, mem = parts
        try:
            mem_mb = int(mem.split()[0])
        except (ValueError, IndexError):
            continue
        gpus.append(
            {
                "index": int(idx),
                "vendor": "NVIDIA",
                "name": name,
                "memory_mb": mem_mb,
            }
        )
    return gpus


def detect_nvidia_gpus() -> List[Dict[str, Any]]:
    out = _run(
        [
            "nvidia-smi",
            "--query-gpu=index,name,memory.total",
            "--format=csv,noheader",
        ]
    )
    if not out:
        return []
    return parse_nvidia_smi(out)


def parse_rocm_smi(output: str) -> List[Dict[str, Any]]:
    """Parse ``rocm-smi`` CSV output."""
    gpus: List[Dict[str, Any]] = []
    lines = [ln.strip() for ln in output.splitlines() if ln.strip()]
    if not lines or "," not in lines[0]:
        return gpus
    for line in lines[1:]:
        parts = [p.strip() for p in line.split(",", 1)]
        if len(parts) != 2:
            continue
        idx, name = parts
        gpus.append(
            {
                "index": int(idx),
                "vendor": "AMD",
                "name": name,
                "memory_mb": None,
            }
        )
    return gpus


def detect_amd_gpus() -> List[Dict[str, Any]]:
    out = _run(["rocm-smi", "--showproductname", "--csv"])
    if not out:
        return []
    return parse_rocm_smi(out)


def detect_other_gpus() -> List[Dict[str, Any]]:
    """Detect non NVIDIA/AMD GPUs using platform specific tools."""
    gpus: List[Dict[str, Any]] = []
    if platform.system() == "Windows":
        out = _run(["wmic", "path", "win32_VideoController", "get", "Name"])
        for line in out.splitlines():
            name = line.strip()
            if name and name != "Name":
                gpus.append(
                    {
                        "index": None,
                        "vendor": "OTHER",
                        "name": name,
                        "memory_mb": None,
                    }
                )
        return gpus

    out = _run(["lspci"])
    for line in out.splitlines():
        if re.search(r"vga|3d", line, re.IGNORECASE):
            try:
                name = line.split(": ", 1)[1]
            except IndexError:
                continue
            gpus.append(
                {"index": None, "vendor": "OTHER", "name": name, "memory_mb": None}
            )
    return gpus


def collect_hardware() -> Dict[str, Any]:
    """Collect CPU and GPU information."""
    gpus = detect_nvidia_gpus()
    if not gpus:
        gpus = detect_amd_gpus()
    if not gpus:
        gpus = detect_other_gpus()
    return {"cpu": get_cpu_info(), "gpus": gpus}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Optional output JSON file")
    args = parser.parse_args()

    data = collect_hardware()
    text = json.dumps(data, indent=2)
    if args.output:
        args.output.write_text(text)
    else:
        print(text)


if __name__ == "__main__":
    main()
