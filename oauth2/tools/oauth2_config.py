#!/usr/bin/env python3
"""Validate, render, and scaffold declarative PingFederate OAuth2 configuration."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

import yaml
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
OAUTH_ROOT = ROOT / "oauth2"
APPLICATIONS = OAUTH_ROOT / "applications"
PLATFORM_FILE = OAUTH_ROOT / "platform" / "oauth2_platform.yaml"
OWNERSHIP_FILE = OAUTH_ROOT / "ownership.yaml"
CLIENT_SCHEMA = OAUTH_ROOT / "schemas" / "oauth2-client.schema.json"
PLATFORM_SCHEMA = OAUTH_ROOT / "schemas" / "oauth2-platform.schema.json"
FILENAME_RE = re.compile(r"^oauth2_([a-z0-9][a-z0-9-]{0,31})_([a-z0-9][a-z0-9-]{0,47})\.yaml$")
TEAM_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f"duplicate YAML key {key!r} at line {key_node.start_mark.line + 1}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def load_yaml(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return yaml.load(handle, Loader=UniqueKeyLoader)


def write_text_lf(path: Path, content: str) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)


def schema_errors(document, schema_path: Path) -> list[str]:
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = []
    for error in sorted(validator.iter_errors(document), key=lambda item: list(item.absolute_path)):
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        errors.append(f"{location}: {error.message}")
    return errors


def keyed(items: list[dict], label: str, errors: list[str]) -> dict[str, dict]:
    result = {}
    for item in items:
        key = item.get("key")
        if key in result:
            errors.append(f"platform: duplicate {label} key {key!r}")
        result[key] = item
    return result


def validate_platform(document: dict) -> tuple[list[str], dict[str, dict]]:
    errors = [f"platform: {error}" for error in schema_errors(document, PLATFORM_SCHEMA)]
    if errors:
        return errors, {}
    spec = document["spec"]
    catalog = {
        "accessTokenManagers": keyed(spec["accessTokenManagers"], "access token manager", errors),
        "accessTokenMappings": keyed(spec["accessTokenMappings"], "access token mapping", errors),
        "oidcPolicies": keyed(spec["oidcPolicies"], "OIDC policy", errors),
        "tokenExchangePolicies": keyed(spec["tokenExchangePolicies"], "token exchange policy", errors),
        "tokenExchangeGeneratorMappings": keyed(spec["tokenExchangeGeneratorMappings"], "token exchange generator mapping", errors),
    }
    processors = spec["externalReferences"]["tokenProcessors"]
    generators = spec["externalReferences"]["tokenGenerators"]
    for manager in spec["accessTokenManagers"]:
        if not manager["attributeContract"]:
            errors.append(f"platform: access token manager {manager['key']!r} requires at least one extended attribute")
    for mapping in spec["accessTokenMappings"]:
        if mapping["accessTokenManager"] not in catalog["accessTokenManagers"]:
            errors.append(f"platform: mapping {mapping['key']!r} references an unknown access token manager")
    for policy in spec["oidcPolicies"]:
        manager = catalog["accessTokenManagers"].get(policy["accessTokenManager"])
        if manager is None:
            errors.append(f"platform: OIDC policy {policy['key']!r} references an unknown access token manager")
            continue
        subject_fulfillment = policy["attributeContractFulfillment"].get("sub")
        if subject_fulfillment and subject_fulfillment["source"]["type"] == "TOKEN":
            token_attributes = {attribute["name"] for attribute in manager["attributeContract"]}
            if subject_fulfillment["value"] not in token_attributes:
                errors.append(
                    f"platform: OIDC policy {policy['key']!r} maps sub from unknown token attribute "
                    f"{subject_fulfillment['value']!r} on access token manager {manager['key']!r}"
                )
    for policy in spec["tokenExchangePolicies"]:
        for mapping in policy["processorMappings"]:
            if mapping["subjectTokenProcessor"] not in processors:
                errors.append(f"platform: policy {policy['key']!r} references an unknown subject token processor")
            actor = mapping.get("actorTokenProcessor")
            if actor and actor not in processors:
                errors.append(f"platform: policy {policy['key']!r} references an unknown actor token processor")
    for mapping in spec["tokenExchangeGeneratorMappings"]:
        if mapping["policy"] not in catalog["tokenExchangePolicies"]:
            errors.append(f"platform: generator mapping {mapping['key']!r} references an unknown policy")
        if mapping["tokenGenerator"] not in generators:
            errors.append(f"platform: generator mapping {mapping['key']!r} references an unknown generator")
    return errors, catalog


def effective_spec(spec: dict, environment: str) -> dict:
    result = copy.deepcopy(spec)
    overlays = result.pop("environments", {})
    result.update(copy.deepcopy(overlays.get(environment, {})))
    return result


def unsafe_uri(uri: str, profile: str) -> str | None:
    if "*" in uri:
        return "contains a forbidden wildcard"
    parsed = urlsplit(uri)
    if parsed.fragment:
        return "contains a forbidden fragment"
    if parsed.username or parsed.password:
        return "contains forbidden userinfo"
    if parsed.scheme == "https" and parsed.hostname:
        return None
    if profile == "native" and parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}:
        return None
    if profile == "native" and parsed.scheme not in {"", "http", "https", "javascript", "data", "file"}:
        return None
    return "must use HTTPS (except native loopback or private-use schemes)"


def validate_client(path: Path, document: dict, platform: dict, catalog: dict, ownership: dict) -> list[str]:
    prefix = path.as_posix()
    errors = [f"{prefix}: {error}" for error in schema_errors(document, CLIENT_SCHEMA)]
    match = FILENAME_RE.fullmatch(path.name)
    if not match:
        errors.append(f"{prefix}: filename must match oauth2_<organisation>_<application>.yaml")
        return errors
    if errors:
        return errors
    organisation, application = match.groups()
    metadata, spec = document["metadata"], document["spec"]
    if (metadata["organisation"], metadata["application"]) != (organisation, application):
        errors.append(f"{prefix}: filename and metadata do not match")
    owner_key = f"{organisation}/{application}"
    if owner_key not in ownership.get("applications", {}):
        errors.append(f"{prefix}: no trusted ownership entry exists for {owner_key!r}")

    profile = spec["profile"]
    method = spec.get("authentication", {"method": "none"})["method"]
    if profile in {"public_spa", "native"} and method != "none":
        errors.append(f"{prefix}: {profile} must use authentication.method=none")
    if profile in {"confidential_web", "service", "token_exchange"} and method not in {"client_secret", "private_key_jwt"}:
        errors.append(f"{prefix}: {profile} requires confidential client authentication")
    if profile == "token_exchange" and not spec.get("tokenExchangePolicy"):
        errors.append(f"{prefix}: token_exchange requires tokenExchangePolicy")
    if profile != "token_exchange" and spec.get("tokenExchangePolicy"):
        errors.append(f"{prefix}: tokenExchangePolicy is only valid for token_exchange")
    if profile in {"confidential_web", "public_spa", "native", "device"} and not spec.get("oidcPolicy"):
        errors.append(f"{prefix}: {profile} requires oidcPolicy")

    if spec["accessTokenManager"] not in catalog["accessTokenManagers"]:
        errors.append(f"{prefix}: unknown accessTokenManager {spec['accessTokenManager']!r}")
    if spec.get("oidcPolicy") and spec["oidcPolicy"] not in catalog["oidcPolicies"]:
        errors.append(f"{prefix}: unknown oidcPolicy {spec['oidcPolicy']!r}")
    if spec.get("tokenExchangePolicy") and spec["tokenExchangePolicy"] not in catalog["tokenExchangePolicies"]:
        errors.append(f"{prefix}: unknown tokenExchangePolicy {spec['tokenExchangePolicy']!r}")
    approved_scopes = set(platform["spec"]["approvedScopes"])
    for scope in spec["scopes"]:
        if scope == "*" or scope not in approved_scopes:
            errors.append(f"{prefix}: scope {scope!r} is not in the platform allowlist")

    for environment in ("development", "staging", "production"):
        effective = effective_spec(spec, environment)
        if profile in {"confidential_web", "public_spa", "native"} and not effective.get("redirectUris"):
            errors.append(f"{prefix}: {environment} requires a redirect URI for {profile}")
        for field in ("redirectUris", "logoutUris", "postLogoutRedirectUris"):
            for uri in effective.get(field, []):
                reason = unsafe_uri(uri, profile)
                if reason:
                    errors.append(f"{prefix}: {environment}.{field} URI {uri!r} {reason}")
    return errors


def validate_all() -> list[str]:
    try:
        platform = load_yaml(PLATFORM_FILE)
        ownership = load_yaml(OWNERSHIP_FILE)
    except (OSError, yaml.YAMLError, ValueError) as exc:
        return [str(exc)]
    errors, catalog = validate_platform(platform)
    if errors:
        return errors
    if not TEAM_RE.fullmatch(ownership.get("identityPlatformTeam", "")):
        errors.append("ownership: identityPlatformTeam must be an organisation/team slug")
    for key, record in ownership.get("applications", {}).items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9-]*", key):
            errors.append(f"ownership: invalid application key {key!r}")
        if not TEAM_RE.fullmatch(record.get("githubTeam", "")):
            errors.append(f"ownership: invalid githubTeam for {key!r}")
    seen_client_ids = {}
    for path in sorted(APPLICATIONS.glob("*.yaml")):
        try:
            document = load_yaml(path)
            errors.extend(validate_client(path.relative_to(ROOT), document, platform, catalog, ownership))
            metadata, spec = document.get("metadata", {}), document.get("spec", {})
            client_id = spec.get("clientId") or f"{metadata.get('organisation')}-{metadata.get('application')}"
            if client_id in seen_client_ids:
                errors.append(f"{path.as_posix()}: duplicate client ID {client_id!r}")
            seen_client_ids[client_id] = path.as_posix()
        except (OSError, yaml.YAMLError, ValueError) as exc:
            errors.append(f"{path.as_posix()}: {exc}")
    return errors


def codeowners_content() -> str:
    ownership = load_yaml(OWNERSHIP_FILE)
    identity = "@" + ownership["identityPlatformTeam"]
    lines = [
        "# Generated by oauth2/tools/oauth2_config.py codeowners; do not edit by hand.",
        f"/oauth2/platform/ {identity}",
        f"/oauth2/schemas/ {identity}",
        f"/oauth2/tools/ {identity}",
        f"/oauth2/ownership.yaml {identity}",
        f"/terraform/ {identity}",
        f"/setup/ {identity}",
        f"/.github/workflows/oauth2-*.yml {identity}",
    ]
    for key, record in sorted(ownership.get("applications", {}).items()):
        organisation, application = key.split("/", 1)
        lines.append(f"/oauth2/applications/oauth2_{organisation}_{application}.yaml @{record['githubTeam']} {identity}")
    return "\n".join(lines) + "\n"


def render_application(path: Path, environment: str) -> dict:
    document = load_yaml(path)
    spec = effective_spec(document["spec"], environment)
    metadata = document["metadata"]
    return {
        "metadata": metadata,
        "lifecycle": document["lifecycle"],
        "spec": spec,
        "clientId": spec.get("clientId") or f"{metadata['organisation']}-{metadata['application']}",
    }


def scaffold(organisation: str, application: str, profile: str, name: str) -> Path:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", organisation):
        raise ValueError("invalid organisation slug")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", application):
        raise ValueError("invalid application slug")
    profiles = {"confidential_web", "public_spa", "native", "service", "device", "token_exchange"}
    if profile not in profiles:
        raise ValueError("invalid client profile")
    path = APPLICATIONS / f"oauth2_{organisation}_{application}.yaml"
    if path.exists():
        raise FileExistsError(f"refusing to overwrite {path}")
    method = "none" if profile in {"public_spa", "native", "device"} else "client_secret"
    authentication = {"method": method}
    if method == "client_secret":
        authentication["secretRef"] = "client_secret"
    spec = {
        "name": name,
        "profile": profile,
        "accessTokenManager": "default-reference",
        "scopes": ["openid"],
        "authentication": authentication,
        "environments": {environment: {} for environment in ("development", "staging", "production")},
    }
    if profile in {"confidential_web", "public_spa", "native", "device"}:
        spec["oidcPolicy"] = "default-oidc"
    if profile == "token_exchange":
        spec["tokenExchangePolicy"] = "replace-with-approved-policy"
    document = {
        "apiVersion": "pingfederate.oauth2/v1alpha1",
        "kind": "OAuth2Client",
        "metadata": {"organisation": organisation, "application": application},
        "lifecycle": {"state": "disabled"},
        "spec": spec,
    }
    write_text_lf(
        path,
        "# yaml-language-server: $schema=../schemas/oauth2-client.schema.json\n"
        + yaml.safe_dump(document, sort_keys=False),
    )
    return path


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("validate")
    owners = commands.add_parser("codeowners")
    owners.add_argument("--check", action="store_true")
    render = commands.add_parser("render")
    render.add_argument("file", type=Path)
    render.add_argument("--environment", choices=["development", "staging", "production"], required=True)
    create = commands.add_parser("scaffold")
    create.add_argument("--organisation", required=True)
    create.add_argument("--application", required=True)
    create.add_argument("--profile", required=True)
    create.add_argument("--name", required=True)
    args = parser.parse_args()

    if args.command == "validate":
        errors = validate_all()
        if errors:
            print("\n".join(f"ERROR: {error}" for error in errors), file=sys.stderr)
            return 1
        print("OAuth2 configuration is valid")
        return 0
    if args.command == "codeowners":
        expected = codeowners_content()
        path = ROOT / ".github" / "CODEOWNERS"
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != expected:
                print("ERROR: .github/CODEOWNERS is stale", file=sys.stderr)
                return 1
        else:
            write_text_lf(path, expected)
        return 0
    if args.command == "render":
        print(json.dumps(render_application(args.file.resolve(), args.environment), indent=2, sort_keys=True))
        return 0
    if args.command == "scaffold":
        print(scaffold(args.organisation, args.application, args.profile, args.name))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
