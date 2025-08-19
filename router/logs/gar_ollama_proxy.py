"""
GARVIS Router (final patched version)
-----------------------------------

This version of the GARVIS router consolidates previous fixes and improvements
into a single, stable script.  Key features:

* Reads configuration from `router.yaml`, including endpoints, inventory,
  hardware specs and routing policy.
* Normalises model aliases so that both `gar-chat` and `gar-chat:latest` map
  to the same inventory entry and endpoint.
* Performs heuristic routing when no model is explicitly provided, based on
  configured keywords.  Falls back to CPU when no GPU candidate fits and
  the policy allows it.
* Logs routing events to the configured log file.
* Forwards generation requests to upstream Ollama instances using only
  `/api/generate` (no deprecated `/api/chat` fallback).

This script is intended to replace the existing `gar_router.py`.  Ensure that
the `router.yaml` configuration file is up to date and that each alias in the
inventory corresponds to a real model available on the appropriate Ollama
instance.
"""

import argparse
import json
import socketserver
import sys
import time
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Dict, Tuple, Any

import yaml
import requests


# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------

def load_config(cfg_path: str) -> Dict[str, Any]:
    """Load YAML configuration from disk."""
    with open(cfg_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


# parse CLI arg for config path
parser = argparse.ArgumentParser(description="GARVIS router")
parser.add_argument("--config", default=r"D:\GARVIS\router\router.yaml",
                    help="Path to router.yaml configuration file")
args = parser.parse_args()

# Load configuration
CFG = load_config(args.config)

# Extract top‑level settings with sensible defaults
MODE      = CFG.get("router", {}).get("mode", "heuristic")
BIND_HOST = CFG.get("router", {}).get("bind_host", "127.0.0.1")
BIND_PORT = int(CFG.get("router", {}).get("bind_port", 28100))
TIMEOUT_S = int(CFG.get("router", {}).get("request_timeout_s", 300))
LOG_PATH  = CFG.get("router", {}).get("log_path", "router.log")

ENDPOINTS      = CFG.get("endpoints", {})
MODEL_MAP      = CFG.get("model_map", {})
KEYWORDS       = {k: [kw.lower() for kw in v] for k, v in CFG.get("keywords", {}).items()}
DEFAULT_MODELS = CFG.get("default_models", {})

HARDWARE  = CFG.get("hardware", {})
INVENTORY = CFG.get("inventory", {})
POLICY    = CFG.get("policy", {})

# Ensure log directory exists
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)


