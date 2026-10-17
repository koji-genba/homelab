#!/bin/sh
set -eu

python3 <<'PY'
import pathlib
import re

import yaml

repo = pathlib.Path(".")
root = repo / "files/infrastructure/ansible/agent"
role = root / "roles" / "agent_ops"
restore = (role / "templates" / "homelab-agent-restore.sh.j2").read_text()
export = (role / "templates" / "homelab-agent-export.sh.j2").read_text()
rebuild = (role / "templates" / "homelab-agent-rebuild-memory.sh.j2").read_text()
worker = (role / "templates" / "homelab-agent-rebuild-memory.py.j2").read_text()

# A set is decrypted with an operator-supplied identity and verified first.
assert "--identity" in restore
assert "sha256sum -c SHA256SUMS" in restore
assert "age --decrypt -i" in restore

# Production restore is destructive and gated, takes a safety snapshot, then
# recreates the DB, pg_restores, hermetic-imports and health-checks.
assert "re-run with --yes" in restore
assert "safety snapshot" in restore
# Safety copies must be taken after the writers stop, with no tar warning
# accepted as a successful snapshot.
production = restore[restore.index("restore_production() {"):restore.index("write_scratch_override() {")]
assert production.index("compose stop hermes hindsight") < production.index("pg_dump -Fc")
assert "|| [ $? -eq 1 ]" not in restore
assert "DROP DATABASE IF EXISTS" in restore
# Both restore paths must authenticate as POSTGRES_USER; --role only runs
# SET ROLE after connecting and otherwise defaults to the container OS root.
commands = re.findall(r"PGPASSWORD=.*?'", restore, re.S)
restores = [command for command in commands if ' pg_restore ' in command]
assert len(restores) == 2
assert sum(" pg_dump " in command for command in commands) == 1
assert "compose exec -T memory-db pg_dump" not in restore
for command in commands:
    if re.search(r'\b(?:psql|pg_restore|pg_dump)\b', command):
        assert '-U "$POSTGRES_USER"' in command, command
for command in restores:
    assert '--exit-on-error' in command
assert 'pg_dump -Fc -U "$POSTGRES_USER"' in restore
assert "import --force" in restore
assert "homelab-agent-healthcheck" in restore
# The gateway needs a few seconds after start, so the post-restore health check
# is retried before it is allowed to fail.
assert "retrying in" in restore

# Scratch restore is isolated: a throwaway project, an override that resets the
# scratch DB, and it shares the live TEI servers over the production network.
assert "--scratch" in restore
assert "-restore-${ts,,}" in restore
assert "!reset []" in restore
assert "!override" in restore
assert "external: true" in restore
assert "production_internal" in restore
# The external network has the live memory-db alias too. Restored Hindsight
# must address ONLY the private scratch alias, and recreate the auto-init DB.
assert "@scratch-memory-db:5432/" in restore
assert "aliases: [scratch-memory-db]" in restore
assert "  scratch-hindsight:" in restore
assert "service: hindsight" in restore
assert "exec -T scratch-hindsight" in restore
assert "exec -T scratch-memory-db" in restore
scratch = restore[restore.index("restore_scratch() {"):]
assert "DROP DATABASE IF EXISTS" in scratch
# The privilege-dropped CLI must be able to read the decrypted archive.
assert 'install -m 0600 -o {{ agent_ops_uid }}' in restore
# It verifies the restore, then removes itself.
assert "total_nodes" in restore
assert "memories/recall" in restore
assert "if not isinstance(results, list) or not results:" in restore
assert "integrity_check" in restore
assert "trap on_exit EXIT" in restore

# Export is provider-independent and never destructive.
assert "sessions export" in export
assert "--format jsonl" in export
assert "export-bank" in export
assert "memories.jsonl" in export
assert "documents.jsonl" in export
assert "/memories" in export
assert "/documents" in export

# The Hindsight container is read-only with a tmpfs /tmp, so docker cp can never
# see the staged bank; it must be streamed out through exec and checked non-empty.
assert "docker cp" not in export
assert "exec -T hindsight cat" in export
assert "hindsight-bank.zip.tmp" in export

