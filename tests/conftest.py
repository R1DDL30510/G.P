import importlib
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def router_module():
    """Import gar_router.py if available; otherwise skip dependent tests."""
    try:
        with patch.object(sys, "argv", sys.argv[:1]):
            return importlib.import_module("router.gar_router")
    except ModuleNotFoundError:
        try:
            with patch.object(sys, "argv", sys.argv[:1]):
                return importlib.import_module("gar_router")
        except ModuleNotFoundError:
            pytest.skip("gar_router module not found; routing tests skipped.")


@pytest.fixture(scope="session")
def router_config_path():
    path = ROOT / "router" / "router.yaml"
    if not path.exists():
        pytest.skip("router/router.yaml not found; schema tests skipped.")
    return path


@pytest.fixture(scope="session")
def router_config(router_config_path):
    with open(router_config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


CANDIDATE_FUNCS = [
    "decide_route",
    "select_endpoint",
    "choose_endpoint",
    "route_request",
    "route",
]


def _find_decider(router_module: types.ModuleType):
    for name in CANDIDATE_FUNCS:
        fn = getattr(router_module, name, None)
        if callable(fn):
            return fn
    pytest.skip(
        "No routing function found in gar_router. "
        f"Export one of: {', '.join(CANDIDATE_FUNCS)}"
    )


@pytest.fixture(scope="module")
def decider(router_module):
    return _find_decider(router_module)


@pytest.fixture(scope="module")
def mini_config():
    return {
        "endpoints": {
            "gpu0": {
                "host": "http://127.0.0.1",
                "port": 11434,
                "hardware": {"vram_gb": 24},
            },
            "cpu": {"host": "http://127.0.0.1", "port": 11436, "hardware": {}},
        },
        "model_map": {
            "gar-chat": "gpu0",
            "gar-reason": "gpu0",
            "small-cpu": "cpu",
        },
        "keywords": {
            "code": ["python", "typescript", "stack trace"],
            "math": ["integral", "matrix", "derivative"],
        },
        "defaults": {"fallback_endpoint": "cpu"},
    }
