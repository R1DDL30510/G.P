#!/usr/bin/env bash
set -euo pipefail

# Default ports
GPU0_PORT=${GPU0_PORT:-11434}
GPU1_PORT=${GPU1_PORT:-11435}
CPU_PORT=${CPU_PORT:-11436}
ROUTER_PORT=${ROUTER_PORT:-28100}
EVAL_PORT=${EVAL_PORT:-11437}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR" "$ROOT_DIR/OllamaGPU0" "$ROOT_DIR/OllamaGPU1" "$ROOT_DIR/OllamaCPU"

# Kill processes on occupied ports
for port in $GPU0_PORT $GPU1_PORT $CPU_PORT $ROUTER_PORT $EVAL_PORT; do
  if lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    lsof -iTCP:$port -sTCP:LISTEN -t | xargs -r kill -9
  fi
done

# Start Ollama instances
OLLAMA_BIN=${OLLAMA_BIN:-$(command -v ollama)}

nohup env OLLAMA_HOST="127.0.0.1:$GPU0_PORT" \
          CUDA_VISIBLE_DEVICES=0 \
          OLLAMA_MODELS="$ROOT_DIR/OllamaGPU0" \
          "$OLLAMA_BIN" serve >"$LOG_DIR/gpu0.log" 2>&1 &

nohup env OLLAMA_HOST="127.0.0.1:$GPU1_PORT" \
          CUDA_VISIBLE_DEVICES=1 \
          OLLAMA_MODELS="$ROOT_DIR/OllamaGPU1" \
          "$OLLAMA_BIN" serve >"$LOG_DIR/gpu1.log" 2>&1 &

nohup env OLLAMA_HOST="127.0.0.1:$CPU_PORT" \
          OLLAMA_NO_GPU=1 \
          OLLAMA_MODELS="$ROOT_DIR/OllamaCPU" \
          "$OLLAMA_BIN" serve >"$LOG_DIR/cpu.log" 2>&1 &

# Generate router config based on detected hardware
python "$ROOT_DIR/scripts/generate_router_config.py" \
       "$ROOT_DIR/router/router.yaml" \
       "$ROOT_DIR/router/router.generated.yaml"

# Start router with generated config
nohup python "$ROOT_DIR/router/gar_router.py" --config "$ROOT_DIR/router/router.generated.yaml" \
      >"$LOG_DIR/router.log" 2>&1 &

# Start evaluator proxy
nohup PORT=$EVAL_PORT python "$ROOT_DIR/evaluator/evaluator_proxy.py" \
      >"$LOG_DIR/evaluator.log" 2>&1 &

# Health check
sleep 6
function check() {
  local name=$1 url=$2
  if curl -sf "$url" >/dev/null; then
    echo "$name: OK"
  else
    echo "$name: FAIL"
  fi
}
check gpu0 "http://127.0.0.1:$GPU0_PORT/api/tags"
check gpu1 "http://127.0.0.1:$GPU1_PORT/api/tags"
check cpu  "http://127.0.0.1:$CPU_PORT/api/tags"
check router "http://127.0.0.1:$ROUTER_PORT/evaluate"
check evaluator "http://127.0.0.1:$EVAL_PORT/api/tags"
