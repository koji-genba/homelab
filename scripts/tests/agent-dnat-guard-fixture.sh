#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import yaml

root = pathlib.Path("files/infrastructure/ansible/agent")
all_vars = yaml.safe_load((root / "group_vars" / "all.yml").read_text())
agent_vars = yaml.safe_load((root / "group_vars" / "agent.yml").read_text())
runner_vars = yaml.safe_load((root / "group_vars" / "runner.yml").read_text())

# Agent publishes Webapp; keep the broad guard and a stricter port guard.
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

# Render both roles: the stricter rule must precede established accepts as well
# as the broad trusted guard. Runner must not acquire a Webapp exception.
import ipaddress
import jinja2

env = jinja2.Environment(undefined=jinja2.StrictUndefined)
env.filters["bool"] = bool
for host, vars_ in (("agent", agent_vars), ("runner", runner_vars)):
    context = dict(all_vars, **vars_)
    if host == "agent":
        context["firewall_webapp_port"] = context["agent_stack_webapp_port"]
    rendered = env.from_string(template).render(**context)
    if host == "runner":
        assert "9120" not in rendered
        continue
    forward = rendered.split("chain forward {", 1)[1].split("chain output", 1)[0]
    # Reply packets retain the original tuple; their packet source is the container.
    narrow = "ct status dnat meta l4proto tcp ct original proto-dst 9120 ct original ip saddr != 192.168.10.101/32 drop"
    assert forward.index(narrow) < forward.index("ct state established,related accept")
    assert forward.index(narrow) < forward.index("ct status dnat ip saddr !=")
    input_ = rendered.split("chain input {", 1)[1].split("chain forward", 1)[0]
    loopback = input_.index('iifname "lo" accept')
    webapp_accept = input_.index("ip saddr 192.168.10.101/32 tcp dport 9120 accept")
    webapp_drop = input_.index("tcp dport 9120 drop")
    established = input_.index("ct state established,related accept")
    assert loopback < webapp_accept < webapp_drop < established
    allowed = ipaddress.ip_network(context["firewall_webapp_allowed_source"])
    for source, accepted in (("192.168.10.101", True), ("192.168.10.105", False),
                             ("192.168.10.51", False), ("192.168.20.10", False),
                             ("100.86.147.127", False)):
        assert (ipaddress.ip_address(source) in allowed) == accepted
PY

echo "Agent DNAT guard fixture: ok"
