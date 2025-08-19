# GARVIS v001 Overview

GARVIS is a local multi‑model routing stack built around separate Ollama instances for GPU0, GPU1 and CPU. Its goal is to provide a single “model” endpoint that automatically chooses the best model and hardware based on a prompt’s content and context.

### Architecture
- **Ollama Instances**: Three separate Ollama services run on different ports (`11434` for GPU0, `11435` for GPU1, `11436` for CPU). Each instance has its own model store, which keeps memory usage isolated.
- **Router** (`v001_gar_router.py`): Listens on `28100`. It inspects incoming prompts, matches them against keyword heuristics or explicit model aliases, and forwards to the correct Ollama instance. It also logs routing decisions.
- **Evaluator** (`v001_evaluator_proxy.py`): Presents an Ollama‑style `/api/generate` endpoint on `11437`. It calls the router’s `/evaluate` route to select a model, logs the decision, maps the alias model name to the underlying Ollama “real” model (from the inventory), then invokes that model’s `/api/generate`.
- **Configuration** (`v001_router.yaml`): Defines endpoints, default models, model aliases, keywords for heuristics, hardware specs, inventory metadata (including real model names), evaluator policy, and evaluator proxy settings.
- **Startup Script** (`v001_start_all.ps1`): Disables any old Ollama services, starts each Ollama instance with appropriate environment variables (e.g., `CUDA_VISIBLE_DEVICES` or `OLLAMA_NO_GPU`), launches the Python router and evaluator proxy, then verifies that all services respond correctly.

### Alias and Real Model
Clients send alias model names (e.g., `gar-chat:latest`). The router and evaluator use the inventory to map the alias to the real Ollama model name (e.g., `llama3.1:8b-instruct`). This keeps client prompts decoupled from underlying model names and allows transparent swapping of real models.

### Usage
- Send a POST to `http://127.0.0.1:11437/api/generate` with `{ "prompt": "...", "stream": false }` to use the evaluator proxy.
- To inspect the router’s decision without generating a response, POST to `http://127.0.0.1:28100/evaluate`.
- All prompts without an explicit `model` field will be routed based on keywords; if none match, `gpu0` (gar‑chat) is used.
- Logs are stored at `D:/GARVIS/router/logs/router.jsonl` and `D:/GARVIS/evaluator/evaluator_proxy.log` for auditing decisions and evaluating performance.

