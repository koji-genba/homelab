#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

import yaml

repo = pathlib.Path(".")
root = repo / "files/infrastructure/ansible/agent"
role = root / "roles" / "agent_ops"

# --- Role layout -------------------------------------------------------------
assert (role / "defaults" / "main.yml").is_file()
assert (role / "handlers" / "main.yml").is_file()
assert (role / "tasks" / "main.yml").is_file()
for name in (
    "homelab-agent-backup.sh.j2",
    "homelab-agent-restore.sh.j2",
    "homelab-agent-export.sh.j2",
    "homelab-agent-rebuild-memory.sh.j2",
    "homelab-agent-rebuild-memory.py.j2",
    "homelab-agent-healthcheck.sh.j2",
    "homelab-agent-backup.service.j2",
    "homelab-agent-backup.timer.j2",
    "homelab-agent-healthcheck.service.j2",
    "homelab-agent-healthcheck.timer.j2",
):
    assert (role / "templates" / name).is_file(), name

# --- Play wiring: agent_ops runs after agent_stack ---------------------------
site = yaml.safe_load((root / "site.yml").read_text())
agent_play = next(play for play in site if play["hosts"] == "agent")
roles = [r if isinstance(r, str) else next(iter(r)) for r in agent_play["roles"]]
assert "agent_ops" in roles
assert roles.index("agent_ops") > roles.index("agent_stack")

# --- Recovery recipient configured; example stays empty ----------------------
variables = yaml.safe_load((root / "group_vars/agent.yml").read_text())
assert variables["agent_backup_age_recipients"] == [
    "age1a8v97ung7t9g39vdxsdxgzta4fq4hz7hv7yezzlx6ac7xfgqgsws420x6u"
]
example = yaml.safe_load((root / "group_vars/agent.yml.example").read_text())
assert example["agent_backup_age_recipients"] == []

backup = (role / "templates" / "homelab-agent-backup.sh.j2").read_text()
# No recipients -> refuse rather than write plaintext.
assert "refusing to write unencrypted backups" in backup
# The NFS export is validated (source, fstype, marker) and a missing mount is a
# hard failure, never a silent local write.
assert "findmnt -rn -M" in backup
assert "refusing to write a backup to local disk" in backup
# Sensitive artifacts are always age-encrypted, staging is atomic.
assert "age " in backup
assert ".incomplete-$ts" in backup
assert 'mv "$staging" "$final"' in backup
# Completeness metadata.
assert "SHA256SUMS" in backup
assert "MANIFEST.txt" in backup
assert "pg_dump -Fc" in backup
assert "hermes backup -o" in backup
# Secrets are never pulled into the set.
assert "memory-db.env" in backup  # used only to drive compose, not archived
assert "/etc/homelab/secrets/*.env" in backup  # documented as excluded
# Generation management keeps the newest daily + weekly sets.
assert "DAILY_KEEP" in backup
assert "WEEKLY_KEEP" in backup

# --- Timer cadence -----------------------------------------------------------
defaults = yaml.safe_load((role / "defaults" / "main.yml").read_text())
assert defaults["agent_ops_backup_daily_keep"] == 14
assert defaults["agent_ops_backup_weekly_keep"] == 8
assert defaults["agent_ops_backup_on_calendar"] == "*-*-* 03:30:00"
timer = (role / "templates" / "homelab-agent-backup.timer.j2").read_text()
assert "OnCalendar={{ agent_ops_backup_on_calendar }}" in timer
assert "Persistent=true" in timer
PY

echo "Agent backup fixture: ok"
