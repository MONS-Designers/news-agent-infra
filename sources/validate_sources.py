#!/usr/bin/env python3
"""Validate a NewsAgent default RSS source list YAML file."""

import argparse
import sys
from pathlib import Path
from urllib.parse import urlsplit

import yaml

REQUIRED_FIELDS = ("name", "url", "category", "language")
ALLOWED_CATEGORIES = {"tech", "world_news", "science"}
DEFAULT_PATH = Path(__file__).resolve().parent / "default_sources.yaml"


def entry_label(entry, index):
    name = entry.get("name") if isinstance(entry, dict) else None
    return f"entry {index} ({name!r})" if name else f"entry {index}"


def validate(data):
    errors = []

    if not isinstance(data, dict) or not isinstance(data.get("sources"), list):
        return ["top-level YAML must be a mapping with a 'sources' list"]

    entries = data["sources"]
    if not entries:
        return ["'sources' list must contain at least one entry"]

    seen_names = {}
    seen_urls = {}

    for index, entry in enumerate(entries):
        label = entry_label(entry, index)

        if not isinstance(entry, dict):
            errors.append(f"{label}: expected a mapping, got {type(entry).__name__}")
            continue

        for field in REQUIRED_FIELDS:
            value = entry.get(field)
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{label}: missing or empty required field '{field}'")

        url = entry.get("url")
        if isinstance(url, str) and url.strip():
            parsed = urlsplit(url)
            if parsed.scheme not in ("http", "https") or not parsed.netloc:
                errors.append(f"{label}: invalid url '{url}' (needs http/https scheme and host)")

        category = entry.get("category")
        if isinstance(category, str) and category.strip() and category.strip() not in ALLOWED_CATEGORIES:
            allowed = ", ".join(sorted(ALLOWED_CATEGORIES))
            errors.append(f"{label}: unknown category '{category}' (allowed: {allowed})")

        name = entry.get("name")
        if isinstance(name, str) and name.strip():
            key = name.strip()
            if key in seen_names:
                errors.append(f"{label}: duplicate name '{name}' (also used by entry {seen_names[key]})")
            else:
                seen_names[key] = index

        if isinstance(url, str) and url.strip():
            key = url.strip()
            if key in seen_urls:
                errors.append(f"{label}: duplicate url '{url}' (also used by entry {seen_urls[key]})")
            else:
                seen_urls[key] = index

    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        default=str(DEFAULT_PATH),
        help="Path to the source list YAML file (default: sources/default_sources.yaml)",
    )
    args = parser.parse_args()

    path = Path(args.path)
    try:
        with path.open("r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError, UnicodeDecodeError) as exc:
        print(f"ERROR: could not read/parse {path}: {exc}", file=sys.stderr)
        sys.exit(1)

    errors = validate(data)
    if errors:
        print(f"FAILED: {len(errors)} error(s) in {path}", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    count = len(data["sources"])
    print(f"OK: {count} sources validated")
    sys.exit(0)


if __name__ == "__main__":
    main()
