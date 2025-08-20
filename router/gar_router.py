import argparse, json, socketserver, sys, time, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import yaml, requests

# parse CLI arg for config path (default to router.yaml next to this file)
parser = argparse.ArgumentParser()
default_cfg = Path(__file__).with_name("router.yaml")
parser.add_argument("--config", default=str(default_cfg))
args = parser.parse_args()

# load YAML configuration
with open(args.config, "r", encoding="utf-8") as f:
    CFG = yaml.safe_load(f)

MODE      = CFG["router"].get("mode", "heuristic")
BIND_HOST = CFG["router"].get("bind_host", "127.0.0.1")
BIND_PORT = int(CFG["router"].get("bind_port", 28100))
TIMEOUT_S = int(CFG["router"].get("request_timeout_s", 300))
LOG_PATH  = CFG["router"]["log_path"]

ENDPOINTS      = CFG["endpoints"]
MODEL_MAP      = CFG.get("model_map", {})
KEYWORDS       = {k: [kw.lower() for kw in v] for k, v in CFG.get("keywords", {}).items()}
DEFAULT_MODELS = CFG.get("default_models", {})

HARDWARE  = CFG.get("hardware", {})
INVENTORY = CFG.get("inventory", {})
POLICY    = CFG.get("policy", {})

os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)

def log_event(ev: dict):
    ev["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")

def pick_by_keywords(prompt: str) -> str:
    p = (prompt or "").lower()
    scores = {k: 0 for k in KEYWORDS.keys()}
    for target, kws in KEYWORDS.items():
        for kw in kws:
            if kw in p:
                scores[target] += 1
    return max(scores, key=lambda k: scores[k]) if any(scores.values()) else "gpu0"

def resolve_target(payload: dict):
    model  = payload.get("model")
    prompt = payload.get("prompt", "")

    alias = _normalize_alias(model)  # <— добавили
    if alias and alias in MODEL_MAP:
        key = MODEL_MAP[alias]
        return key, ENDPOINTS[key]

    key = pick_by_keywords(prompt)
    return key, ENDPOINTS[key]


def _normalize_alias(name: str | None) -> str | None:
    """Normalize model alias names by stripping ":latest" and lowering."""
    if not name:
        return None
    return name.lower().removesuffix(":latest")

def _post_json(url: str, body: dict) -> dict:
    r = requests.post(url, json=body, timeout=TIMEOUT_S)
    r.raise_for_status()
    return json.loads(r.content.decode("utf-8", errors="replace"))

def forward_generate(base_url: str, payload: dict, default_model: str | None) -> dict:
    """
    Try /api/generate first. If missing, fall back to /api/chat.
    Alias model names are mapped to real model names via the inventory.
    """
    chosen_model = payload.get("upstream_model") or payload.get("model") or default_model or ""
    # map alias to real model if present in inventory
    real_model = chosen_model
    if real_model and real_model in INVENTORY:
        real_model = INVENTORY[real_model]["params"].get("real_model", real_model)
    prompt = payload.get("prompt", "")

    # Primary: /api/generate
    gen_body = {"prompt": prompt, "stream": False}
    if real_model:
        gen_body["model"] = real_model
    try:
        return _post_json(f"{base_url}/api/generate", gen_body)
    except requests.HTTPError as e:
        if e.response is not None and e.response.status_code == 404:
            # fallback to /api/chat
            pass
        else:
            raise

    # Fallback: /api/chat
    chat_body = {
        "model": real_model or "",
        "messages": [{"role": "user", "content": prompt}],
        "stream": False
    }
    if not chat_body["model"]:
        chat_body.pop("model", None)
    return _post_json(f"{base_url}/api/chat", chat_body)

# evaluator functions (token estimation and hardware selection)
def estimate_tokens(text: str) -> int:
    return max(1, int(len(text or "") / 4))

def fits_context(prompt_tokens: int, ctx_tokens: int, margin: float) -> bool:
    return prompt_tokens * (1 + margin) < ctx_tokens

def est_latency_s(hw_key: str, out_tokens: int = 150) -> float:
    tok_s = HARDWARE.get(hw_key, {}).get("est_tok_s", 10)
    return round(out_tokens / max(1, tok_s), 2)

