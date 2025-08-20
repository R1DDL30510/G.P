from __future__ import annotations

from scripts import hardware_inventory as hi


def test_parse_nvidia_smi() -> None:
    sample = "0, NVIDIA A100, 40536 MiB\n1, NVIDIA A100, 40536 MiB\n"
    gpus = hi.parse_nvidia_smi(sample)
    assert gpus == [
        {"index": 0, "vendor": "NVIDIA", "name": "NVIDIA A100", "memory_mb": 40536},
        {"index": 1, "vendor": "NVIDIA", "name": "NVIDIA A100", "memory_mb": 40536},
    ]


def test_parse_rocm_smi() -> None:
    sample = "GPU ID, GPU Name\n0, gfx1030\n"
    gpus = hi.parse_rocm_smi(sample)
    assert gpus == [{"index": 0, "vendor": "AMD", "name": "gfx1030", "memory_mb": None}]


def test_get_cpu_info_linux(monkeypatch) -> None:
    def fake_run(cmd: list[str]) -> str:  # type: ignore[override]
        if cmd == ["lscpu"]:
            return (
                "Model name: TestCPU\n"
                "Socket(s): 1\n"
                "Core(s) per socket: 4\n"
                "CPU(s): 8\n"
            )
        if cmd[:2] == ["grep", "MemTotal"]:
            return "MemTotal:       16384000 kB\n"
        return ""

    monkeypatch.setattr(hi, "_run", fake_run)
    monkeypatch.setattr(hi.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(hi.platform, "system", lambda: "Linux")
    monkeypatch.setattr(hi.os, "cpu_count", lambda: 8)

    info = hi.get_cpu_info()
    assert info["name"] == "TestCPU"
    assert info["cores"] == 4
    assert info["threads"] == 8
    assert info["memory_gb"] == 15.62


def test_get_cpu_info_windows(monkeypatch) -> None:
    def fake_run(cmd: list[str]) -> str:  # type: ignore[override]
        if cmd == ["wmic", "cpu", "get", "Name,NumberOfCores", "/format:csv"]:
            return "Node,Name,NumberOfCores\nDESKTOP,WinCPU,6\n"
        if cmd == [
            "wmic",
            "computersystem",
            "get",
            "totalphysicalmemory",
            "/format:value",
        ]:
            return "TotalPhysicalMemory=17179869184\n"
        return ""

    monkeypatch.setattr(hi, "_run", fake_run)
    monkeypatch.setattr(hi.platform, "machine", lambda: "AMD64")
    monkeypatch.setattr(hi.platform, "system", lambda: "Windows")
    monkeypatch.setattr(hi.os, "cpu_count", lambda: 12)

    info = hi.get_cpu_info()
    assert info["name"] == "WinCPU"
    assert info["cores"] == 6
    assert info["threads"] == 12
    assert info["memory_gb"] == 16.0
