"""
Heuristic routing contract tests.

Exercises a synthetic mini-config so tests don't depend on production YAML.
"""

import pytest


@pytest.mark.parametrize(
    "requested_model, prompt, expected_endpoint",
    [
        ("gar-chat", "hello world", "gpu0"),
        ("small-cpu", "quick reply", "cpu"),
        (None, "Please compute this integral quickly", "gpu0"),
        (None, "Just a tiny request", "cpu"),
    ],
)
def test_decision_rules(
    decider, mini_config, requested_model, prompt, expected_endpoint
):
    fn = decider
    try:
        result = fn(prompt, requested_model, mini_config)  # type: ignore[arg-type]
    except TypeError:
        payload = {"prompt": prompt, "model": requested_model, "config": mini_config}
        result = fn(payload)  # type: ignore[misc]

    if isinstance(result, dict):
        endpoint = result.get("endpoint") or result.get("target") or result.get("name")
    else:
        endpoint = str(result)

    assert endpoint == expected_endpoint
