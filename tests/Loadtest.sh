#!/usr/bin/env bash
set -euo pipefail

URI="http://127.0.0.1:18100/api/generate"

declare -A payloads
payloads["gar-chat"]='{"model":"gar-chat","prompt":"Erkläre kurz den Unterschied zwischen Hund und Katze.","stream":false}'
payloads["gar-reason"]='{"model":"gar-reason","prompt":"Analysiere die Vor- und Nachteile von erneuerbaren Energien.","stream":false}'
payloads["gar-router"]='{"model":"gar-router","prompt":"route: soll diese Anfrage eher coding oder reasoning sein?","stream":false}'

invoke_loadtest() {
  local body="$1" model="$2" target="$3"
  local url="$URI"
  if [[ -n "$target" ]]; then
    url="$URI?target=$target"
  fi
  local start
  start=$(date +%s%3N)
  local resp
  resp=$(curl -s -X POST -H "Content-Type: application/json" "$url" -d "$body")
  local end
  end=$(date +%s%3N)
  local elapsed=$((end-start))
  local upstream
  upstream=$(echo "$resp" | python -c 'import sys,json; data=json.load(sys.stdin);print(data.get("model") or data.get("upstream_response",{}).get("model","?"))')
  echo "[$model] $upstream -> ${elapsed} ms"
}

pids=()
for model in "${!payloads[@]}"; do
for _ in {1..10}; do
    body=${payloads[$model]}
    case $model in
      gar-chat) target="gpu0" ;;
      gar-reason) target="gpu1" ;;
      gar-router) target="cpu" ;;
    esac
    invoke_loadtest "$body" "$model" "$target" &
    pids+=("$!")
  done
done

for pid in "${pids[@]}"; do
  wait "$pid"
done
