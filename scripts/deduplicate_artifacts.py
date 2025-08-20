import argparse
import json
from pathlib import Path


def load_artifacts(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_artifacts(path: Path, artifacts):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(artifacts, f, indent=2, sort_keys=True)


def deduplicate(artifacts):
    unique = {}
    for art in artifacts:
        unique[art["id"]] = art
    return list(unique.values())


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Remove duplicate artifacts from a repository JSON file"
    )
    parser.add_argument("repository", type=Path, help="Path to artifacts JSON file")
    args = parser.parse_args()

    artifacts = load_artifacts(args.repository)
    deduped = deduplicate(artifacts)
    removed = len(artifacts) - len(deduped)
    save_artifacts(args.repository, deduped)
    print(f"Removed {removed} duplicates. {len(deduped)} artifacts remain.")


if __name__ == "__main__":
    main()
