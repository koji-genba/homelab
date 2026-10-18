#!/bin/sh
set -eu

python3 <<'PY'
import pathlib
import re

import jinja2
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
assert pin["ansible.builtin.known_hosts"]["key"] == "{{ agent_stack_runner_host_key_line }}"
cdp_pin = task("agent_stack", "Pin the Runner host key for the CDP tunnel", "ssh_keys.yml")
assert cdp_pin["ansible.builtin.copy"]["content"] == "{{ agent_stack_runner_host_key_line }}\n"

# keyscan banners must never become part of either pinned key. Validate before
# indexing or writing, while preserving the original scan retry conditions.
scan = task("agent_stack", "Scan the Runner SSH host key", "ssh_keys.yml")
assert scan["register"] == "agent_stack_runner_host_key"
assert scan["until"] == (
    "agent_stack_runner_host_key.rc == 0 "
    "and 'ssh-ed25519' in agent_stack_runner_host_key.stdout")
assert (scan["retries"], scan["delay"], scan["changed_when"]) == (30, 10, False)
filtered = task("agent_stack", "Filter the Runner host key scan output", "ssh_keys.yml")
expression = filtered["ansible.builtin.set_fact"]["agent_stack_runner_host_key_lines"]
for fragment in ("stdout.splitlines()", "map('trim')", "reject('equalto', '')",
                 "reject('match', '^#')", "| list"):
    assert fragment in expression
validate = task("agent_stack", "Validate the Runner host key scan output", "ssh_keys.yml")
checks = validate["ansible.builtin.assert"]["that"]
assert checks[0] == "agent_stack_runner_host_key_lines | length == 1"
assert "agent_stack_runner_host | regex_escape" in checks[1]
assert "ssh-ed25519 [A-Za-z0-9+/]+={0,2}$" in checks[1]
assert "exactly one non-comment key line" in validate["ansible.builtin.assert"]["fail_msg"]
line = task("agent_stack", "Set the validated Runner host key line", "ssh_keys.yml")
assert line["ansible.builtin.set_fact"]["agent_stack_runner_host_key_line"] == (
    "{{ agent_stack_runner_host_key_lines | first }}")
ordered = tasks("agent_stack", "ssh_keys.yml")
assert [ordered.index(t) for t in (scan, filtered, validate, line, cdp_pin, pin)] == sorted(
    ordered.index(t) for t in (scan, filtered, validate, line, cdp_pin, pin))

# Evaluate the actual task expressions, including malformed scan results.
env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
env.tests["match"] = lambda value, pattern: re.match(pattern, value) is not None
env.filters["regex_escape"] = re.escape

# Bind-mounted input changes must refresh Hermes even when Compose's service
# definition is unchanged. Keep its network-namespace consumer in the same up.
recreate_name = "Recreate Hermes and the CDP tunnel"
for filename, names in (
    ("config.yml", (
        "Render the Hermes configuration", "Render the Hindsight plugin configuration",
        "Seed the Hermes persona when absent", "Seed the shipped skills when absent")),
    ("ssh_keys.yml", (
        "Generate the Runner terminal identity", "Generate the CDP tunnel identity",
        "Pin the Runner host key for the CDP tunnel",
        "Pin the Runner host key for the Hermes terminal backend")),
):
    for name in names:
        assert task("agent_stack", name, filename)["notify"] == recreate_name, name
assert task("agent_stack", "Render the Hermes configuration", "config.yml")["ansible.builtin.template"]["mode"] == "0640"
for name in ("Install the Agent Compose project definition", "Render the non-secret Compose environment"):
    assert task("agent_stack", name, "config.yml")["notify"] == "Restart the Agent stack"
for name, module in (("Seed the Hermes persona when absent", "ansible.builtin.template"),
                     ("Seed the shipped skills when absent", "ansible.builtin.copy")):
    assert task("agent_stack", name, "config.yml")[module]["force"] is False
handlers = yaml.safe_load((roles / "agent_stack/handlers/main.yml").read_text())
assert [h["name"] for h in handlers] == ["Restart the Agent stack", recreate_name]
assert handlers[0]["ansible.builtin.command"]["argv"] == [
    "{{ agent_stack_helpers_dir }}/homelab-agent-compose-up"]
expression_argv = handlers[1]["ansible.builtin.command"]["argv"].strip()[2:-2]
render_argv = env.compile_expression(expression_argv)
context = dict(defaults, agent_stack_project_name="fixture",
               agent_stack_project_dir="/fixture/project", agent_stack_env_file="/fixture/compose.env",
               agent_stack_secrets_dir="/fixture/secrets")
prefix = [env.from_string(value).render(**context) for value in defaults["agent_stack_compose_argv_prefix"]]
for timeout in (defaults["agent_stack_compose_wait_timeout"], 37):
    argv = render_argv(agent_stack_compose_argv_prefix=prefix, agent_stack_compose_wait_timeout=timeout)
    assert argv == prefix + ["up", "-d", "--no-deps", "--force-recreate", "--wait",
                             "--wait-timeout", str(timeout), "hermes", "cdp-tunnel"], argv
compose = yaml.safe_load((repo / "files/services/agent/stack/compose.yaml").read_text())
assert compose["services"]["cdp-tunnel"]["network_mode"] == "service:hermes"
# These services have no host-rendered bind-mounted config requiring a force
# refresh. Embedding alone mounts an immutable, revision-pinned model cache.
for service in ("hindsight", "reranker"):
    assert not compose["services"][service].get("volumes"), service
assert compose["services"]["embedding"]["volumes"][0]["read_only"] is True
print("Agent bind-mounted config: notifications, handler order and scoped recreate argv passed")

filter_scan = env.compile_expression(expression.strip()[2:-2])
validators = [env.compile_expression(check) for check in checks]
host = "192.168.10.105"
key = host + " ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKey1234567890abcd="
banner = "# " + host + ":22 SSH-2.0-OpenSSH_fixture\n"
for stdout, accepted in (
    (banner + key + "\n", True),
    ("\n  " + banner + "\n  " + key + "  \n\t\n", True),
    (key, True),
    ("", False),
    (banner, False),
    (banner + key + "\n" + key, False),
    (key.replace(host, "192.168.10.106"), False),
    (key.replace(host, "192x168x10x105"), False),
    (key.replace("ssh-ed25519", "ssh-rsa"), False),
    (host + " ssh-ed25519 !!!", False),
    (key + " unexpected-comment", False),
):
    lines = filter_scan(agent_stack_runner_host_key={"stdout": stdout})
    context = {"agent_stack_runner_host_key_lines": lines, "agent_stack_runner_host": host}
    assert all(check(**context) for check in validators) == accepted, stdout
    if accepted:
        assert lines == [key], lines
        fact = env.from_string(line["ansible.builtin.set_fact"]["agent_stack_runner_host_key_line"]).render(**context)
        assert env.from_string(cdp_pin["ansible.builtin.copy"]["content"]).render(
            agent_stack_runner_host_key_line=fact) == key + "\n"
        assert env.from_string(pin["ansible.builtin.known_hosts"]["key"]).render(
            agent_stack_runner_host_key_line=fact) == key

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
