#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import yaml

root = pathlib.Path("files/infrastructure/ansible/agent")
all_vars = yaml.safe_load((root / "group_vars" / "all.yml").read_text())
runner_vars = yaml.safe_load((root / "group_vars" / "runner.yml").read_text())
agent_vars = yaml.safe_load((root / "group_vars" / "agent.yml").read_text())

# PRD 4.2 + ADR-0014: internet and pve1 TCP 2049 only. Other NEW connections
# to LAN, RFC1918, CGNAT/tailnet and link-local ranges are rejected.
assert runner_vars["firewall_egress_restrict"] is True
assert agent_vars["firewall_egress_restrict"] is False
common_rejected = all_vars["firewall_egress_rejected_networks"]
for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"):
    assert network in common_rejected, network
# No blanket exception: only the dedicated pve1 NFS TCP endpoint is allowed.
assert runner_vars["firewall_egress_allowed_networks"] == []
assert runner_vars["firewall_egress_allowed_dns"] == []
assert all_vars["firewall_egress_allowed_tcp"] == []
assert runner_vars["firewall_egress_allowed_tcp"] == [
    {"address": "192.168.10.11/32", "port": 2049}
]

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
# Render the real template with Ansible-compatible whitespace and bool filter.
import ipaddress
import re
from jinja2 import Environment

env = Environment(trim_blocks=True, lstrip_blocks=True)
env.filters["bool"] = bool

def render(values, text=template):
    return env.from_string(text).render(**(all_vars | values))

runner = render(runner_vars)
rule = "ip daddr 192.168.10.11/32 tcp dport 2049 accept"
assert runner.count(rule) == 1
assert runner.index(rule) < runner.index("ct state new reject")
# Removing only the new optional loop reconstructs the previous template.
old_template = re.sub(
    r"{% for exception in firewall_egress_allowed_tcp \| default\(\[\]\) %}.*?{% endfor %}\n",
    "", template, flags=re.S,
)
assert old_template != template
for values in (agent_vars, {}, runner_vars | {"firewall_egress_allowed_tcp": []}):
    assert render(values) == render(values, old_template)

# Evaluate the rendered NEW IPv4 output rules in order, including broad accepts
# should a future change accidentally add one. This is not a live packet test.
output = runner.split("  chain output {", 1)[1]

def allowed(address, port, protocol="tcp"):
    address = ipaddress.ip_address(address)
    for line in output.splitlines():
        line = line.strip()
        match = re.fullmatch(r"ip daddr (\S+)(?: (tcp|udp) dport (\d+))? accept", line)
        if match:
            network, proto, number = match.groups()
            if address in ipaddress.ip_network(network) and (proto is None or
                    (proto == protocol and int(number) == port)):
                return True
        match = re.fullmatch(r"ip daddr \{ (.+) \} ct state new reject", line)
        if match and any(address in ipaddress.ip_network(n.strip())
                         for n in match[1].split(",")):
            return False
    return True  # output policy accept

assert allowed("192.168.10.11", 2049)
for port in (22, 53, 111, 443, 2048, 2050, 8006):
    assert not allowed("192.168.10.11", port), port
assert not allowed("192.168.10.11", 2049, "udp")
for address in ("192.168.10.51", "192.168.10.101", "192.168.20.1",
                "10.0.0.1", "172.16.0.1", "100.64.0.1", "169.254.169.254"):
    assert not allowed(address, 2049), address
assert allowed("1.1.1.1", 443)
PY

echo "Runner egress firewall fixture: ok"
