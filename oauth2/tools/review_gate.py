#!/usr/bin/env python3
"""Require current-commit approval from application and identity owners."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
FILE_RE = re.compile(r"^oauth2/applications/oauth2_([a-z0-9][a-z0-9-]*)_([a-z0-9][a-z0-9-]*)\.yaml$")


def api(path: str):
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={
            "Authorization": f"Bearer {os.environ['GH_APP_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and "/teams/" in path:
            raise SystemExit(
                "GitHub App cannot read the configured team. Verify the team slug, "
                "installation access, and organization Members: read permission."
            ) from None
        raise SystemExit(f"GitHub API request failed for {path}: HTTP {error.code}") from None


def team_members(team: str) -> set[str]:
    organisation, slug = team.split("/", 1)
    members = set()
    page = 1
    while True:
        values = api(f"/orgs/{organisation}/teams/{slug}/members?per_page=100&page={page}")
        members.update(value["login"].lower() for value in values)
        if len(values) < 100:
            return members
        page += 1


def approval_error(
    approved: set[str],
    identity_team: str,
    identity_members: set[str],
    app_teams: dict[str, set[str]],
) -> str | None:
    """Return the approval-policy failure, allowing one shared-team approval."""
    identity_approvers = approved & identity_members
    if not identity_approvers:
        return "A current-commit identity-platform approval is required"
    for team, members in app_teams.items():
        app_approvers = approved & members
        if not app_approvers:
            return f"A current-commit approval from {team} is required"
        if team.lower() != identity_team.lower() and not any(
            app != identity for app in app_approvers for identity in identity_approvers
        ):
            return f"{team} and identity-platform approvals must come from different people"
    return None


def main() -> int:
    repository = os.environ["GITHUB_REPOSITORY"]
    number = os.environ["PR_NUMBER"]
    pull = api(f"/repos/{repository}/pulls/{number}")
    if pull["head"]["repo"]["full_name"] != repository:
        print("Fork pull requests cannot receive privileged approval", file=sys.stderr)
        return 1
    if pull.get("author_association", "") not in {"MEMBER", "OWNER", "COLLABORATOR"}:
        print("The pull request author is not a trusted member", file=sys.stderr)
        return 1
    reviews = api(f"/repos/{repository}/pulls/{number}/reviews?per_page=100")
    author = pull["user"]["login"].lower()
    approved = {
        review["user"]["login"].lower()
        for review in reviews
        if review["state"] == "APPROVED"
        and review.get("commit_id") == pull["head"]["sha"]
        and review["user"]["login"].lower() != author
    }
    ownership = yaml.safe_load((ROOT / "oauth2" / "ownership.yaml").read_text(encoding="utf-8"))
    required_app_teams = set()
    page = 1
    while True:
        files = api(f"/repos/{repository}/pulls/{number}/files?per_page=100&page={page}")
        for changed in files:
            match = FILE_RE.fullmatch(changed["filename"])
            if match:
                key = f"{match.group(1)}/{match.group(2)}"
                if key not in ownership["applications"]:
                    print(f"No trusted owner for {key}", file=sys.stderr)
                    return 1
                required_app_teams.add(ownership["applications"][key]["githubTeam"])
        if len(files) < 100:
            break
        page += 1
    identity_team = ownership["identityPlatformTeam"]
    error = approval_error(
        approved,
        identity_team,
        team_members(identity_team),
        {team: team_members(team) for team in required_app_teams},
    )
    if error:
        print(error, file=sys.stderr)
        return 1
    print("Required team approvals are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
