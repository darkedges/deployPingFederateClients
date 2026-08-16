#!/usr/bin/env python3
"""Emit infrastructure targets affected by a Git diff."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

import yaml

ROOT = Path(__file__).resolve().parents[2]
APP_RE = re.compile(r"^oauth2/applications/oauth2_([a-z0-9][a-z0-9-]*)_([a-z0-9][a-z0-9-]*)\.yaml$")
PLATFORM_TERRAFORM_PREFIXES = (
    "terraform/modules/oauth2-platform/",
    "terraform/stacks/platform/",
)
APPLICATION_TERRAFORM_PREFIXES = (
    "terraform/modules/oauth2-application/",
    "terraform/stacks/application/",
    "terraform/stacks/application-destroy/",
)


def all_applications(root: Path) -> list[dict[str, str]]:
    return [
        {"target": path.relative_to(root).as_posix(), "action": "upsert"}
        for path in sorted((root / "oauth2/applications").glob("*.yaml"))
    ]


def classify_changes(
    changed: list[str],
    base: str,
    *,
    root: Path = ROOT,
    load_previous: Callable[[str], str] | None = None,
    initial: bool = False,
) -> dict[str, object]:
    """Classify a name-status diff into platform and per-client targets."""
    paths = [path for line in changed for path in line.split("\t")[1:]]
    platform_changed = (
        initial
        or "oauth2/platform/oauth2_platform.yaml" in paths
        or any(path.endswith(".tf") and path.startswith(PLATFORM_TERRAFORM_PREFIXES) for path in paths)
    )
    deploy_all_applications = initial or any(
        path.endswith(".tf") and path.startswith(APPLICATION_TERRAFORM_PREFIXES) for path in paths
    )

    entries = {}
    if deploy_all_applications:
        entries = {entry["target"]: entry for entry in all_applications(root)}

    if load_previous is None:
        load_previous = lambda path: subprocess.check_output(
            ["git", "show", f"{base}:{path}"], cwd=root, text=True
        )

    for line in changed:
        parts = line.split("\t")
        status = parts[0]
        old_path = parts[1] if len(parts) > 1 else ""
        new_path = parts[-1] if len(parts) > 1 else ""

        if status.startswith(("D", "R")):
            match = APP_RE.fullmatch(old_path)
            if match:
                document = yaml.safe_load(load_previous(old_path))
                if document.get("lifecycle", {}).get("state") != "disabled":
                    raise SystemExit(f"{old_path} must be disabled before deletion or rename")
                target = f"deleted:{match.group(1)}:{match.group(2)}"
                entries[target] = {"target": target, "action": "delete"}

        if not status.startswith("D"):
            match = APP_RE.fullmatch(new_path)
            if match:
                entries[new_path] = {"target": new_path, "action": "upsert"}

    return {
        "applications": sorted(entries.values(), key=lambda entry: entry["target"]),
        "platform_changed": platform_changed,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: changed.py <base> <head>", file=sys.stderr)
        return 2
    base, head = sys.argv[1:]
    initial = bool(base) and set(base) == {"0"}
    if initial:
        changed = []
    else:
        output = subprocess.check_output(
            ["git", "diff", "--name-status", "--find-renames", base, head, "--", "oauth2", "terraform"],
            cwd=ROOT,
            text=True,
        )
        changed = output.splitlines()
    print(json.dumps(classify_changes(changed, base, initial=initial), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
