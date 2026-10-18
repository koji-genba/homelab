#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import yaml

root = pathlib.Path("files/infrastructure/ansible/agent")
all_vars = yaml.safe_load((root / "group_vars" / "all.yml").read_text())
agent_vars = yaml.safe_load((root / "group_vars" / "agent.yml").read_text())
runner_vars = yaml.safe_load((root / "group_vars" / "runner.yml").read_text())

# The Agent VM does not publish Docker ports today; the DNAT guard is defence in
# depth against an accidental `ports:` entry being added later.
assert all_vars["firewall_dnat_guard"] is True
assert agent_vars["firewall_dnat_guard"] is True
# The Runner runs no Docker, so the guard is not rendered there.
assert runner_vars["firewall_dnat_guard"] is False

# Trusted sources mirror the Apps VM guard, without the legacy range.
trusted = set(all_vars["firewall_trusted_networks"])
assert {"192.168.10.0/24", "192.168.20.0/24", "100.64.0.0/10"} <= trusted
assert "192.168.11.0/24" not in trusted

template = (root / "roles" / "firewall" / "templates" / "nftables.conf.j2").read_text()
# Early-guard forward chain equivalent to the Apps VM: drop DNAT packets whose
# source is outside the trusted set, keep the rest accepted.
assert "chain forward {" in template
assert "type filter hook forward priority -100; policy accept;" in template
assert "ct status dnat ip saddr != { {{ trusted_networks }} } drop" in template
assert "{% if firewall_dnat_guard | bool %}" in template
# The policy must never flush or replace Docker's own tables/rules.
assert "flush ruleset" not in template
assert "flush table" not in template
assert "delete table" not in template
PY

echo "Agent DNAT guard fixture: ok"
