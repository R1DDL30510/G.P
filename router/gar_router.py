import os, re, json, socket, urllib.request, urllib.error
from dataclasses import dataclass
from typing import Dict, Any
from http.server import BaseHTTPRequestHandler, HTTPServer

try:
    import yaml
    def _load_yaml(p):
        with open(p, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
except Exception:
    yaml = None
    def _load_yaml(p):
        with open(p, "r", encoding="utf-8") as f:
            return json.loads(f.read())

ROOT = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(ROOT, "router.yaml")

@dataclass
class Target:
    name: str
    url: str
    tags: list

class Router:
    def __init__(self, cfg: Dict[str, Any]):
        self.cfg = cfg
        self.targets: Dict[str, Target] = {
            k: Target(k, v["url"], v.get("tags", []))
            for k, v in cfg.get("targets", {}).items()
        }
        s = cfg.get("server", {})
        self.read_timeout = float(s.get("read_timeout_s", 120))
        self.connect_timeout = float(s.get("connect_timeout_s", 5))

    def choose_target(self, body: Dict[str, Any]) -> Target:
        alias = body.get("route") or body.get("model_alias")
        if alias:
            name = self.cfg.get("routing", {}).get("by_model_alias", {}).get(str(alias))
            if name and name in self.targets:
                return self.targets[name]
        prompt = ""
        if "prompt" in body:
            prompt = str(body["prompt"])
        elif isinstance(body.get("messages"), list):
            prompt = " ".join(str(m.get("content","")) for m in body["messages"])
        for pattern, name in self.cfg.get("routing", {}).get("by_keyword", {}).items():
            if re.search(pattern, prompt, flags=re.I) and name in self.targets:
                return self.targets[name]
        name = self.cfg.get("routing", {}).get("default")
        if name in self.targets:
            return self.targets[name]
        return next(iter(self.targets.values()))

    def forward_json(self, target: Target, path: str, body: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{target.url}{path}"
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"})
        socket.setdefaulttimeout(self.connect_timeout)
        try:
            with urllib.request.urlopen(req, timeout=self.read_timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"upstream {target.name} {e.code}: {msg}") from e
        except Exception as e:
            raise RuntimeError(f"forward error to {target.name}: {e}") from e

def load_config() -> Dict[str, Any]:
    if not os.path.exists(CFG_PATH):
        raise FileNotFoundError(f"missing config {CFG_PATH}")
    return _load_yaml(CFG_PATH)

ROUTER = Router(load_config())

class H(BaseHTTPRequestHandler):
    def _json(self):
        try:
            length = int(self.headers.get("Content-Length","0"))
        except Exception:
            length = 0
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _send(self, code: int, obj: Dict[str, Any]):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        if self.path == "/generate":
            body = self._json()
            tgt = ROUTER.choose_target(body)
            try:
                out = ROUTER.forward_json(tgt, "/api/generate", body)
                out["_meta"] = {"target": tgt.name, "url": tgt.url}
                self._send(200, out)
            except Exception as e:
                self._send(502, {"error": str(e)})
            return
        if self.path == "/chain":
            body = self._json()
            first  = body.get("first")  or {"model_alias":"fast"}
            second = body.get("second") or {"model_alias":"balanced"}
            prompt = body.get("prompt") or ""
            t1 = ROUTER.choose_target({**first, "prompt": prompt})
            r1 = ROUTER.forward_json(t1, "/api/generate", {**first, "prompt": prompt})
            mid = r1.get("response") or r1.get("message","")
            t2 = ROUTER.choose_target({**second, "prompt": mid})
            r2 = ROUTER.forward_json(t2, "/api/generate", {**second, "prompt": mid})
            r2["_meta"] = {"first_target": t1.name, "second_target": t2.name}
            self._send(200, r2); return
        self._send(404, {"error":"unknown endpoint"})

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "targets": list(ROUTER.targets)})
            return
        self._send(404, {"error":"not found"})

def main():
    s = ROUTER.cfg.get("server", {})
    host = s.get("host","0.0.0.0")
    port = int(s.get("port", 28100))
    httpd = HTTPServer((host, port), H)
    print(f"[router] listening on http://{host}:{port}")
    httpd.serve_forever()

if __name__ == "__main__":
    main()
