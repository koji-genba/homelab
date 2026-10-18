#!/bin/sh
set -eu

python3 <<'PY'
import pathlib
import re

import yaml

repo = pathlib.Path(".")
root = repo / "files/infrastructure/ansible/agent"
role = root / "roles" / "agent_ops"
health = (role / "templates" / "homelab-agent-healthcheck.sh.j2").read_text()
defaults = yaml.safe_load((role / "defaults" / "main.yml").read_text())

# Every layer from PRD 4.6 is probed.
for probe in (
    "check_containers",
    "check_hindsight_ready",
    "check_tei",
    "check_inference",
    "check_runner",
    "check_cdp",
    "check_gateway",
    "check_cron",
    "check_hindsight_stats",
):
    assert probe + "()" in health, probe
    assert probe in health.split("main() {")[1], probe

# Gateway is read from the persisted state file and treats a platform that is
# not "connected" (and a gateway that is not "running") as a failure.
assert "gateway_state.json" in health
assert 'state.get("gateway_state") != "running"' in health
assert 'platform.get("state") != "connected"' in health
# The gateway snippet runs under `python3 -c '...'`; a backslash-escaped quote
# inside an f-string expression is a SyntaxError, so the state value is built by
# concatenation instead.
assert 'problems.append("gateway_state=" + str(state.get("gateway_state")))' in health
assert '\\"' not in health
# Cron failures are detected from the incidents subcommand (both open states).
assert 'hermes cron incidents --state "$state"' in health
assert "for state in detected alerted" in health
assert "No cron failure incidents recorded." in health

# Notification policy: only on change, periodic re-notify, recovery, dead-man.
assert "STATE_FILE" in health
assert "RENOTIFY" in health
assert "new_failures" in health
assert "recovered" in health
assert "still_failing" in health
assert "deadman_ping" in health
assert "notify_operator" in health

# No emojis in the generated script.
assert not re.search(r"[\U0001F300-\U0001FAFF\u2600-\u27BF]", health), "emoji in healthcheck"

# Timer runs every five minutes.
assert defaults["agent_ops_health_on_calendar"] == "*:0/5"
assert defaults["agent_ops_health_renotify_seconds"] == 21600
timer = (role / "templates" / "homelab-agent-healthcheck.timer.j2").read_text()
assert "OnCalendar={{ agent_ops_health_on_calendar }}" in timer
PY

echo "Agent health check fixture: ok"