def evaluate_choice(prompt: str, hint_model: str | None = None) -> dict:
    ptoks  = estimate_tokens(prompt)
    margin = float(POLICY.get("min_ctx_margin", 0.2))

    candidates = []
    nm = _normalize_alias(hint_model)  # <— добавили
    if nm and nm in INVENTORY:
        meta = INVENTORY[nm]
        candidates.append((nm, meta["endpoint"], meta))
    else:
        for mkey, meta in INVENTORY.items():
            candidates.append((mkey, meta["endpoint"], meta))

    # apply context/vram constraints
    filtered = []
    for mkey, hw, meta in candidates:
        params = meta.get("params", {})
        ctx_ok  = fits_context(ptoks, params.get("ctx_tokens", 4096), margin)
        vram_ok = params.get("vram_req_gb", 0) <= HARDWARE.get(hw, {}).get("vram_gb", 0)
        if ctx_ok and vram_ok:
            filtered.append((mkey, hw, meta))

    if not filtered:
        if POLICY.get("allow_cpu", True) and "cpu" in ENDPOINTS:
            return {"decision": {"model": "gar-router:latest", "endpoint": "cpu"},
                    "reason": "No GPU candidate fits; fallback to CPU.",
                    "est_latency_s": est_latency_s("cpu"),
                    "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin}}
        if candidates:
            mkey, hw, meta = candidates[0]
            return {"decision": {"model": mkey, "endpoint": hw},
                    "reason": "No perfect fit; choosing first available.",
                    "est_latency_s": est_latency_s(hw),
                    "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin}}
        return {"decision": {"model": "gar-router:latest", "endpoint": "cpu"},
                "reason": "No candidates at all; defaulting to CPU.",
                "est_latency_s": est_latency_s("cpu"),
                "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin}}

    best = sorted(filtered, key=lambda t: est_latency_s(t[1]))[0]
    mkey, hw, meta = best
    return {"decision": {"model": mkey, "endpoint": hw},
            "reason": "Chosen by strengths/context and lowest est. latency.",
            "est_latency_s": est_latency_s(hw),
            "constraints": {"prompt_tokens": ptoks, "ctx_margin": margin}}

# HTTP handler
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw    = self.rfile.read(length)
            payload = json.loads(raw.decode("utf-8", errors="replace")) if raw else {}
            prompt  = payload.get("prompt", "")

            if self.path == "/evaluate":
                hint_model = payload.get("model")
                result = evaluate_choice(prompt, hint_model)
                data = json.dumps({"evaluator": result}, ensure_ascii=False).encode("utf-8")
                return self._send_json(200, data)

            if self.path == "/route_and_generate":
                hint_model = payload.get("model")
                ev = evaluate_choice(prompt, hint_model)
                target_key    = ev["decision"]["endpoint"]
                chosen_model  = ev["decision"]["model"]
                default_model = DEFAULT_MODELS.get(target_key)
                payload["upstream_model"] = chosen_model
                t0 = time.time()
                upstream = forward_generate(ENDPOINTS[target_key], payload, default_model)
                dt = round(time.time() - t0, 3)
                out = {
                    "evaluator": ev,
                    "router": {"mode": MODE, "target": target_key,
                               "endpoint": ENDPOINTS[target_key], "elapsed_s": dt},
                    "upstream_response": upstream
                }
                data = json.dumps(out, ensure_ascii=False).encode("utf-8")
                log_event({"event": "route", "target": target_key,
                           "endpoint": ENDPOINTS[target_key], "len_prompt": len(prompt),
                           "elapsed_s": dt})
                return self._send_json(200, data)

            if self.path == "/generate":
                target_key, target_url = resolve_target(payload)
                default_model = DEFAULT_MODELS.get(target_key)
                t0 = time.time()
                upstream = forward_generate(target_url, payload, default_model)
                dt = round(time.time() - t0, 3)
                out = {
                    "router": {"mode": MODE, "target": target_key,
                               "endpoint": target_url, "elapsed_s": dt},
                    "upstream_response": upstream
                }
                data = json.dumps(out, ensure_ascii=False).encode("utf-8")
                log_event({"event": "route", "target": target_key,
                           "endpoint": target_url, "len_prompt": len(prompt),
                           "elapsed_s": dt})
                return self._send_json(200, data)

            self.send_error(404, "Use POST /evaluate | /route_and_generate | /generate")
        except Exception as e:
            msg = {"error": str(e)}
            data = json.dumps(msg, ensure_ascii=False).encode("utf-8")
            self._send_json(500, data)

    def _send_json(self, status, data: bytes):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
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
