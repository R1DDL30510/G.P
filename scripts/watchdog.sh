#!/usr/bin/env bash
# Simple watchdog to restart critical services if they exit.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG_DIR="$ROOT_DIR/logs"
SERVICES=("router:28100" "evaluator:11437")
mkdir -p "$LOG_DIR"

while true; do
  for svc in "${SERVICES[@]}"; do
    name=${svc%%:*}
    port=${svc##*:}
    if ! lsof -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$(date -Is) $name down; restarting" | tee -a "$LOG_DIR/watchdog.log"
      bash "$ROOT_DIR/start_all.sh"
      break
    fi
  done
  sleep 60
done
