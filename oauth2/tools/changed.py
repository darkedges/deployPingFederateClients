#!/usr/bin/env python3
"""Emit the application deployment matrix for a Git diff."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
APP_RE = re.compile(r"^oauth2/applications/oauth2_([a-z0-9][a-z0-9-]*)_([a-z0-9][a-z0-9-]*)\.yaml$")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: changed.py <base> <head>", file=sys.stderr)
        return 2
    base, head = sys.argv[1:]
    if set(base) == {"0"}:
        changed = [f"A\t{path.relative_to(ROOT).as_posix()}" for path in (ROOT / "oauth2/applications").glob("*.yaml")]
    else:
        output = subprocess.check_output(
            ["git", "diff", "--name-status", "--find-renames", base, head, "--", "oauth2"],
            cwd=ROOT,
            text=True,
        )
        changed = output.splitlines()
    deploy_all = any(
        line.split("\t")[-1].startswith(("oauth2/platform/", "oauth2/schemas/", "oauth2/tools/"))
        for line in changed
    )
    entries = {}
    if deploy_all:
        for path in sorted((ROOT / "oauth2/applications").glob("*.yaml")):
            relative = path.relative_to(ROOT).as_posix()
            entries[relative] = {"target": relative, "action": "upsert"}
    for line in changed:
        parts = line.split("\t")
        status = parts[0]
        old_path = parts[1] if len(parts) > 1 else ""
        new_path = parts[-1] if len(parts) > 1 else ""
        if status.startswith("D") or status.startswith("R"):
            match = APP_RE.fullmatch(old_path)
            if match:
                previous = subprocess.check_output(
                    ["git", "show", f"{base}:{old_path}"], cwd=ROOT, text=True
                )
                document = yaml.safe_load(previous)
                if document.get("lifecycle", {}).get("state") != "disabled":
                    raise SystemExit(f"{old_path} must be disabled before deletion or rename")
                target = f"deleted:{match.group(1)}:{match.group(2)}"
                entries[target] = {"target": target, "action": "delete"}
        if not status.startswith("D"):
            match = APP_RE.fullmatch(new_path)
            if match:
                entries[new_path] = {"target": new_path, "action": "upsert"}
    print(json.dumps(list(entries.values()), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
