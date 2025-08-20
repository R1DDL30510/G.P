import argparse
import json
import os
from pathlib import Path

import jsonschema


def expand_env_variables(obj):
    if isinstance(obj, dict):
        return {k: expand_env_variables(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [expand_env_variables(v) for v in obj]
    if isinstance(obj, str):
        return os.path.expandvars(obj)
    return obj


def load_json(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate a configuration file against the JSON schema"
    )
    parser.add_argument("config", type=Path, help="Path to configuration JSON file")
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "config" / "schema.json",
        help="Path to configuration schema",
    )
    args = parser.parse_args()

    config = expand_env_variables(load_json(args.config))
    schema = load_json(args.schema)
    jsonschema.validate(instance=config, schema=schema)
    print(f"{args.config} is valid.")


if __name__ == "__main__":
    main()
