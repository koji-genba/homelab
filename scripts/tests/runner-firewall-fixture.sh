#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import yaml

root = pathlib.Path("files/infrastructure/ansible/agent")
all_vars = yaml.safe_load((root / "group_vars" / "all.yml").read_text())
runner_vars = yaml.safe_load((root / "group_vars" / "runner.yml").read_text())
agent_vars = yaml.safe_load((root / "group_vars" / "agent.yml").read_text())

# PRD 4.2: the Runner may reach only the internet. New connections to the LAN,
# RFC1918, CGNAT/tailnet and link-local ranges are rejected.
assert runner_vars["firewall_egress_restrict"] is True
assert agent_vars["firewall_egress_restrict"] is False
common_rejected = all_vars["firewall_egress_rejected_networks"]
for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"):
    assert network in common_rejected, network
# No blanket exception to the egress block, and no extra allowed destinations.
assert runner_vars["firewall_egress_allowed_networks"] == []
assert runner_vars["firewall_egress_allowed_dns"] == []

# Ingress on the Runner is SSH-only. Management sources are the server VLAN,
# the Trusted VLAN and the tailnet CGNAT range (via the gateway subnet route);
# the legacy 192.168.11.0/24 range is not needed.
assert runner_vars["firewall_input_allowed_tcp_ports"] == []
assert set(runner_vars["firewall_ssh_allowed_networks"]) == {
    "192.168.10.104/32",
    "192.168.10.0/24",
    "192.168.20.0/24",
    "100.64.0.0/10",
}
assert "192.168.11.0/24" not in runner_vars["firewall_ssh_allowed_networks"]
default_ssh = set(all_vars["firewall_ssh_allowed_networks"])
assert {"192.168.10.0/24", "192.168.20.0/24", "100.64.0.0/10"} <= default_ssh
assert "192.168.11.0/24" not in default_ssh

template = (root / "roles" / "firewall" / "templates" / "nftables.conf.j2").read_text()
# Default-drop ingress, reject only NEW egress to the blocked ranges so reply
# traffic to already-established connections keeps flowing.
assert "policy drop;" in template
assert "ip daddr { {{ rejected_networks }} } ct state new reject" in template
assert "{% if firewall_egress_restrict | bool %}" in template
PY

echo "Runner egress firewall fixture: ok"
