#!/bin/sh
set -eu

python3 <<'PY'
import pathlib
import re

import yaml

repo = pathlib.Path(".")

# The Agent/Runner roots are deliberately isolated from the Apps VM. They must
# not manage Apps containers, the Apps SOPS bundle, or the Compose project list.
ansible_root = repo / "files/infrastructure/ansible/agent"
site = yaml.safe_load((ansible_root / "site.yml").read_text())
plays = {play["hosts"]: [r if isinstance(r, str) else next(iter(r)) for r in play["roles"]] for play in site}
assert set(plays) == {"agent", "runner"}, plays
agent_roles = set(plays["agent"])
assert agent_roles == {"common", "docker", "firewall", "agent_storage", "agent_stack", "agent_ops"}, agent_roles
assert "secrets" not in agent_roles
assert "compose" not in agent_roles
# The Runner role bundle reuses only generic roles.
assert set(plays["runner"]) == {"common", "firewall", "runner"}, plays["runner"]

# The nearest ansible.cfg must point role resolution at this root and the Apps
# root, and must never enable the Apps project playbooks.
cfg = (ansible_root / "ansible.cfg").read_text()
assert "roles_path" in cfg

# No Apps-only roles are vendored or referenced by this root.
assert not (ansible_root / "roles" / "secrets").exists()
assert not (ansible_root / "roles" / "compose").exists()
assert not (ansible_root / "roles" / "base").exists()

# The inventory defines only the two Hermes hosts.
inventory = yaml.safe_load((ansible_root / "inventory" / "hosts.yml").read_text())
children = inventory["all"]["children"]
assert set(children) == {"agent", "runner"}, children
assert set(children["agent"]["hosts"]) == {"agent-vm"}
assert set(children["runner"]["hosts"]) == {"runner-vm"}

# The Terraform roots never reference the Apps VM, its containers, or SOPS.
for root in ("agent-vm", "runner-vm"):
    for path in (repo / "files/infrastructure/terraform" / root).glob("*.tf"):
        text = path.read_text()
        assert "proxmox_virtual_environment_container" not in text, path
        assert "sops" not in text.lower(), path
        assert "runtime.yaml" not in text, path

# The Terraform roots share one VM resource each, and their tftvars examples
# never carry a real secret (only a placeholder / env reference).
for root, resource in (("agent-vm", "agent"), ("runner-vm", "runner")):
    main = (repo / "files/infrastructure/terraform" / root / "main.tf").read_text()
    assert re.search(r'proxmox_virtual_environment_vm"\s+"' + resource + r'"', main), root

# The gitignored Agent bundle plaintext path is covered by .gitignore.
gitignore = (repo / ".gitignore").read_text()
assert "files/infrastructure/secrets/agent/runtime.yaml" in gitignore
PY

echo "Agent/Runner Terraform scope fixture: ok"
