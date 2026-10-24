#!/bin/sh
# Static contract check; optional synthetic inputs support negative tests.
set -eu

python3 - "$@" <<'PY'
import json
import pathlib
import re
import sys

import yaml

vars_path, tf_path = sys.argv[1:] or [
    "files/infrastructure/ansible/gateway/group_vars/gateway.yml",
    "files/infrastructure/terraform/tailscale/variables.tf",
]
prefs = yaml.safe_load(pathlib.Path(vars_path).read_text())
exit_node = prefs["gateway_tailscale_advertise_exit_node"]
assert isinstance(exit_node, bool), "exit-node preference must be boolean"
routes = prefs["gateway_tailscale_advertise_routes"]
assert isinstance(routes, list) and all(isinstance(r, str) for r in routes)
expected = set(routes) | ({"0.0.0.0/0", "::/0"} if exit_node else set())

# This contract deliberately accepts only a literal default list. Fail closed
# if the Terraform declaration changes shape instead of silently skipping it.
text = re.sub(r"#[^\n]*|//[^\n]*|/\*.*?\*/", "", pathlib.Path(tf_path).read_text(), flags=re.S)
block = re.search(r'variable\s+"advertised_routes"\s*\{([^{}]*)\}', text)
assert block, "missing literal advertised_routes variable block"
default = re.search(r"\bdefault\s*=\s*(\[[^\]]*\])", block[1])
assert default, "missing literal advertised_routes default list"
approved = json.loads(re.sub(r",\s*\]", "]", default[1]))
assert isinstance(approved, list) and all(isinstance(r, str) for r in approved)
assert expected == set(approved), (
    f"gateway advertised routes {sorted(expected)} != Terraform approvals {sorted(approved)}"
)
print("Gateway/Terraform route contract: ok")
PY
