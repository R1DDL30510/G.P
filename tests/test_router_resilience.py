"""
Basic resilience checks for the decision function.
"""

import pytest


@pytest.mark.parametrize(
    "requested_model, prompt",
    [
        (None, ""),
        ("unknown-alias", "text"),
        (None, None),
    ],
)
def test_graceful_fallbacks(decider, mini_config, requested_model, prompt):
    endpoint = None
    try:
        res = decider(prompt, requested_model, mini_config)  # type: ignore[arg-type]
        endpoint = res.get("endpoint") if isinstance(res, dict) else res
    except TypeError:
        payload = {"prompt": prompt, "model": requested_model, "config": mini_config}
        res = decider(payload)  # type: ignore[misc]
        endpoint = res.get("endpoint") if isinstance(res, dict) else res

    assert endpoint in (
        mini_config["defaults"]["fallback_endpoint"],
        "cpu",
        "gpu0",
    )
