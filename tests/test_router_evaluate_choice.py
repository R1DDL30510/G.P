def test_cpu_fallback_when_no_candidate(router_module, monkeypatch):
    gr = router_module
    monkeypatch.setattr(gr, "ENDPOINTS", {"cpu": "http://localhost"})
    monkeypatch.setattr(gr, "HARDWARE", {"cpu": {}})
    monkeypatch.setattr(
        gr,
        "INVENTORY",
        {"big": {"endpoint": "gpu0", "params": {"ctx_tokens": 10, "vram_req_gb": 40}}},
    )
    monkeypatch.setattr(gr, "POLICY", {"allow_cpu": True, "min_ctx_margin": 0.0})

    res = gr.evaluate_choice("x" * 1000)
    assert res["decision"]["endpoint"] == "cpu"
    assert "No GPU candidate fits" in res["reason"]


def test_hint_model_normalization(router_module, monkeypatch):
    gr = router_module
    monkeypatch.setattr(gr, "ENDPOINTS", {"gpu0": "http://localhost"})
    monkeypatch.setattr(gr, "HARDWARE", {"gpu0": {"vram_gb": 24}})
    monkeypatch.setattr(
        gr, "INVENTORY", {"gar-router": {"endpoint": "gpu0", "params": {}}}
    )
    monkeypatch.setattr(gr, "POLICY", {"min_ctx_margin": 0.0})

    res = gr.evaluate_choice("", hint_model="GAR-ROUTER:latest")
    assert res["decision"]["endpoint"] == "gpu0"
