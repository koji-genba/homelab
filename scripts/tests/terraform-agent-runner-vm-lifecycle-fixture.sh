#!/bin/sh
set -eu

python3 <<'PY'
import pathlib
import re

roots = {
    "agent": "files/infrastructure/terraform/agent-vm",
    "runner": "files/infrastructure/terraform/runner-vm",
}

# Each root keeps its own lifecycle protection: refreshing the creation-time
# cloud-init snippet must never replace an existing VM.
for host, root in roots.items():
    main = pathlib.Path(root, "main.tf").read_text()
    lifecycle = re.search(
        r'resource\s+"proxmox_virtual_environment_vm"\s+"' + host + r'".*?'
        r'\n\s*lifecycle\s*\{(?P<body>.*?)\n\s*\}',
        main,
        flags=re.DOTALL,
    )
    assert lifecycle, f"{host} VM lifecycle protection is missing"
    body = lifecycle.group("body")
    assert "ignore_changes = [" in body
    assert body.count("initialization[0].user_data_file_id") == 1

    # Cloud-init is always scsi0 and imports the pinned image; the data disk is
    # a separate, blank scsi1 device addressed by its by-id path in Ansible.
    disks = re.findall(r'\n\s*disk\s*\{(?P<body>.*?)\n\s*\}', main, flags=re.DOTALL)
    assert len(disks) == 2, f"{host} must declare exactly an OS disk and a data disk"
    os_disk, data_disk = disks
    assert 'interface    = "scsi0"' in os_disk
    assert "import_from" in os_disk
    assert 'interface    = "scsi1"' in data_disk
    assert "import_from" not in data_disk

    # Two separate Terraform states must never manage the same Proxmox object:
    # root-specific snippet and imported image file names.
    assert "source_raw" in main
    assert f'file_name = "{host}-cloud-init.yaml"' in main

# The two roots must not collide on VMID, address, or imported image object.
agent_vars = pathlib.Path(roots["agent"], "variables.tf").read_text()
runner_vars = pathlib.Path(roots["runner"], "variables.tf").read_text()
assert re.search(r'variable\s+"vm_id".*?default\s*=\s*104', agent_vars, re.DOTALL)
assert re.search(r'variable\s+"vm_id".*?default\s*=\s*105', runner_vars, re.DOTALL)
assert 'default     = "192.168.10.104/24"' in agent_vars
assert 'default     = "192.168.10.105/24"' in runner_vars
assert 'default     = "debian-13-genericcloud-amd64-agent.qcow2"' in agent_vars
assert 'default     = "debian-13-genericcloud-amd64-runner.qcow2"' in runner_vars

# Both roots pin the identical image URL and SHA-512, so drift in either is a
# deliberate, reviewed change.
checksum = "184761b0dad0f9ace02f9298050ca96ce3caa39a461a47706d47ff9698b59933918b91b40177fbd4d392f6446af8b4d18ecb94caca988169b19641606bf34003"
assert checksum in agent_vars
assert checksum in runner_vars
PY

echo "Agent/Runner VM cloud-init lifecycle fixture: ok"
