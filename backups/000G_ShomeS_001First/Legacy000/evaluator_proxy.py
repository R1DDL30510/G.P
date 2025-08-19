import os, json, datetime, logging
import yaml, requests
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn

# read router config
CFG_PATH = r"D:\GARVIS\router\router.yaml"
with open(CFG_PATH, "r", encoding="utf-8") as f:
    CFG = yaml.safe_load(f)

PROXY_CFG   = CFG.get("evaluator_proxy", {})
BIND_HOST   = PROXY_CFG.get("bind_host", "127.0.0.1")
BIND_PORT   = int(PROXY_CFG.get("bind_port", 11437))
ROUTER_BASE = PROXY_CFG.get("router_url", "http://127.0.0.1:28100")
ROUTER_EVAL = f"{ROUTER_BASE}/evaluate"
LOG_FILE    = PROXY_CFG.get("log_file", r"D:\GARVIS\evaluator\evaluator_proxy.log")

ENDPOINTS = CFG["endpoints"]      # mapping of alias to URL
INVENTORY = CFG.get("inventory", {})  # includes real_model mapping

# ensure log directory exists
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

app = FastAPI()

@app.get("/api/tags")
async def tags():
    return {
        "models": [{
            "name": "gar-evaluator:latest",
            "model": "gar-evaluator:latest",
            "modified_at": datetime.datetime.utcnow().isoformat() + "Z",
            "size": 0,
            "digest": "router-meta-hash",
            "details": {"parameter_size": "dynamic",
                        "quantization_level": "n/a"}
        }]
    }

@app.post("/api/generate")
async def generate(request: Request):
    body = await request.json()

    # 1) ask router to decide
    try:
        router_resp = requests.post(ROUTER_EVAL, json=body, timeout=60)
        router_resp.raise_for_status()
        ev = router_resp.json().get("evaluator", {})
    except Exception as e:
        return JSONResponse(status_code=500,
                            content={"error": f"router/evaluate failed: {e}"})

    decision = ev.get("decision", {})
    reason   = ev.get("reason", "")
    est_lat  = ev.get("est_latency_s", None)

    alias_model  = decision.get("model")
    endpoint_key = decision.get("endpoint")
    if not alias_model or not endpoint_key or endpoint_key not in ENDPOINTS:
        return JSONResponse(status_code=500,
                            content={"error": f"invalid decision from evaluator: {ev}"})

    # 2) derive real model name from inventory
    real_model = alias_model
    inv_entry = INVENTORY.get(alias_model, {})
    params = inv_entry.get("params", {})
    if params.get("real_model"):
        real_model = params["real_model"]

    # 3) log decision
    snippet = (body.get("prompt", "") or "")[:80].replace("\n", " ")
    logging.info(f"DECISION model={alias_model} real_model={real_model} "
                 f"endpoint={endpoint_key} reason='{reason}' "
                 f"est={est_lat}s prompt='{snippet}…'")

    # 4) call upstream Ollama /api/generate with real model
    try:
        upstream_url = f"{ENDPOINTS[endpoint_key]}/api/generate"
        upstream_body = dict(body)
        # set model to real_model if present
        upstream_body["model"] = real_model
        resp = requests.post(upstream_url, json=upstream_body, timeout=300)
        resp.raise_for_status()
        gen_data = resp.json()
    except Exception as e:
        return JSONResponse(status_code=500,
                            content={"error": f"upstream generate failed on {endpoint_key}: {e}"})

    # 5) return pure model response
    return JSONResponse(content=gen_data)

if __name__ == "__main__":
    uvicorn.run(app, host=BIND_HOST, port=BIND_PORT)