# Rebuild posts Hermes sessions into Hindsight, resumable and idempotent.
assert "--dry-run" in rebuild
assert "--entrypoint python3" in rebuild
assert "--fresh" in rebuild
# The checkpoint directory is keyed by bank + the first 16 hex digits of the
# input's SHA-256, never by the wall clock, so the same input resumes.
assert 'progress_dir="$REBUILD_DIR/${bank}-${sha16}"' in rebuild
assert 'input_sha="$(sha256sum "$input"' in rebuild
assert 'sha16="${input_sha:0:16}"' in rebuild
# The worker runs as the non-root hindsight user, so the progress dir must be
# chowned to that container user before it is mounted writable.
assert 'chown "$run_uid:$run_gid" "$progress_dir"' in rebuild
# The helper stages its own readable copy of the input in the progress dir (the
# export may be owned by the Hermes uid with a restrictive umask) and hands only
# that to the worker, so the export is mounted read-only nowhere.
assert 'install -m 0600 -o "$run_uid" -g "$run_gid"' in rebuild
assert 'input.jsonl' in rebuild
assert '--input /progress/input.jsonl' in rebuild
assert '"/input:ro"' not in rebuild
assert 'staged input copy does not match the source' in rebuild
# Conversation plaintext is not left staged after a successful rebuild.
assert 'rm -f "$staged"' in rebuild
# --fresh removes only the checkpoint, never the bank contents.
assert 'discarding saved progress' in rebuild
# The worker reproduces the production plugin's retain shape: one item (one
# document) per session, content is the flat turn-message JSON array the plugin
# builds in _build_turn_messages, posted asynchronously as an explicit replace
# and confirmed complete before the checkpoint advances.
assert "--timeout" in worker
assert "document_id" in worker
assert "progress.json" in worker
assert "save_state" in worker
assert "build_turns" in worker
assert "def build_item" in worker
assert "RETAIN_USER_PREFIX" in worker
assert "RETAIN_ASSISTANT_PREFIX" in worker
assert 'f"{RETAIN_USER_PREFIX}: {user_text}"' in worker
assert 'f"{RETAIN_ASSISTANT_PREFIX}: {assistant_text}"' in worker
assert '"conversation between Hermes Agent and the User"' in worker
assert '"shared"' in worker
assert "observation_scopes" in worker
assert '"update_mode": "replace"' in worker
assert 'json.dumps(flat, ensure_ascii=False)' in worker
# One session is one async retain request, not a batch of message items.
assert "def retain(" in worker
assert '"async": True' in worker
assert "def wait_operation" in worker
assert "/operations/" in worker
assert "batch_size" not in worker
# Timestamping must not silently fall back to the re-run time.
assert "allow-missing-timestamp" in worker
assert "no export timestamp" in worker
# The worker records the input hash and bank and refuses to reuse another
# input's progress.
assert "input_sha256" in worker
assert "file_sha256" in worker
assert 'state.get("input_sha256") != input_sha' in worker
assert 'state.get("bank") != args.bank' in worker
# The session's line is checkpointed only after its async retain completed, so
# an interrupted run never resumes past a session it did not retain.
retain_block = worker[worker.index("operation_id = retain("):]
assert retain_block.index("wait_operation(args.api, args.bank, operation_id") < \
    retain_block.index('state["last_line"] = line_number')

# No emojis anywhere in the generated helpers.
for name, text in (
    ("restore", restore),
    ("export", export),
    ("rebuild", rebuild),
    ("rebuild-worker", worker),
):
    assert not re.search(r"[\U0001F300-\U0001FAFF\u2600-\u27BF]", text), f"emoji in {name}"

# The role installs every helper with mode 0755 and both timers.
tasks = (role / "tasks" / "main.yml").read_text()
assert "homelab-agent-restore" in tasks
assert "homelab-agent-export" in tasks
assert "homelab-agent-rebuild-memory" in tasks
assert "'0755'" in tasks
PY

# Keep the provisioning OOM and EXIT-cleanup regressions on the existing CI
# restore/rebuild target as well as runnable independently.
./scripts/tests/agent-model-fetch-fixture.sh
./scripts/tests/agent-ops-cleanup-fixture.sh
./scripts/tests/agent-rebuild-fixture.sh
./scripts/tests/agent-ops-behavior-fixture.sh

echo "Agent restore/export/rebuild fixture: ok"
