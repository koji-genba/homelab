#!/bin/sh
# Static + dry-run check for the rebuild worker's turn assembly. It renders the
# worker template into a temporary file (the template carries no Jinja besides a
# comment) and runs it in --dry-run against a synthetic Hermes export, so the
# turn shaping is exercised without a Hindsight server or any network.
set -eu

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

python3 - "$workdir" <<'PY'
import datetime
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import time

# Fixed offset so the emitted turn timestamps are deterministic.
os.environ["TZ"] = "UTC"
time.tzset()

work = pathlib.Path(sys.argv[1])
repo = pathlib.Path(".")
template = (
    repo
    / "files/infrastructure/ansible/agent/roles/agent_ops/templates/homelab-agent-rebuild-memory.py.j2"
).read_text()
worker = work / "worker.py"
worker.write_text(template)
subprocess.run([sys.executable, "-m", "py_compile", str(worker)], check=True)

base = datetime.datetime(2026, 3, 5, 12, 0, 0, tzinfo=datetime.timezone.utc).timestamp()


def message(role, content, timestamp, tool_calls=None, tool_name=None):
    return {
        "role": role,
        "content": content,
        "timestamp": timestamp,
        "tool_calls": tool_calls,
        "tool_name": tool_name,
    }


# One session with tool chatter and an intermediate assistant line that the final
# answer supersedes, then a user message with no assistant answer (dropped).
sess = {
    "id": "sess-1",
    "parent_session_id": "parent-1",
    "started_at": base,
    "title": "fixture",
    "messages": [
        message("user", "明日の会議は10時です", base),
        message("assistant", "", base + 1, tool_calls=[{"function": {"name": "hindsight_retain"}}]),
        message("tool", "retained", base + 2, tool_name="hindsight_retain"),
        message("assistant", "承知しました。", base + 3),
        message("user", "私の好きな色は青です", base + 100),
        message("assistant", "メモします", base + 101, tool_calls=[{"function": {"name": "memory"}}]),
        message("tool", "ok", base + 102, tool_name="memory"),
        message("assistant", "青ですね、覚えました。", base + 103),
        message("user", "ありがとう", base + 200),
    ],
}
# A second session with no timestamps at all, to exercise the missing-time count.
no_time = {
    "id": "sess-2",
    "started_at": None,
    "messages": [message("user", "時刻の無い発話", None), message("assistant", "承知しました", None)],
}

export = work / "sessions.jsonl"
export.write_text(
    "\n".join(json.dumps(s, ensure_ascii=False) for s in (sess, no_time)) + "\n",
    encoding="utf-8",
)

env = dict(os.environ, TZ="UTC")
run = subprocess.run(
    [
        sys.executable,
        str(worker),
        "--input",
        str(export),
        "--bank",
        "rebuild-fixture",
        "--state-dir",
        str(work / "state"),
        "--dry-run",
    ],
    capture_output=True,
    text=True,
    env=env,
)
assert run.returncode == 0, run.stderr
err = run.stderr
assert "sessions=2 retained=2 turns=3 messages=6" in err, err
assert "missing_timestamp_turns=1 dropped_user_turns=1" in err, err
assert "WARNING: 1 turn(s)" in err, err
assert not (work / "state" / "progress.json").exists()

spec = importlib.util.spec_from_file_location("rebuild_worker", worker)
worker_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker_mod)

turns, dropped, missing = worker_mod.build_turns(sess)
assert len(turns) == 2, turns
assert dropped == 1, dropped
assert missing == 0, missing
assert turns[0][0] == "明日の会議は10時です"
assert turns[0][1] == "承知しました。"
assert turns[1][0] == "私の好きな色は青です"
# The intermediate assistant line is superseded by the final answer.
assert turns[1][1] == "青ですね、覚えました。"

item = worker_mod.build_item(sess, turns)
assert item["document_id"] == "sess-1"
assert item["update_mode"] == "replace"
assert item["context"] == "conversation between Hermes Agent and the User"
assert item["observation_scopes"] == "shared"
assert item["tags"] == ["session:sess-1", "parent:parent-1"]
assert item["metadata"]["source"] == "hermes-session-export"
assert item["metadata"]["message_count"] == "4"
assert item["metadata"]["turn_index"] == "2"
content = json.loads(item["content"])
assert [m["role"] for m in content] == ["user", "assistant", "user", "assistant"], content
assert content[0]["content"] == "User: 明日の会議は10時です"
assert content[1]["content"] == "Assistant: 承知しました。"
assert content[2]["content"] == "User: 私の好きな色は青です"
assert content[3]["content"] == "Assistant: 青ですね、覚えました。"
# One turn's two messages share the timestamp; tool turns are absent.
assert content[0]["timestamp"] == content[1]["timestamp"]
assert content[2]["timestamp"] == content[3]["timestamp"]
assert content[0]["timestamp"] == "2026-03-05T21:00:00+09:00"
assert content[1]["timestamp"] == item["timestamp"]
assert all(m["role"] in ("user", "assistant") for m in content)

# UTC host execution still produces the configured Hermes date around midnight.
assert worker_mod._iso_timestamp("2026-03-04T15:30:00Z") == "2026-03-05T00:30:00+09:00"
assert worker_mod._iso_timestamp("2026-03-05T00:30:00") == "2026-03-05T00:30:00+09:00"
assert worker_mod._iso_timestamp(1e99) is None
assert worker_mod._session_started_at({"last_activity_at": base}) is None
# Tool-call commentary cannot become the final answer of an aborted turn.
partial = {"started_at": base, "messages": [
    message("user", "事実", base),
    message("assistant", "調べます", base+1, tool_calls=[{"id": "tool"}]),
    message("tool", "結果", base+2),
]}
assert worker_mod.build_turns(partial) == ([], 1, 0)
# Consecutive final prose: the export has no sync boundary, so keep the last
# non-tool answer; preserve all original text separately in sessions.jsonl.
partial["messages"] += [message("assistant", "前段", base+3), message("assistant", "最終", base+4)]
assert worker_mod.build_turns(partial)[0][0][1] == "最終"

# Crash during polling: the operation must be resumed without another POST.
from unittest.mock import patch
saved_argv = sys.argv
single = work / "single.jsonl"
single.write_text(json.dumps(sess)+"\n")
args = [str(worker), "--input", str(single), "--bank", "test", "--state-dir", str(work/"resume"), "--rate-limit", "0"]
with patch.object(sys, "argv", args), patch.object(worker_mod, "retain", return_value="operation-1") as post, patch.object(worker_mod, "wait_operation", side_effect=SystemExit("interrupted")):
    try:
        worker_mod.main()
    except SystemExit:
        pass
    else:
        raise AssertionError("poll interruption ignored")
    assert post.call_count == 1
statefile = work / "resume/progress.json"
state = json.loads(statefile.read_text())
assert state["last_line"] == 0 and state["pending"]["operation_id"] == "operation-1"
with patch.object(sys, "argv", args), patch.object(worker_mod, "retain") as post, patch.object(worker_mod, "wait_operation") as poll:
    worker_mod.main()
    assert not post.called
    assert poll.call_args.args[2] == "operation-1"
state = json.loads(statefile.read_text())
assert state["last_line"] == 1 and "pending" not in state
# A corrupt export line must never yield a false-success partial export.
bad = work / "bad.jsonl"
bad.write_text("{broken\n")
try:
    list(worker_mod.iter_sessions(bad))
except SystemExit:
    pass
else:
    raise AssertionError("invalid JSON silently skipped")
print("rebuild worker assembly, event timezone and operation resume: ok")
PY

echo "Agent rebuild fixture: ok"
