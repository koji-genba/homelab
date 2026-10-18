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

# Re-apply must preserve live container ownership and mounted filesystem roots.
roles = ansible_root / "roles"


def tasks(role, filename="main.yml"):
    return yaml.safe_load((roles / role / "tasks" / filename).read_text())


def task(role, name, filename="main.yml"):
    return next(t for t in tasks(role, filename) if t["name"] == name)


defaults = yaml.safe_load((roles / "agent_stack/defaults/main.yml").read_text())
assert defaults["agent_stack_postgres_uid"] == 999
assert defaults["agent_stack_postgres_gid"] == 999
# Numeric IDs belong to the pinned Debian PGroonga base, not Hermes' UID.
dockerfile = (repo / "files/services/images/memory-db/Dockerfile").read_text()
assert "groonga/pgroonga:4.0.8-debian-17@sha256:" in dockerfile
dirs = task("agent_stack", "Create the Agent service directories", "directories.yml")
directory_items = {item["path"]: item for item in dirs["loop"]}
for path, uid, gid, mode in (
    ("{{ agent_stack_postgres_data_dir }}", "agent_stack_postgres_uid", "agent_stack_postgres_gid", "0700"),
    ("{{ agent_stack_hermes_data_dir }}", "agent_stack_uid", "agent_stack_gid", "0750"),
    ("{{ agent_stack_ssh_key_dir }}", "agent_stack_uid", "agent_stack_gid", "0700"),
):
    entry = directory_items[path]
    assert entry["owner"] == "{{ " + uid + " }}", entry
    assert entry["group"] == "{{ " + gid + " }}", entry
    assert entry["mode"] == mode, entry
assert directory_items["{{ agent_stack_models_dir }}"] == {
    "path": "{{ agent_stack_models_dir }}", "mode": "0755"
}  # root fetcher writes; embedding mounts read-only
assert dirs["ansible.builtin.file"]["owner"] == "{{ item.owner | default('root') }}"
assert dirs["ansible.builtin.file"]["group"] == "{{ item.group | default('root') }}"

# The later key-hardening task must agree with directory creation.
hardening = task("agent_stack", "Harden the identity directory and private keys", "ssh_keys.yml")
assert hardening["ansible.builtin.file"]["owner"] == "{{ agent_stack_uid }}"
assert hardening["ansible.builtin.file"]["group"] == "{{ agent_stack_gid }}"
assert hardening["loop"][0]["mode"] == "0700"
private = task("common", "Create the private host secrets directory")["ansible.builtin.file"]
assert (private["owner"], private["group"], private["mode"]) == ("root", "root", "0700")
assert "'/etc/homelab/secrets'" not in task("common", "Create host directories")["loop"]

# findmnt -M checks the exact mount root (not an ancestor); only rc=1 permits
# pre-mount metadata writes. Probes also run during --check, without changes.
for role, filename, probe_name, create_name, variable, path in (
    ("agent_storage", "main.yml", "Check whether the Agent data path is already mounted",
     "Create the Agent data mount point", "agent_storage_data_mountpoint", "{{ agent_data_mount }}"),
    ("agent_storage", "main.yml", "Check whether the backup paths are already mounted",
     "Create the backup mount points", "agent_storage_backup_mountpoints", "{{ item.local_path }}"),
    ("runner", "storage.yml", "Check whether the runner work path is already mounted",
     "Create the runner work mount point", "runner_data_mountpoint", "{{ runner_data_mount }}"),
):
    probe = task(role, probe_name, filename)
    create = task(role, create_name, filename)
    assert probe["ansible.builtin.command"]["argv"] == ["findmnt", "-rn", "-M", path]
    assert probe["register"] == variable
    assert probe["changed_when"] is False
    assert probe["check_mode"] is False
    assert probe["failed_when"] == variable + ".rc not in [0, 1]"
    if role == "agent_storage" and "backup" in variable:
        assert create["loop"] == "{{ " + variable + ".results }}"
        assert create["when"] == "item.rc == 1"
        assert create["ansible.builtin.file"]["path"] == "{{ item.item.local_path }}"
    else:
        assert create["when"] == variable + ".rc == 1"
    ordered = tasks(role, filename)
    assert ordered.index(probe) < ordered.index(create)

# One owner/mode before and after the Runner mount; never a transient root.
runner_storage = tasks("runner", "storage.yml")
work_writers = [t["ansible.builtin.file"] for t in runner_storage if "ansible.builtin.file" in t]
assert len(work_writers) == 2
for writer in work_writers:
    assert writer["path"] == "{{ runner_data_mount }}"
    assert (writer["owner"], writer["group"], writer["mode"]) == (
        "{{ runner_user }}", "{{ runner_user }}", "0750")

# Keep OpenSSH's additional learned algorithms; whole-file copy would erase
# them and report changed after the next terminal connection again.
pin = task("agent_stack", "Pin the Runner host key for the Hermes terminal backend", "ssh_keys.yml")
assert "ansible.builtin.copy" not in pin
assert pin["ansible.builtin.known_hosts"]["state"] == "present"
assert pin["ansible.builtin.known_hosts"]["name"] == "{{ agent_stack_runner_host }}"

# Ops owns only the root work dirs. Hindsight checkpoints and scratch PGDATA
# are child paths owned by their containers; Ansible must not traverse them.
ops = task("agent_ops", "Create the operation state and work directories")
assert (ops["ansible.builtin.file"]["owner"], ops["ansible.builtin.file"]["group"]) == ("root", "root")
assert {entry["path"]: entry["mode"] for entry in ops["loop"]} == {
    "{{ agent_ops_state_dir }}": "0750", "{{ agent_ops_exports_dir }}": "0750",
    "{{ agent_ops_scratch_dir }}": "0700", "{{ agent_ops_safety_dir }}": "0700",
    "{{ agent_ops_rebuild_dir }}": "0700", "{{ agent_ops_tmp_dir }}": "0700",
}
for role in ("agent_stack", "agent_storage", "agent_ops", "runner", "common"):
    for path in (roles / role / "tasks").glob("*.yml"):
        for entry in yaml.safe_load(path.read_text()):
            assert not entry.get("ansible.builtin.file", {}).get("recurse", False), path
PY

echo "Agent/Runner Terraform scope fixture: ok"
