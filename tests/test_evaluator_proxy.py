from pathlib import Path
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evaluator.evaluator_proxy as ep


def test_tags_returns_inventory(monkeypatch):
    monkeypatch.setattr(
        ep,
        "INVENTORY",
        {
            "alias": {
                "params": {
                    "tiers": [{"tier": "fast"}],
                    "strengths": ["speed"],
                    "ctx_tokens": 1024,
                }
            }
        },
    )
    client = TestClient(ep.app)
    resp = client.get("/api/tags")
    assert resp.status_code == 200
    data = resp.json()
    assert any(m["name"] == "alias" for m in data["models"])


def test_generate_routes_and_proxies(monkeypatch):
    monkeypatch.setattr(ep, "ENDPOINTS", {"gpu0": "http://upstream"})
    monkeypatch.setattr(ep, "INVENTORY", {"alias": {"params": {"real_model": "real"}}})

    class Dummy:
        def __init__(self, payload):
            self._payload = payload

        def raise_for_status(self):
            return None

        def json(self):
            return self._payload

    def fake_post(url, json, timeout):
        if url.endswith("/evaluate"):
            return Dummy(
                {"evaluator": {"decision": {"model": "alias", "endpoint": "gpu0"}}}
            )
        assert url.endswith("/api/generate")
        assert json["model"] == "real"
        return Dummy({"ok": True})

    monkeypatch.setattr(ep.requests, "post", fake_post)
    client = TestClient(ep.app)
    resp = client.post("/api/generate", json={"prompt": "hi"})
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
