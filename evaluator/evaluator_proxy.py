import os
import datetime
import logging
from pathlib import Path

import yaml
import requests
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

# read router config (default relative to repository root)
CFG_PATH = os.environ.get(
    "ROUTER_CONFIG",
    str(Path(__file__).resolve().parents[1] / "router" / "router.yaml"),
)
with open(CFG_PATH, "r", encoding="utf-8") as f:
    CFG = yaml.safe_load(f)

PROXY_CFG = CFG.get("evaluator_proxy", {})
BIND_HOST = PROXY_CFG.get("bind_host", "127.0.0.1")
DEFAULT_BIND_PORT = int(PROXY_CFG.get("bind_port", 11437))
ROUTER_BASE = PROXY_CFG.get("router_url", "http://127.0.0.1:28100")
ROUTER_EVAL = f"{ROUTER_BASE}/evaluate"
LOG_FILE = PROXY_CFG.get(
    "log_file", str(Path(__file__).with_name("evaluator_proxy.log"))
)

ENDPOINTS = CFG["endpoints"]  # mapping of alias to URL
INVENTORY = CFG.get("inventory", {})  # includes real_model mapping

# ensure log directory exists
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)

app = FastAPI()


@app.get("/api/tags")
async def tags():
    # Return alias-based catalogue
    items = []
    for alias, meta in INVENTORY.items():
        pm = meta.get("params", {})
        tiers = (
            [t.get("tier") for t in pm.get("tiers", [])]
            if pm.get("tiers")
            else ["default"]
        )
        items.append(
            {
                "name": alias,
                "model": alias,
                "modified_at": datetime.datetime.utcnow().isoformat() + "Z",
                "size": 0,
                "digest": "alias",
                "details": {
                    "tiers": tiers,
                    "strengths": pm.get("strengths", []),
                    "ctx_tokens": pm.get("ctx_tokens", 4096),
                },
            }
        )
    return {"models": items}


@app.post("/api/generate")
async def generate(request: Request):
    body = await request.json()
    # 1) ask router to decide
    try:
        router_resp = requests.post(ROUTER_EVAL, json=body, timeout=60)
        router_resp.raise_for_status()
        ev = router_resp.json().get("evaluator", {})
    except Exception as e:
        return JSONResponse(
            status_code=500, content={"error": f"router/evaluate failed: {e}"}
        )

    decision = ev.get("decision", {})
    reason = ev.get("reason", "")
    est_lat = ev.get("est_latency_s", None)

    alias_model = decision.get("model")
    endpoint_key = decision.get("endpoint")
    real_model = decision.get("real_model")

    if not alias_model or not endpoint_key or endpoint_key not in ENDPOINTS:
        return JSONResponse(
            status_code=500, content={"error": f"invalid decision from evaluator: {ev}"}
        )

    # derive real model name from decision or inventory
    if not real_model:
        inv_entry = INVENTORY.get(alias_model, {})
        params = inv_entry.get("params", {})
        real_model = params.get("real_model", alias_model)

    # log decision
    snippet = (body.get("prompt", "") or "")[:80].replace("\n", " ")
    logging.info(
        f"DECISION model={alias_model} real_model={real_model} "
        f"endpoint={endpoint_key} reason='{reason}' "
        f"est={est_lat}s prompt='{snippet}…'"
    )

    # call upstream Ollama /api/generate with real model
    try:
        upstream_url = f"{ENDPOINTS[endpoint_key]}/api/generate"
        upstream_body = dict(body)
        upstream_body["model"] = real_model
        resp = requests.post(upstream_url, json=upstream_body, timeout=300)
        resp.raise_for_status()
        gen_data = resp.json()
    except Exception as e:
        return JSONResponse(
            status_code=500,
            content={"error": f"upstream generate failed on {endpoint_key}: {e}"},
        )

    # return pure model response
    return JSONResponse(content=gen_data)


if __name__ == "__main__":
    # support port override via environment variable (e.g. from start_all.sh)
    port = int(os.environ.get("PORT", DEFAULT_BIND_PORT))
    uvicorn.run(app, host=BIND_HOST, port=port)
