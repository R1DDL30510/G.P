"""
Minimal contract test for router/router.yaml.

Ensures presence and basic types of critical keys to catch accidental renames
or structural regressions early.
"""

from jsonschema import validate
import pytest


def _schema():
    return {
        "type": "object",
        "required": ["endpoints", "keywords", "model_map"],
        "properties": {
            "mode": {"type": "string"},
            "endpoints": {
                "type": "object",
                "minProperties": 1,
                "additionalProperties": {
                    "anyOf": [
                        {"type": "string"},
                        {
                            "type": "object",
                            "required": ["host", "port"],
                            "properties": {
                                "host": {"type": "string"},
                                "port": {"type": "integer"},
                                "hardware": {"type": "object"},
                                "tags": {"type": "array", "items": {"type": "string"}},
                            },
                        },
                    ]
                },
            },
            "keywords": {
                "type": "object",
                "additionalProperties": {"type": "array", "items": {"type": "string"}},
            },
            "model_map": {
                "type": "object",
                "additionalProperties": {"type": "string"},
            },
            "defaults": {"type": "object"},
            "inventory": {"type": "object"},
            "evaluator": {"type": "object"},
        },
        "additionalProperties": True,
    }


@pytest.mark.schema
def test_router_yaml_matches_min_schema(router_config):
    validate(instance=router_config, schema=_schema())