def log_event(ev: Dict[str, Any]) -> None:
    """Append a JSON log entry to the router log."""
    ev["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

def _normalize_alias(alias: str | None) -> str | None:
    """Strip a trailing ":latest" from a model alias, if present."""
    if not alias:
        return None
    if alias.endswith(":latest"):
        return alias[: -len(":latest")]
    return alias


def pick_by_keywords(prompt: str) -> str:
    """Pick an endpoint key based on keyword heuristics."""
    p = (prompt or "").lower()
    scores = {k: 0 for k in KEYWORDS.keys()}
    for target, kws in KEYWORDS.items():
        for kw in kws:
            if kw in p:
                scores[target] += 1
    return max(scores, key=lambda k: scores[k]) if any(scores.values()) else "gpu0"


def resolve_target(payload: Dict[str, Any]) -> Tuple[str, str]:
    """Decide which endpoint to use based on explicit model or keywords."""
    model = payload.get("model")
    prompt = payload.get("prompt", "")

    alias = _normalize_alias(model)
    if alias and alias in MODEL_MAP:
        key = MODEL_MAP[alias]
        return key, ENDPOINTS[key]

    # heuristic fallback
    key = pick_by_keywords(prompt)
    return key, ENDPOINTS[key]


def _post_json(url: str, body: Dict[str, Any]) -> Dict[str, Any]:
    r = requests.post(url, json=body, timeout=TIMEOUT_S)
    r.raise_for_status()
    return json.loads(r.content.decode("utf-8", errors="replace"))


def forward_generate(base_url: str, payload: Dict[str, Any], default_model: str | None) -> Dict[str, Any]:
    """
    Forward a /generate request to an upstream Ollama instance.  Only /api/generate
    is used; this function will not attempt a fallback to /api/chat.  If the
    requested model is an alias, it will be mapped to the real model via the
    inventory.
    """
    chosen_model = payload.get("upstream_model") or payload.get("model") or default_model or ""
    real_model = chosen_model
    if real_model and real_model in INVENTORY:
        real_model = INVENTORY[real_model]["params"].get("real_model", real_model)
    prompt = payload.get("prompt", "")

    gen_body = {"prompt": prompt, "stream": False}
    if real_model:
        gen_body["model"] = real_model
    return _post_json(f"{base_url}/api/generate", gen_body)


def estimate_tokens(text: str) -> int:
    return max(1, int(len(text or "") / 4))


def fits_context(prompt_tokens: int, ctx_tokens: int, margin: float) -> bool:
    return prompt_tokens * (1 + margin) < ctx_tokens


def est_latency_s(hw_key: str, out_tokens: int = 150) -> float:
    tok_s = HARDWARE.get(hw_key, {}).get("est_tok_s", 10)
    return round(out_tokens / max(1, tok_s), 2)


def evaluate_choice(prompt: str, hint_model: str | None = None) -> Dict[str, Any]:
    """
    Select the best model alias and endpoint based on the prompt, inventory and
    routing policy.  Returns a dict with a "decision" sub-dict containing
    alias and endpoint keys.  Does not pick tiers; instead we rely on the
    inventory's real_model and vram/ctx_tokens fields for constraints.
    """
    ptoks = estimate_tokens(prompt)
    margin = float(POLICY.get("min_ctx_margin", 0.2))

    candidates = []
    nm = _normalize_alias(hint_model)
    if nm and nm in INVENTORY:
        meta = INVENTORY[nm]
        candidates.append((nm, meta["endpoint"], meta))
    else:
        p = (prompt or "").lower()
        prefer: list[str] = []
        if any(k in p for k in POLICY.get("prefer_reasoning_for", [])):
            prefer.append("reasoning")
        if any(k in p for k in POLICY.get("prefer_coding_for", [])):
            prefer.append("coding")
        for mkey, meta in INVENTORY.items():
            strengths = meta.get("params", {}).get("strengths", [])
            if not prefer or any(s in strengths for s in prefer):
                candidates.append((mkey, meta["endpoint"], meta))

    # apply context/vram constraints
    filtered: list[Tuple[str, str, Dict[str, Any]]] = []
    for mkey, hw, meta in candidates:
        params = meta.get("params", {})
        ctx_ok = fits_context(ptoks, params.get("ctx_tokens", 4096), margin)
        vram_ok = params.get("vram_req_gb", 0) <= HARDWARE.get(hw, {}).get("vram_gb", 0)
        if ctx_ok and vram_ok:
            filtered.append((mkey, hw, meta))

    if not filtered:
        if POLICY.get("allow_cpu", True) and "cpu" in ENDPOINTS:
            return {
                "decision": {"model": "gar-router:latest", "endpoint": "cpu"},
                "reason": "No GPU candidate fits; fallback to CPU.",
                "est_latency_s": est_latency_s("cpu"),
                "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin},
            }
        if candidates:
            mkey, hw, meta = candidates[0]
            return {
                "decision": {"model": mkey, "endpoint": hw},
                "reason": "No perfect fit; choosing first available.",
                "est_latency_s": est_latency_s(hw),
                "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin},
            }
        return {
            "decision": {"model": "gar-router:latest", "endpoint": "cpu"},
            "reason": "No candidates at all; defaulting to CPU.",
            "est_latency_s": est_latency_s("cpu"),
            "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin},
        }

    # pick the candidate with the lowest estimated latency
    best = sorted(filtered, key=lambda t: est_latency_s(t[1]))[0]
    mkey, hw, meta = best
    return {
        "decision": {"model": mkey, "endpoint": hw},
        "reason": "Chosen by strengths/context and lowest est. latency.",
        "est_latency_s": est_latency_s(hw),
        "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin},
    }


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            payload: Dict[str, Any] = json.loads(raw.decode("utf-8", errors="replace")) if raw else {}
            prompt: str = payload.get("prompt", "")

            if self.path == "/evaluate":
                hint_model = payload.get("model")
                result = evaluate_choice(prompt, hint_model)
                data = json.dumps({"evaluator": result}, ensure_ascii=False).encode("utf-8")
                return self._send_json(200, data)

            if self.path == "/route_and_generate":
                hint_model = payload.get("model")
                ev = evaluate_choice(prompt, hint_model)
                target_key = ev["decision"]["endpoint"]
                chosen_model = ev["decision"]["model"]
                default_model = DEFAULT_MODELS.get(target_key)
                # propagate alias as upstream_model; real model mapping happens in forward_generate
                payload["upstream_model"] = chosen_model
                t0 = time.time()
                upstream = forward_generate(ENDPOINTS[target_key], payload, default_model)
                dt = round(time.time() - t0, 3)
                out = {
                    "evaluator": ev,
                    "router": {
                        "mode": MODE,
                        "target": target_key,
                        "endpoint": ENDPOINTS[target_key],
                        "elapsed_s": dt,
                    },
                    "upstream_response": upstream,
                }
                data = json.dumps(out, ensure_ascii=False).encode("utf-8")
                log_event(
                    {
                        "event": "route",
                        "target": target_key,
                        "endpoint": ENDPOINTS[target_key],
                        "len_prompt": len(prompt),
                        "elapsed_s": dt,
                    }
                )
                return self._send_json(200, data)

            if self.path == "/generate":
                target_key, target_url = resolve_target(payload)
                default_model = DEFAULT_MODELS.get(target_key)
                t0 = time.time()
                upstream = forward_generate(target_url, payload, default_model)
                dt = round(time.time() - t0, 3)
                out = {
                    "router": {
                        "mode": MODE,
                        "target": target_key,
                        "endpoint": target_url,
                        "elapsed_s": dt,
                    },
                    "upstream_response": upstream,
                }
                data = json.dumps(out, ensure_ascii=False).encode("utf-8")
                log_event(
                    {
                        "event": "route",
                        "target": target_key,
                        "endpoint": target_url,
                        "len_prompt": len(prompt),
                        "elapsed_s": dt,
                    }
                )
                return self._send_json(200, data)

            # Unknown path
            self.send_error(404, "Use POST /evaluate | /route_and_generate | /generate")
        except Exception as e:
            msg = {"error": str(e)}
            data = json.dumps(msg, ensure_ascii=False).encode("utf-8")
            return self._send_json(500, data)

    def _send_json(self, status: int, data: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args: Any) -> None:
        # suppress default logging
        return


class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    try:
        srv = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)
        print(f"[GAR-ROUTER] listening on http://{BIND_HOST}:{BIND_PORT}  mode={MODE}")
        srv.serve_forever()
    except PermissionError as e:
        print(f"[GAR-ROUTER] bind failed on {BIND_HOST}:{BIND_PORT} — run as Admin or change port. {e}")
        sys.exit(1)