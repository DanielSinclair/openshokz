#!/usr/bin/env python3
"""Generate site/analytics.js from site/analytics.js.in and site/.env."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / "site" / ".env"
TEMPLATE = ROOT / "site" / "analytics.js.in"
OUTPUT = ROOT / "site" / "analytics.js"


def load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key, value)


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"error: {name} is required (set in site/.env or the environment)", file=sys.stderr)
        sys.exit(1)
    return value


def main() -> None:
    load_dotenv(ENV_FILE)

    replacements = {
        "__PUBLIC_POSTHOG_PROJECT_TOKEN__": require_env("PUBLIC_POSTHOG_PROJECT_TOKEN"),
        "__PUBLIC_POSTHOG_API_HOST__": os.environ.get(
            "PUBLIC_POSTHOG_API_HOST", "https://us.i.posthog.com"
        ),
        "__PUBLIC_POSTHOG_PROJECT__": require_env("PUBLIC_POSTHOG_PROJECT"),
    }

    template = TEMPLATE.read_text(encoding="utf-8")
    for key, value in replacements.items():
        template = template.replace(key, json.dumps(value))

    OUTPUT.write_text(template, encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
