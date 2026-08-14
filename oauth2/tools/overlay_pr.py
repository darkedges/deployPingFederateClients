#!/usr/bin/env python3
"""Overlay only declarative OAuth2 YAML from a PR onto trusted base code."""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = re.compile(r"^oauth2/(applications/oauth2_[a-z0-9-]+_[a-z0-9-]+\.yaml|platform/oauth2_platform\.yaml)$")


def api(path: str):
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={
            "Authorization": f"Bearer {os.environ['GH_APP_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> int:
    repository = os.environ["GITHUB_REPOSITORY"]
    number = os.environ["PR_NUMBER"]
    pull = api(f"/repos/{repository}/pulls/{number}")
    if pull["head"]["repo"]["full_name"] != repository:
        raise SystemExit("fork pull requests cannot receive privileged plans")
    environment = {"develop": "development", "staging": "staging", "production": "production"}.get(pull["base"]["ref"])
    if not environment:
        raise SystemExit("pull request does not target an environment branch")
    files = api(f"/repos/{repository}/pulls/{number}/files?per_page=100")
    if len(files) == 100:
        raise SystemExit("pull requests with 100 or more files are not eligible for privileged planning")
    targets = []
    platform_changed = False
    for changed in files:
        path = changed["filename"]
        if not ALLOWED.fullmatch(path):
            raise SystemExit(f"privileged planning rejects non-data path: {path}")
        target = ROOT / path
        if changed["status"] == "removed":
            previous = yaml.safe_load(target.read_text(encoding="utf-8"))
            if previous.get("lifecycle", {}).get("state") != "disabled":
                raise SystemExit(f"{path} must be disabled before deletion")
            match = re.fullmatch(r"oauth2/applications/oauth2_([a-z0-9-]+)_([a-z0-9-]+)\.yaml", path)
            if match:
                targets.append(f"deleted:{match.group(1)}:{match.group(2)}")
            target.unlink(missing_ok=True)
            continue
        content = api(f"/repos/{repository}/contents/{path}?ref={pull['head']['sha']}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(base64.b64decode(content["content"]))
        if path == "oauth2/platform/oauth2_platform.yaml":
            platform_changed = True
        else:
            targets.append(path)
    output = Path(os.environ["GITHUB_OUTPUT"])
    with output.open("a", encoding="utf-8") as handle:
        handle.write(f"environment={environment}\\n")
        handle.write(f"platform_changed={str(platform_changed).lower()}\\n")
        handle.write("targets=" + json.dumps(sorted(set(targets)), separators=(",", ":")) + "\\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
