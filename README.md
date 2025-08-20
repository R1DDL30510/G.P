# GARVIS Stack

GARVIS is a local multi‑model routing stack built on top of [Ollama](https://ollama.com/). It runs separate Ollama instances for two GPUs and the CPU and exposes a single API that automatically selects the best model and hardware based on the prompt.

## Features

- **Multiple Ollama nodes** – dedicated model stores for GPU0, GPU1 and CPU.
- **Router service** – chooses the target backend using alias mappings, keyword heuristics and hardware constraints.
- **Evaluator proxy** – FastAPI layer that mirrors the Ollama `/api/generate` endpoint and logs routing decisions.
- **Cross‑platform start scripts** – `start_all.sh` and `start_all.ps1` spin up the complete stack, kill conflicting processes and run health checks.
- **Validation utilities** – `garvis_validate.py` and `garvis_validate.ps1` audit running instances, ports and configuration.

## Repository layout

```
OllamaCPU/      Model store for the CPU instance
OllamaGPU0/     Model store for GPU0
OllamaGPU1/     Model store for GPU1
evaluator/      FastAPI evaluator proxy
router/         Heuristic router and YAML configuration
ollama/         Example Modelfiles (e.g. custom assistant)
SERVICES/       Windows service wrappers
tests/          Basic load‑test scripts
```

## Quick start

### Linux/macOS

```bash
# ensure `ollama` and Python 3.11+ are installed
./start_all.sh
```

### Windows

```
Start-Process powershell -Verb RunAs -ArgumentList "-File start_all.ps1"
```

The script launches three Ollama servers, the router and the evaluator proxy. After a short delay it performs simple HTTP health checks.

## Configuration

Routing, hardware capabilities and model inventory are defined in `router/router.yaml`. Adjust endpoints, keywords, inventory or policy settings there to suit your hardware and models.

## Validation

To verify a running stack without making changes:

```bash
python garvis_validate.py
```

This generates a JSON report under `logs/` with port status, HTTP reachability and router configuration consistency.

## Load testing

The `tests/` folder contains simple scripts for exercising the stack. For example:

```bash
bash tests/Loadtest.sh
```

Edit the target URI and payloads to match your deployment.

## Development

For contributions and local development, install the tooling and hooks:

```bash
scripts/install_dev_dependencies.sh
pre-commit install
```

Run linters and tests with:

```bash
pre-commit run --all-files
pytest
```

## Monitoring

`scripts/watchdog.sh` performs periodic health checks on the router and evaluator
ports and restarts the stack via `start_all.sh` if either service stops
responding.

## License

This repository does not yet include an explicit license. If you intend to use it, please consult the project maintainers.
