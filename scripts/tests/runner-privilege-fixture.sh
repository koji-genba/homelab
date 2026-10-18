#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import jinja2
import yaml

role = pathlib.Path("files/infrastructure/ansible/agent/roles/runner")
user_tasks = yaml.safe_load((role / "tasks" / "user.yml").read_text())
cdp_tasks = yaml.safe_load((role / "tasks" / "cdp.yml").read_text())

# The execution account must never hold sudo or the docker group: both are
# root-equivalent and would defeat the Runner isolation (PRD 4.2).
account = next(t for t in user_tasks if t["name"].startswith("Ensure the runner execution account"))
user = account["ansible.builtin.user"]
assert user["groups"] == []
assert user["append"] is False
assert user["password_lock"] is True
assert not {"sudo", "docker"} & set(user["groups"])

# A guard independent of the idempotent user task: fail the run if the account
# somehow already carries a privileged group.
guard = next(t for t in user_tasks if t["name"] == "Refuse a privileged runner account")
guard_body = str(guard["ansible.builtin.assert"])
assert "sudo" in guard_body and "docker" in guard_body

# The terminal key is restricted to the Agent address and disabled for
# forwarding/agent/X11 forwarding by default.
terminal_key = next(t for t in user_tasks if t["name"].startswith("Install the Agent VM SSH key"))
terminal_opts = terminal_key["ansible.posix.authorized_key"]["key_options"]
assert 'from="{{ agent_management_ip }}"' in terminal_opts
assert "no-agent-forwarding" in terminal_opts
assert "no-port-forwarding" in terminal_opts
assert "no-X11-forwarding" in terminal_opts

# The CDP account is a forwarding-only tunnel: no shell, and the authorized key
# may only open the single loopback CDP port.
tunnel = next(t for t in cdp_tasks if t["name"].startswith("Ensure the CDP tunnel account"))
assert tunnel["ansible.builtin.user"]["shell"] == "/usr/sbin/nologin"
assert tunnel["ansible.builtin.user"]["password_lock"] is True
cdp_key = next(t for t in cdp_tasks if t["name"].startswith("Install the Agent VM CDP tunnel key"))
cdp_opts = cdp_key["ansible.posix.authorized_key"]["key_options"]
assert "restrict" in cdp_opts
# `restrict` also disables port forwarding, so the tunnel needs the explicit
# opt-in. This also enables -R: permitopen alone is NOT a remote-forward guard.
assert "port-forwarding" in cdp_opts.split(",")
assert 'permitopen="127.0.0.1:{{ cdp_port }}"' in cdp_opts
assert 'from="{{ agent_management_ip }}"' in cdp_opts

# Enforce forwarding direction on the server, independently of key options.
# Render the real common-role content with each host's group vars so the Agent
# is also checked (it has no Runner accounts and must get no Match blocks).
root = role.parent.parent
common_tasks = yaml.safe_load((role.parent / "common/tasks/main.yml").read_text())
hardening = next(t["ansible.builtin.copy"] for t in common_tasks
                 if t.get("ansible.builtin.copy", {}).get("dest", "").endswith(
                     "/99-homelab-hardening.conf"))
assert hardening["validate"] == "/usr/sbin/sshd -t -f %s"
template = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(hardening["content"])
all_vars = yaml.safe_load((root / "group_vars/all.yml").read_text())


def ssh_policy(host_vars):
    rendered = template.render(all_vars | host_vars)
    blocks = {"all": {}}
    current = blocks["all"]
    for line in rendered.splitlines():
        words = line.split()
        if not words or words[0].startswith("#"):
            continue
        if words[0] == "Match":
            if words[1:] == ["all"]:
                current = blocks["all"]
            else:
                assert words[1] == "User"
                current = blocks.setdefault(words[2], {})
        else:
            current[words[0]] = " ".join(words[1:])
    assert current is blocks["all"], "Match scope must end before later config"
    return blocks


runner_vars = yaml.safe_load((root / "group_vars/runner.yml").read_text())
# Also prove that account names and the CDP port are rendered, not hardcoded.
for host_vars in (runner_vars, runner_vars | {"cdp_user": "test-cdp",
                                            "runner_user": "test-runner", "cdp_port": 19333}):
    policy = ssh_policy(host_vars)
    assert policy[host_vars["cdp_user"]] == {
        "AllowTcpForwarding": "local",
        "PermitOpen": f'127.0.0.1:{host_vars["cdp_port"]}',
        "PermitListen": "none",
        "AllowStreamLocalForwarding": "no",
        "AllowAgentForwarding": "no",
        "X11Forwarding": "no",
        "PermitTTY": "no",
        "PermitTunnel": "no",
        "PermitUserRC": "no",
        "MaxSessions": "0",
    }
    terminal_policy = policy[host_vars["runner_user"]]
    for option in ("AllowTcpForwarding", "AllowStreamLocalForwarding",
                   "AllowAgentForwarding", "X11Forwarding", "PermitTunnel"):
        assert terminal_policy[option] == "no"
    assert terminal_policy["DisableForwarding"] == "yes"
    assert terminal_policy["PermitListen"] == "none"
    assert "MaxSessions" not in terminal_policy
    assert "ForceCommand" not in terminal_policy
    assert "PermitTTY" not in terminal_policy

agent_vars = yaml.safe_load((root / "group_vars/agent.yml").read_text())
assert set(ssh_policy(agent_vars)) == {"all"}

# Headless Chromium: loopback-only CDP, its own system user, and Chromium's own
# sandbox kept enabled (no --no-sandbox).
service = (role / "templates" / "hermes-chromium.service.j2").read_text()
assert "--headless=new" in service
assert "--remote-debugging-address=127.0.0.1" in service
assert "--remote-debugging-port={{ cdp_port }}" in service
assert "--no-sandbox" not in service
assert "NoNewPrivileges=yes" in service
# The namespace sandbox needs user/pid/net namespaces; a blanket
# RestrictNamespaces=yes would block them.
assert "RestrictNamespaces=yes" not in service
assert "RestrictNamespaces=user pid net" in service
# Chromium monitors the network via netlink.
assert "AF_NETLINK" in service

chromium_tasks = yaml.safe_load((role / "tasks" / "chromium.yml").read_text())
# Unprivileged user namespaces must be enabled for the sandbox.
userns = next(t for t in chromium_tasks if t.get("ansible.posix.sysctl"))
assert userns["ansible.posix.sysctl"]["name"] == "kernel.unprivileged_userns_clone"
assert userns["ansible.posix.sysctl"]["value"] == "1"
# The apply must fail loudly when the CDP endpoint never comes up.
probe = next(t for t in chromium_tasks if "ansible.builtin.uri" in t)
assert probe["ansible.builtin.uri"]["url"] == "http://127.0.0.1:{{ cdp_port }}/json/version"
assert probe["retries"] >= 1
assert probe["delay"] >= 1

# The Runner never installs Docker (the docker group is root-equivalent).
runtime_tasks = yaml.safe_load((role / "tasks" / "runtime.yml").read_text())
packages = set()
for task in runtime_tasks:
    apt = task.get("ansible.builtin.apt")
    if not apt:
        continue
    names = apt.get("name")
    if isinstance(names, str):
        names = [names]
    packages.update(names or [])
assert not {p for p in packages if str(p).startswith("docker")}, packages
assert "docker" not in (role / "tasks" / "main.yml").read_text().lower()
PY

echo "Runner privilege fixture: ok"
