#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python -m pip install --upgrade pip
pip install -r "$ROOT_DIR/requirements-dev.txt"
