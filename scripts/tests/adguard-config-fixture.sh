#!/bin/sh
set -eu

# Render the Ansible-owned runtime template with non-secret fixture values,
# then run the exact v0.107.79 --check-config path when that image is present.
# The fixture never writes into the repository or the runtime directory.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT INT TERM

python3 - "$repo_root" "$fixture/AdGuardHome.yaml" <<'PY'
import json
import pathlib
import sys

try:
    import yaml
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
except ImportError as exc:
    raise SystemExit(f"fixture requires Python Jinja2 and PyYAML: {exc}")

root = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
template_dir = root / "files/infrastructure/ansible/apps/roles/secrets/templates"
playbook_dir = root / "files/infrastructure/ansible/apps"

def lookup(kind, path):
    if kind != "file":
        raise ValueError(f"unsupported lookup: {kind}")
    return pathlib.Path(path).read_text(encoding="utf-8")

def quote(value):
    return json.dumps(str(value))

def as_bool(value):
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return bool(value)

env = Environment(loader=FileSystemLoader(str(template_dir)), undefined=StrictUndefined,
                  keep_trailing_newline=True)
env.globals.update(lookup=lookup, playbook_dir=str(playbook_dir))
env.filters["quote"] = quote
env.filters["bool"] = as_bool
context = {
    "network_migration_complete": False,
    "legacy_ldaps_ip": "192.168.11.102",
    "secrets_runtime": {
        "adguard": {
            "username": "fixture-admin",
            "password_hash": "$2a$10$N9qo8uLOickgnaf2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17hu",
        }
    },
}
rendered = env.get_template("AdGuardHome.yaml.j2").render(**context)
parsed = yaml.safe_load(rendered)
assert parsed["schema_version"] == 34
assert parsed["http"]["doh"]["routes"]
assert parsed["dns"]["enable_dnssec"] is True
assert parsed["dns"]["cache_optimistic_answer_ttl"] == "30s"
assert parsed["dns"]["cache_optimistic_max_age"] == "12h"
assert all(item["enabled"] for item in parsed["filtering"]["rewrites"])
expected_filters = [
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/adblock/pro.txt",
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/adblock/tif.txt",
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/adblock/doh-vpn-proxy-bypass.txt",
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/adblock/dyndns.txt",
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/adblock/hoster.txt",
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@main/adblock/urlshortener.txt",
]
assert [item["url"] for item in parsed["filters"]] == expected_filters
assert [item["id"] for item in parsed["filters"]] == list(range(1, 7))
assert len({item["name"] for item in parsed["filters"]}) == len(parsed["filters"])
assert parsed["user_rules"] == ["@@||t.co^", "@@||tailscale.com^"]
destination.write_text(rendered, encoding="utf-8")
PY

"$repo_root/scripts/adguard-config-check.sh" "$fixture/AdGuardHome.yaml"
echo "AdGuard schema-34 fixture: ok"
