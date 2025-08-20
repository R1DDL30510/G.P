# Full Stack Overview

This document maps the GARVIS stack, outlining the purpose of each directory, the dependencies it uses, and how to set up the environment.

## Prerequisites

- Python 3.11+
- [Ollama](https://ollama.com/) installed locally
- Git

## Directory structure

| Path | Purpose |
| --- | --- |
| `OllamaCPU/`, `OllamaGPU0/`, `OllamaGPU1/` | Model stores for CPU and GPU-specific Ollama instances. Created automatically by the start scripts. |
| `evaluator/` | FastAPI proxy mirroring Ollama `/api/generate` and logging routing decisions. |
| `router/` | Heuristic router server and YAML configuration (`router.yaml`). |
| `ollama/` | Example Modelfiles for custom models. |
| `config/` | Environment templates and JSON configuration (`development.json`, `production.json`, `env.example`, `remote.env.example`, `schema.json`). |
| `scripts/` | Utilities such as `install_dev_dependencies.sh`, `generate_router_config.py`, `hardware_inventory.py`, `validate_config.py`, `watchdog.sh`. |
| `tests/` | Pytest suite and load-testing scripts. |
| `docs/` | Documentation, including this guide, configuration reference, and remote setup. |
| `SERVICES/` | Windows service wrappers. |
| `tools/` | Helper PowerShell scripts (`analyze_logs.ps1`, `bench_ollama.ps1`). |
| `start_all.sh`, `start_all.ps1` | Cross-platform scripts to launch the full stack. |
| `garvis_validate.py` / `.ps1` | Stack validation utilities producing JSON reports. |
| `.github/workflows/ci.yml` | GitHub Actions pipeline for linting and tests. |
| `.pre-commit-config.yaml` | Pre-commit hooks configuration. |
| `pyproject.toml` | Tooling configuration for Ruff, Black, Mypy, and Pytest. |

## Dependencies

Runtime dependency (`requirements.txt`):

- `jsonschema` – runtime schema validation for configuration files.

Development tools (`requirements-dev.txt`):

- `pytest` – test runner
- `pytest-cov` – coverage reporting for tests
- `pyyaml` – YAML utilities
- `jsonschema` – schema validation in tests
- `ruff` – linting and code style checks
- `black` – Python formatter
- `mypy` – static type checking
- `yamllint` – YAML linter
- `pre-commit` – hook management
- `fastapi` – evaluator proxy framework
- `requests` – HTTP client for tests
- `types-PyYAML`, `types-requests`, `types-jsonschema` – typing stubs

Install all development dependencies with:

```
scripts/install_dev_dependencies.sh
pre-commit install
```

## Setup

1. Ensure Ollama and Python 3.11+ are installed.
2. Install project dependencies:

```
scripts/install_dev_dependencies.sh
```

3. Start the stack:

```
./start_all.sh          # Linux/macOS
# or
Start-Process powershell -Verb RunAs -ArgumentList "-File start_all.ps1"  # Windows
```

The script boots Ollama instances for each GPU and the CPU, generates `router/router.generated.yaml`, then launches the router and evaluator services.

## Testing and validation

Run linters and tests:

```
pre-commit run --all-files
pytest
```

Validate a running stack without altering state:

```
python garvis_validate.py
```

## Additional notes

- `config/env` allows overriding default ports or the `ollama` binary path.
- Logs are written under `logs/` during runtime.
- Example Modelfiles reside in `ollama/` and can be customized.
- For remote deployment guidelines see `docs/remote-setup.md`.
