#!/usr/bin/env bash
set -euo pipefail

# Base ports
GPU_PORT_BASE=${GPU_PORT_BASE:-11434}
ROUTER_PORT=${ROUTER_PORT:-28100}
EVAL_PORT=${EVAL_PORT:-11437}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"

# Detect GPUs and prepare directories
GPU_INFO=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null || true)
readarray -t GPU_INDICES <<<"$GPU_INFO"
declare -A GPU_PORTS
for idx in "${GPU_INDICES[@]}"; do
  [[ "$idx" =~ ^[0-9]+$ ]] || continue
  port=$((GPU_PORT_BASE + idx))
  GPU_PORTS[$idx]=$port
  mkdir -p "$ROOT_DIR/OllamaGPU$idx"
done

# CPU directory for fallback
CPU_PORT=${CPU_PORT:-$((GPU_PORT_BASE + ${#GPU_PORTS[@]}))}
mkdir -p "$ROOT_DIR/OllamaCPU"

# Kill processes on occupied ports
ports=()
for port in "${GPU_PORTS[@]}"; do
  ports+=("$port")
done
ports+=("$CPU_PORT" "$ROUTER_PORT" "$EVAL_PORT")
for port in "${ports[@]}"; do
  if lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    lsof -iTCP:$port -sTCP:LISTEN -t | xargs -r kill -9
  fi
done

# Start Ollama instances
OLLAMA_BIN=${OLLAMA_BIN:-$(command -v ollama)}

for idx in "${!GPU_PORTS[@]}"; do
  port=${GPU_PORTS[$idx]}
  nohup env OLLAMA_HOST="127.0.0.1:$port" \
            CUDA_VISIBLE_DEVICES=$idx \
            OLLAMA_MODELS="$ROOT_DIR/OllamaGPU$idx" \
            "$OLLAMA_BIN" serve >"$LOG_DIR/gpu$idx.log" 2>&1 &
done

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
for idx in "${!GPU_PORTS[@]}"; do
  check "gpu$idx" "http://127.0.0.1:${GPU_PORTS[$idx]}/api/tags"
done
check cpu  "http://127.0.0.1:$CPU_PORT/api/tags"
check router "http://127.0.0.1:$ROUTER_PORT/evaluate"
check evaluator "http://127.0.0.1:$EVAL_PORT/api/tags"
