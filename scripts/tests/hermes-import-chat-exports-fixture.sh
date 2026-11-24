#!/bin/sh
# Convert synthetic exports and pass the result to the real rebuild worker.
set -eu

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

python3 - "$workdir" <<'PY'
from collections import Counter
import datetime
import json
from pathlib import Path
import runpy
import stat
import subprocess
import sys

work = Path(sys.argv[1])
converter = Path("scripts/hermes-import-chat-exports.py")
worker = Path("files/infrastructure/ansible/agent/roles/agent_ops/templates/homelab-agent-rebuild-memory.py.j2")
helper = runpy.run_path(str(worker))


def convert(source, data, *options):
    output_file, report_file = work / "sessions.jsonl", work / "report.json"
    if isinstance(data, Path):
        input_file = data
    else:
        input_file = work / "export.json"
        input_file.write_text(json.dumps(data), encoding="utf-8")
    result = subprocess.run([
        sys.executable, "-I", str(converter),
        "--source", source, "--input", str(input_file),
        "--output", str(output_file), "--report", str(report_file), *options,
    ], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout == result.stderr == ""
    for path in (output_file, report_file):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    sessions = list(map(json.loads, output_file.read_text(encoding="utf-8").splitlines()))
    report = json.loads(report_file.read_text(encoding="utf-8"))
    assert report["conversations_in"] == report["conversations_out"] + sum(report["conversations_skipped"].values())
    assert report["sessions_out"] == len(sessions)
    counts = Counter()
    for session_counts in report["redactions_by_session"].values():
        counts.update(session_counts)
    assert dict(counts) == report["redactions"]
    return sessions, report


def check_worker(sessions, report):
    result = subprocess.run([
        sys.executable, "-I", str(worker), "--input", str(work / "sessions.jsonl"),
        "--bank", "fixture", "--dry-run", "--state-dir", str(work / "state"),
    ], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    messages = sum(len(session["messages"]) for session in sessions)
    assert f"retained={len(sessions)} turns={report['turns']} messages={messages}" in result.stderr, result.stderr
    assert "missing_timestamp_turns=0 dropped_user_turns=0" in result.stderr
    assert not (work / "state/progress.json").exists()
    user_chars = assistant_chars = max_size = 0
    items = []
    for session in sessions:
        turns, dropped, missing = helper["build_turns"](session)
        assert not dropped and not missing and turns
        users = sum(len(user) for user, _, _ in turns)
        assistants = sum(len(assistant or "") for _, assistant, _ in turns)
        user_chars += users
        assistant_chars += assistants
        max_size = max(max_size, users + assistants)
        item = helper["build_item"](session, turns)
        assert item["document_id"] == session["id"]
        assert item["update_mode"] == "replace"
        assert item["metadata"]["source"] == session["source"]
        assert item["metadata"]["title"] == session["title"]
        if "created_at" in session:
            assert item["metadata"]["created_at"] == str(session["created_at"])
        assert item["tags"] == [
            f"session:{session['id']}",
            *([f"parent:{session['parent_session_id']}"] if "parent_session_id" in session else []),
            f"source:{session['source']}",
        ]
        items.append(item)
    assert user_chars == report["user_chars"]
    assert assistant_chars == report["assistant_chars"]
    assert max_size == report["max_session_chars"]
    return items


iso_time = "2025-06-16T03:50:11.239134Z"
epoch = datetime.datetime.fromisoformat("2025-06-16T03:50:11.239134+00:00").timestamp()
claude_root = "00000000-0000-4000-8000-000000000000"


def claude_message(uuid, parent, sender, text="", **fields):
    return dict(uuid=uuid, parent_message_uuid=parent, sender=sender, text=text, **fields)


claude = {
    "uuid": "00000000-0000-4000-8000-000000000001",
    "name": "架空の図 token=fixture-title",
    "created_at": iso_time,
    "chat_messages": [
        claude_message("user", claude_root, "human", "ignored fallback", content=[
            {"type": "text", "text": "猫が好きです"},
            {"type": "text", "text": "絵を見てください"},
            {"type": "image", "file_uuid": "image"},
            {"type": "document", "file_uuid": "doc", "title": "架空の資料"},
            *[{"type": kind, "text": "private block"} for kind in (
                "thinking", "tool_use", "tool_result", "token_budget", "flag", "injected_prompt_block"
            )],
        ], files=[{"file_uuid": "image", "file_name": "猫.png"}, {"file_name": "別紙.txt"}],
            attachments=[{"file_name": "猫.png", "extracted_content": "fixture OCR api_key=fixture-ocr"}]),
        claude_message("alternate", "user", "assistant", "inactive answer"),
        claude_message("segment", "user", "assistant", "前半", content=[{"type": "thinking"}]),
        claude_message("final", "segment", "assistant", content=[{"type": "text", "text": "後半"}]),
        claude_message("empty", "final", "human", "  "),
        claude_message("other", "empty", "human", "もう一つ"),
        claude_message("other-reply", "other", "assistant", "答え"),
        claude_message("unanswered", "other-reply", "human", "未回答"),
    ],
}
sessions, report = convert("claude", [claude])
parent = f"import-claude-{claude['uuid']}"
assert report["branch_notes"] == {parent: {"off_path_messages": 1}}
assert report["turns_dropped"] == {"unanswered": 1}
assert report["redactions"] == {"assignment": 1}
assert sessions[0]["messages"][0]["content"] == (
    "猫が好きです\n絵を見てください\n[添付: 猫.png]\n[添付: 架空の資料]\n[添付: 別紙.txt]"
)
assert sessions[0]["messages"][1]["content"] == "前半\n後半"
items = check_worker(sessions, report)
assert items[0]["context"] == "conversation between Claude.ai and the User"
assert items[0]["timestamp"] == "2025-06-16T12:50:11+09:00"

sessions, report = convert("claude", [claude], "--include-attachment-text", "--split-max-chars", "15")
assert [session["id"] for session in sessions] == [f"{parent}-p01", f"{parent}-p02"]
assert all(session["parent_session_id"] == parent for session in sessions)
assert report["oversize_sessions"] == 1
assert "fixture OCR api_key=[REDACTED:assignment]" in sessions[0]["messages"][0]["content"]
assert "fixture-ocr" not in json.dumps(sessions)
check_worker(sessions, report)

# A linear sentinel-rooted conversation and an edit that forks at the root.
root_turn = [
    claude_message("edited", claude_root, "human", "編集後の質問"),
    claude_message("edited-reply", "edited", "assistant", "編集後の回答"),
]
linear = dict(claude, uuid="fixture-claude-linear", chat_messages=root_turn)
root_fork = dict(claude, uuid="fixture-claude-root-fork", chat_messages=[
    claude_message("original", claude_root, "human", "編集前の質問"),
    claude_message("original-reply", "original", "assistant", "編集前の回答"),
    *root_turn,
])
claude_cycle = dict(claude, uuid="fixture-claude-cycle", chat_messages=[
    claude_message("u", "a", "human", "循環した質問"),
    claude_message("a", "u", "assistant", "循環した回答"),
])
sessions, report = convert("claude", [linear, root_fork, claude_cycle])
assert report["conversations_skipped"] == {"invalid_branch": 1}
assert report["branch_notes"] == {"import-claude-fixture-claude-root-fork": {"off_path_messages": 2}}
assert [session["id"] for session in sessions] == [
    "import-claude-fixture-claude-linear", "import-claude-fixture-claude-root-fork",
]
for session in sessions:
    assert [message["content"] for message in session["messages"]] == ["編集後の質問", "編集後の回答"]
check_worker(sessions, report)

project_export = work / "claude-export"
projects_dir = project_export / "projects"
projects_dir.mkdir(parents=True)
project = {
    "uuid": "fixture-project",
    "name": "架空のプロジェクト",
    "created_at": iso_time,
    "description": "概要の本文",
    "prompt_template": "文体は簡潔に",
    "docs": [
        {"uuid": "empty-doc", "filename": "空.txt", "content": "  "},
        {"uuid": "real-doc", "filename": "猫.txt", "content": "猫が好きです\napi_key=fixture-project-key",
         "created_at": "2025-07-01T01:02:03Z"},
        {"uuid": "undated-doc", "filename": "予備.txt", "content": "会話開始時刻へフォールバック"},
    ],
}
(projects_dir / "project.json").write_text(json.dumps(project), encoding="utf-8")
(projects_dir / "empty.json").write_text(json.dumps(
    dict(project, uuid="empty-project", description="", prompt_template="", docs=[project["docs"][0]]),
), encoding="utf-8")
sessions, report = convert("claude-projects", project_export)
assert sessions[0]["id"] == "import-claude-project-fixture-project"
assert report["conversations_skipped"] == {"no_usable_turns": 1}
assert report["turns"] == 4 and report["assistant_chars"] == 0
assert report["redactions"] == {"assignment": 1}
assert "fixture-project-key" not in json.dumps(sessions)
item, = check_worker(sessions, report)
assert item["context"] == "project materials provided by the User in Claude.ai Projects"
assert item["metadata"]["message_count"] == "4"
project_messages = json.loads(item["content"])
assert all(message["role"] == "user" for message in project_messages)
assert [message["content"] for message in project_messages] == [
    "User: [Claude Project「架空のプロジェクト」の概要]\n概要の本文",
    "User: [Claude Project「架空のプロジェクト」のプロンプトテンプレート]\n文体は簡潔に",
    "User: [Claude Project「架空のプロジェクト」の資料: 猫.txt]\n猫が好きです\napi_key=[REDACTED:assignment]",
    "User: [Claude Project「架空のプロジェクト」の資料: 予備.txt]\n会話開始時刻へフォールバック",
]
assert [message["timestamp"] for message in project_messages] == [
    "2025-06-16T12:50:11+09:00", "2025-06-16T12:50:11+09:00",
    "2025-07-01T10:02:03+09:00", "2025-06-16T12:50:11+09:00",
]
sessions, report = convert("claude-projects", projects_dir, "--split-max-chars", "45")
assert [session["id"] for session in sessions] == [f"import-claude-project-fixture-project-p{i:02d}" for i in range(1, 5)]
assert all(session["parent_session_id"] == "import-claude-project-fixture-project" for session in sessions)
check_worker(sessions, report)


# These strings use fixture-only payloads with the requested credential shapes.
credentials = {
    # Split the PEM header so the repo secret scan does not match this fixture.
    "pem-private-key": "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nfixture PEM body\n-----END OPENSSH " + "PRIVATE KEY-----",
    "aws-access-key": "AKIA" + "0" * 16,
    "github-token": "ghp_" + "fixture0" * 5,
    "anthropic-key": "sk-ant-" + "fixture0" * 5,
    "openai-key": "sk-" + "fixture0" * 5,
    "slack-token": "xoxb-00000000-fixture",
    "tailscale-key": "tskey-" + "auth-fixture-fixture",
    "age-key": "AGE-SECRET-KEY-1" + "0" * 24,
    "jwt": "eyJmaXh0dXJlIn0.YWJj.ZGVm",
    "bearer": "Bearer abcdefghfixture",
    "url-credentials": "fakeuser:fixture-pass",
    "assignment": "fixture multi word password",
}
additional = ["gho_" + "fixture0" * 5, "github_pat_" + "fixture0" * 5]
fixture_text = "I forgot my password.\n" + "\n".join([
    *list(credentials.values())[:-2], *additional,
    f"https://{credentials['url-credentials']}@example.invalid/path",
    f'"passwd": "{credentials["assignment"]}"',
])


def node(parent, role, *parts, kind="text", hidden=False):
    return {
        "parent": parent,
        "message": {
            "author": {"role": role},
            "create_time": epoch + 1,
            "content": {"content_type": kind, "parts": parts},
            "metadata": {"is_visually_hidden_from_conversation": hidden},
        },
    }


chatgpt = {
    "id": "fixture-chat",
    "title": "架空のChatGPT会話",
    "create_time": epoch,
    "current_node": "answer",
    "mapping": {
        "root": {"parent": None, "message": None},
        "system": node("root", "system", "system hidden"),
        "user": node("system", "user", fixture_text, {"content_type": "image_asset_pointer",
                     "asset_pointer": "ignored-image"}, "second part", kind="multimodal_text"),
        "inactive": node("user", "assistant", "inactive answer"),
        "thought": node("user", "assistant", "thinking hidden", kind="thoughts"),
        "preface": node("thought", "assistant", "Start of answer"),
        "tool": node("preface", "tool", "tool hidden"),
        "hidden": node("tool", "user", "visually hidden", hidden=True),
        "recap": node("hidden", "assistant", "recap hidden", kind="reasoning_recap"),
        "answer": node("recap", "assistant", "middle " * 15, "end of answer"),
    },
}
private = dict(chatgpt, id="fixture-private", is_do_not_remember=True)
cycle = dict(chatgpt, id="fixture-cycle", current_node="loop",
             mapping={"loop": {"parent": "loop"}})
missing_time = dict(chatgpt, id="fixture-no-time", create_time=None, current_node="a", mapping={
    "u": node(None, "user", "uncertain date"),
    "a": node("u", "assistant", "ok"),
})
missing_time["mapping"]["u"]["message"]["create_time"] = None
sessions, report = convert("chatgpt", [chatgpt, private, cycle, missing_time])
assert report["conversations_skipped"] == {"do_not_remember": 1, "invalid_branch": 1, "no_usable_turns": 1}
assert report["turns_dropped"] == {"missing_timestamp": 1}
assert report["branch_notes"] == {"import-chatgpt-fixture-chat": {"off_path_messages": 1}}
user, answer = [message["content"] for message in sessions[0]["messages"]]
assert user.startswith("I forgot my password.")
assert user.endswith("[添付: 画像]\nsecond part")
assert "https://[REDACTED:url-credentials]@example.invalid/path" in user
assert answer == "Start of answer\n" + "middle " * 14 + "middle\nend of answer"
for kind, value in credentials.items():
    assert f"[REDACTED:{kind}]" in user, kind
    assert value not in user and value not in json.dumps(report), kind
assert report["redactions"] == dict.fromkeys(credentials, 1) | {"github-token": 3}
for rejected in [*additional, "inactive answer", "system hidden", "thinking hidden", "tool hidden",
                 "visually hidden", "recap hidden", "ignored-image", "Start of answer"]:
    assert rejected not in user and rejected not in json.dumps(report)
assert check_worker(sessions, report)[0]["context"] == "conversation between ChatGPT and the User"

# A dangling parent ends the path, but the current node itself must exist.
dangling = dict(chatgpt, id="fixture-dangling-parent", mapping=dict(
    chatgpt["mapping"], system=dict(chatgpt["mapping"]["system"], parent="missing-root"),
))
missing_current = dict(chatgpt, id="fixture-missing-current", current_node="missing-node")
dangling_sessions, dangling_report = convert("chatgpt", [dangling, missing_current])
assert dangling_report["conversations_skipped"] == {"invalid_branch": 1}
assert dangling_report["branch_notes"] == {"import-chatgpt-fixture-dangling-parent": {"off_path_messages": 1}}
assert dangling_sessions[0]["id"] == "import-chatgpt-fixture-dangling-parent"
assert dangling_sessions[0]["messages"] == sessions[0]["messages"]
check_worker(dangling_sessions, dangling_report)

id_file = work / "ids.txt"
id_file.write_text("fixture-chat\nfixture-private\nfixture-old\n")
old = dict(chatgpt, id="fixture-old", create_time=epoch - 86400)
other = dict(chatgpt, id=None, conversation_id="fixture-other")
options = ("--include-do-not-remember", "--assistant-max-chars", "36", "--ids-file", str(id_file),
           "--since", "2025-06-16", "--until", "2025-06-16", "--sample", "1", "--seed", "7")
sessions, report = convert("chatgpt", [chatgpt, private, old, other], *options)
assert (sessions, report) == convert("chatgpt", [other, old, private, chatgpt], *options)
assert [session["id"] for session in sessions] == ["import-chatgpt-fixture-private"]
assert report["conversations_skipped"] == {"date_filter": 1, "id_filter": 1, "sample_filter": 1}
answer = sessions[0]["messages"][1]["content"]
assert len(answer) == 36 and answer.startswith("Start of") and answer.endswith("end of answer")
assert "[…省略…]" in answer
check_worker(sessions, report)
assert convert("chatgpt", [other])[0][0]["id"] == "import-chatgpt-fixture-other"

# Redact both credential shapes and assignment values before reply shortening.
reply_with_secrets = dict(chatgpt, mapping=dict(chatgpt["mapping"], answer=node(
    "recap", "assistant", "end of answer\nDB_PASSWORD=`fixture-db-pass`\n"
    "token=fixture-[token]\nBearer abc123\n" + "x" * 80,
)))
sessions, report = convert("chatgpt", [reply_with_secrets], "--assistant-max-chars", "36")
assert report["redactions"]["assignment"] == 3 and report["redactions"]["bearer"] == 2
assert "fixture-db-pass" not in json.dumps(sessions)
check_worker(sessions, report)

assets = work / "chatgpt-assets"
extracted = work / "pre-extracted"
assets.mkdir()
extracted.mkdir()
(assets / "conversation_asset_file_names.json").write_text(json.dumps({
    "note.dat": "記録", "scan.dat": "スキャン.pdf", "image.dat": "写真.png",
}), encoding="utf-8")
(assets / "note.dat").write_text(
    "テキストの先頭\npassword=fixture-attachment-pass\n" + "中" * 80 + "\nテキストの末尾", encoding="utf-8",
)
(assets / "plain.dat").write_text("raw text superseded by supplied text", encoding="utf-8")
(extracted / "plain.txt").write_text("preferred supplied text", encoding="utf-8")
(assets / "scan.dat").write_bytes(b"%PDF-1.7 binary PDF fixture")
(assets / "image.dat").write_bytes(b"untrusted image bytes")
(assets / "invalid.dat").write_bytes(b"\xff\xfe\x00")
(assets / "large.dat").write_bytes(b"x" * (4 * 1024 * 1024 + 1))
(extracted / "scan.txt").write_text("PDFから抽出した本文", encoding="utf-8")
(work / "outside.txt").write_text("must never be read as an attachment", encoding="utf-8")

attachment_user = node(None, "user", kind="multimodal_text")
attachment_user["message"]["metadata"]["attachments"] = [
    {"id": "note", "name": "original-name.dat", "mime_type": "application/octet-stream"},
    {"id": "plain", "name": "plain.txt", "mime_type": "text/plain; charset=utf-8"},
    {"id": "scan", "mime_type": "application/pdf"},
    {"id": "image", "mime_type": "image/png"},
    {"id": "invalid", "name": "invalid.txt", "mime_type": "text/plain"},
    {"id": "large", "name": "large.txt", "mime_type": "text/plain"},
    {"id": "missing", "name": "missing.txt", "mime_type": "text/plain"},
    {"id": "../outside", "name": "unsafe ID.txt", "mime_type": "text/plain"},
]
attachment_chat = dict(chatgpt, id="fixture-attachments", current_node="a", mapping={
    "u": attachment_user, "a": node("u", "assistant", "受け取りました"),
})
dirs = ("--attachments-dir", str(assets), "--attachment-text-dir", str(extracted))
sessions, report = convert("chatgpt", [attachment_chat], *dirs)
assert report["attachments"] == {"inlined": 0, "placeholder_only": 8, "truncated": 0}
assert "[添付: 記録]" in sessions[0]["messages"][0]["content"]
assert "PDFから抽出した本文" not in sessions[0]["messages"][0]["content"]
check_worker(sessions, report)

sessions, report = convert("chatgpt", [attachment_chat], *dirs, "--include-attachment-text")
assert report["attachments"] == {"inlined": 3, "placeholder_only": 5, "truncated": 0}
user_text = sessions[0]["messages"][0]["content"]
assert "[添付: 記録]\nテキストの先頭\npassword=[REDACTED:assignment]" in user_text
assert "[添付: plain.txt]\npreferred supplied text" in user_text
assert "[添付: スキャン.pdf]\nPDFから抽出した本文\n[添付: 写真.png]" in user_text
assert all(text not in user_text for text in (
    "fixture-attachment-pass", "raw text superseded", "binary PDF fixture", "untrusted image bytes", "must never be read",
))
assert report["redactions"] == {"assignment": 1}
check_worker(sessions, report)

sessions, report = convert("chatgpt", [attachment_chat], *dirs, "--include-attachment-text", "--attachment-max-chars", "28")
assert report["attachments"] == {"inlined": 3, "placeholder_only": 5, "truncated": 1}
inlined_note = sessions[0]["messages"][0]["content"].split("[添付: 記録]\n")[1].split("\n[添付: plain.txt]")[0]
assert len(inlined_note) == 28 and inlined_note.endswith("テキストの末尾") and "[…省略…]" in inlined_note
assert report["redactions"] == {"assignment": 1}
check_worker(sessions, report)

print("Hermes chat export fixture: ok")
PY
