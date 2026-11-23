#!/usr/bin/env python3
"""Convert a Claude.ai or ChatGPT export to Hindsight rebuild JSONL offline."""

import argparse
from collections import Counter
from datetime import date, datetime, timezone
import json
from pathlib import Path
import random
import re
import tempfile


UTC = timezone.utc
OMISSION = "\n[…省略…]\n"
EXPORT_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
SECRET_PATTERNS = {
    "pem-private-key": r"-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----[\s\S]*?(?:-----END \1-----|\Z)",
    "aws-access-key": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "github-token": r"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}",
    "anthropic-key": r"\bsk-ant-[A-Za-z0-9_-]{12,}",
    "openai-key": r"\bsk-(?!ant-)[A-Za-z0-9_-]{16,}",
    "slack-token": r"\bxox[a-z]-[A-Za-z0-9-]{12,}",
    "tailscale-key": r"\btskey-[A-Za-z0-9_-]{12,}",
    "age-key": r"\bAGE-SECRET-KEY-1[0-9A-Z]{20,}\b",
    "jwt": r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
}
SECRET_PATTERNS = {kind: re.compile(pattern) for kind, pattern in SECRET_PATTERNS.items()}
BEARER = re.compile(r"\bBearer[ \t]+(?:\[REDACTED:[a-z-]+\]|[A-Za-z0-9._~+/=-]{6,})", re.I)
URL_CREDENTIALS = re.compile(
    r"(?P<scheme>\b[A-Za-z][A-Za-z0-9+.-]*://)"
    r"""[^\s/:@<>?#"']+:[^\s/@<>?#"']+(?=@)"""
)
ASSIGNMENT = re.compile(
    r"""(?P<key>(?<![\w-])(?:[\w-]+[_-])?"""
    r"""(?:password|passwd|secret|token|api[_-]?key|aws_secret_access_key)["']?[ \t]*[:=][ \t]*)"""
    r"""(?P<value>"(?:[^"\\\r\n]|\\.)*"|'(?:[^'\\\r\n]|\\.)*'|`[^`\r\n]*`"""
    r"""|(?!\[REDACTED:[a-z-]+\])[^\s"',;`<>]+)""",
    re.I,
)
REDACTED = re.compile(r"\[REDACTED:[a-z-]+\]")


def redact(text, counts):
    def marker(kind):
        counts[kind] += 1
        return f"[REDACTED:{kind}]"

    # Structured tokens get their own kind, including JWTs used as Bearer tokens.
    for kind, pattern in SECRET_PATTERNS.items():
        text = pattern.sub(lambda _: marker(kind), text)
    text = BEARER.sub(
        lambda match: match[0].split()[-1] if REDACTED.search(match[0]) else marker("bearer"),
        text,
    )
    text = URL_CREDENTIALS.sub(lambda match: match["scheme"] + marker("url-credentials"), text)

    def assignment(match):
        value = match["value"]
        quote = value[:1] if value.startswith(('"', "'", "`")) else ""
        bare = value[1:-1] if quote else value
        if not bare or REDACTED.fullmatch(bare):
            return match[0]
        return f'{match["key"]}{quote}{marker("assignment")}{quote}'

    return ASSIGNMENT.sub(assignment, text)


def timestamp(value):
    try:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return datetime.fromtimestamp(value, tz=UTC)
        if isinstance(value, str):
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
            return parsed.replace(tzinfo=parsed.tzinfo or UTC).astimezone(UTC)
    except (ValueError, OverflowError, OSError):
        pass
    return None


def as_dict(value):
    return value if isinstance(value, dict) else {}


def as_list(value):
    return value if isinstance(value, list) else []


def string(value):
    return value.strip() if isinstance(value, str) else ""


def ancestor_path(nodes, last, parent_key):
    if not isinstance(last, str) or not last or last not in nodes:
        return None
    path = []
    visited = set()
    while last is not None:
        if not isinstance(last, str) or last in visited:
            return None
        if last not in nodes:
            # Claude can point its root at a sentinel UUID absent from the export.
            break
        visited.add(last)
        node = nodes[last]
        path.append(node)
        last = node.get(parent_key)
    return list(reversed(path))


def claude_branch(conversation):
    messages = [message for message in as_list(conversation.get("chat_messages"))
                if isinstance(message, dict)]
    if not any(message.get("parent_message_uuid") for message in messages):
        return messages, 0
    nodes = {message["uuid"]: message for message in messages if isinstance(message.get("uuid"), str)}
    if len(nodes) != len(messages):
        return None, 0
    path = ancestor_path(nodes, messages[-1]["uuid"], "parent_message_uuid")
    return (path, len(messages) - len(path)) if path is not None else (None, 0)


def chatgpt_branch(conversation):
    nodes = {key: node for key, node in as_dict(conversation.get("mapping")).items()
             if isinstance(node, dict)}
    path = ancestor_path(nodes, conversation.get("current_node"), "parent")
    if path is None:
        return None, 0
    messages = [node["message"] for node in path if isinstance(node.get("message"), dict)]
    return messages, sum(isinstance(node.get("message"), dict) for node in nodes.values()) - len(messages)


def claude_text(message, include_attachment_text):
    blocks = [as_dict(block) for block in as_list(message.get("content"))]
    parts = [string(block.get("text")) for block in blocks if block.get("type") == "text"]
    parts = [part for part in parts if part] or [string(message.get("text"))]
    files = [as_dict(file) for file in as_list(message.get("files"))]
    filenames = {file["file_uuid"]: string(file.get("file_name"))
                 for file in files if isinstance(file.get("file_uuid"), str)}
    attachments = {}

    for block in blocks:
        if block.get("type") in ("image", "document"):
            file_id = string(block.get("file_uuid"))
            name = filenames.get(file_id) or string(block.get("title")) or (
                "画像" if block["type"] == "image" else "文書"
            )
            attachments.setdefault(file_id or name, name)
    for file in files:
        name = string(file.get("file_name")) or "ファイル"
        attachments.setdefault(string(file.get("file_uuid")) or name, name)

    extracted = []
    for attachment in as_list(message.get("attachments")):
        if not isinstance(attachment, dict):
            continue
        name = string(attachment.get("file_name")) or "ファイル"
        if name not in attachments.values():
            attachments[name] = name
        if include_attachment_text:
            extracted.append(string(attachment.get("extracted_content")))

    parts.extend(f"[添付: {name}]" for name in attachments.values())
    return "\n".join(part for part in parts + extracted if part)


def chatgpt_text(message):
    content = as_dict(message.get("content"))
    if content.get("content_type") not in ("text", "multimodal_text"):
        return ""
    parts = [
        "[添付: 画像]" if as_dict(part).get("content_type") == "image_asset_pointer" else string(part)
        for part in as_list(content.get("parts"))
    ]
    return "\n".join(part for part in parts if part)


def normalized_messages(path, args):
    for message in path:
        if args.source == "claude":
            sender = message.get("sender")
            if sender not in ("human", "assistant"):
                continue
            role = "user" if sender == "human" else "assistant"
            content = claude_text(message, args.include_attachment_text)
            created = timestamp(message.get("created_at"))
        else:
            role = as_dict(message.get("author")).get("role")
            if role not in ("user", "assistant") or as_dict(message.get("metadata")).get(
                "is_visually_hidden_from_conversation"
            ):
                continue
            content = chatgpt_text(message)
            created = timestamp(message.get("create_time"))
        if content:
            yield {"role": role, "content": content, "timestamp": created.isoformat() if created else None}


def complete_turns(messages, started_at, stats):
    user = None
    replies = []
    for message in messages:
        if message["role"] == "assistant":
            if user is not None:
                replies.append(message)
            continue
        if user is not None:
            yield from finish_turn(user, replies, started_at, stats)
        user, replies = message, []
    if user is not None:
        yield from finish_turn(user, replies, started_at, stats)


def finish_turn(user, replies, started_at, stats):
    if not replies:
        stats["unanswered"] += 1
    elif not (user["timestamp"] or started_at):
        stats["missing_timestamp"] += 1
    else:
        assistant = dict(replies[-1], content="\n".join(reply["content"] for reply in replies))
        yield user, assistant


def shorten(text, limit):
    if limit is None or len(text) <= limit:
        return text
    remaining = limit - len(OMISSION)
    head = (remaining + 1) // 2
    tail = remaining - head
    return text[:head] + OMISSION + text[-tail:]


def redact_turns(turns, assistant_limit):
    for user, assistant in turns:
        counts = Counter()
        user["content"] = redact(user["content"], counts)
        assistant["content"] = shorten(redact(assistant["content"], counts), assistant_limit)
        yield user, assistant, counts


def session_parts(turns, limit):
    part = []
    size = 0
    for user, assistant, counts in turns:
        turn_size = len(user["content"]) + len(assistant["content"])
        if part and limit is not None and size + turn_size > limit:
            yield part, size
            part, size = [], 0
        part.append((user, assistant, counts))
        size += turn_size
    if part:
        yield part, size


def convert(conversations, args, selected_ids):
    report = {
        "source": args.source,
        "conversations_in": len(conversations),
        "conversations_out": 0,
        "conversations_skipped": Counter(),
        "sessions_out": 0,
        "turns": 0,
        "turns_dropped": Counter(),
        "user_chars": 0,
        "assistant_chars": 0,
        "max_session_chars": 0,
        "oversize_sessions": 0,
        "branch_notes": {},
        "redactions": Counter(),
        "redactions_by_session": {},
    }
    skipped = report["conversations_skipped"]
    candidates = {}
    for conversation in conversations:
        if not isinstance(conversation, dict):
            skipped["invalid_conversation"] += 1
            continue
        if args.source == "claude":
            original_id = conversation.get("uuid")
            raw_created = conversation.get("created_at")
        else:
            original_id = conversation.get("id") or conversation.get("conversation_id")
            raw_created = conversation.get("create_time")
            if conversation.get("is_do_not_remember") is True and not args.include_do_not_remember:
                skipped["do_not_remember"] += 1
                continue
        if not isinstance(original_id, str) or not EXPORT_ID.fullmatch(original_id) or (
            redact(original_id, Counter()) != original_id
        ):
            skipped["invalid_id"] += 1
            continue
        if original_id in candidates:
            skipped["duplicate_id"] += 1
            continue
        if selected_ids is not None and original_id not in selected_ids:
            skipped["id_filter"] += 1
            continue
        created = timestamp(raw_created)
        if args.since or args.until:
            if created is None:
                skipped["missing_created_at_for_date_filter"] += 1
                continue
            if (args.since and created.date() < args.since) or (args.until and created.date() > args.until):
                skipped["date_filter"] += 1
                continue
        candidates[original_id] = (conversation, raw_created, created)

    ids = list(candidates)
    if args.sample is not None and args.sample < len(ids):
        ids = sorted(random.Random(args.seed).sample(sorted(ids), args.sample))
        skipped["sample_filter"] += len(candidates) - len(ids)

    output = []
    output_ids = set()
    branch = claude_branch if args.source == "claude" else chatgpt_branch
    for original_id in ids:
        conversation, raw_created, created = candidates[original_id]
        parent_id = f"import-{args.source}-{original_id}"
        path, excluded = branch(conversation)
        if path is None:
            skipped["invalid_branch"] += 1
            continue
        if excluded:
            report["branch_notes"][parent_id] = {"off_path_messages": excluded}
        stats = Counter()
        turns = list(complete_turns(normalized_messages(path, args), created, stats))
        report["turns_dropped"].update(stats)
        if not turns:
            skipped["no_usable_turns"] += 1
            continue
        report["conversations_out"] += 1

        title_counts = Counter()
        title = redact(string(conversation.get("name" if args.source == "claude" else "title")), title_counts)
        parts = list(session_parts(redact_turns(turns, args.assistant_max_chars), args.split_max_chars))
        for index, (part, size) in enumerate(parts, 1):
            session_id = f"{parent_id}-p{index:02d}" if len(parts) > 1 else parent_id
            if session_id in output_ids:
                raise ValueError("generated session IDs collide")
            output_ids.add(session_id)
            session = dict(id=session_id, source=args.source, title=title, messages=[])
            if created is not None:
                session.update(created_at=raw_created, started_at=created.isoformat())
            if len(parts) > 1:
                session["parent_session_id"] = parent_id
            output.append(session)

            counts = title_counts.copy()
            for user, assistant, turn_counts in part:
                session["messages"].extend((user, assistant))
                counts.update(turn_counts)
                report["user_chars"] += len(user["content"])
                report["assistant_chars"] += len(assistant["content"])
            report["redactions"].update(counts)
            report["redactions_by_session"][session_id] = counts
            report["turns"] += len(part)
            report["max_session_chars"] = max(report["max_session_chars"], size)
            if args.split_max_chars is not None and size > args.split_max_chars:
                report["oversize_sessions"] += 1
    report["sessions_out"] = len(output)
    return output, report


def paths_overlap(first, second):
    return first.resolve() == second.resolve() or (
        first.exists() and second.exists() and first.samefile(second)
    )


def write_results(output_path, report_path, sessions, report):
    # Stage both before publishing, with mode 0600 even if the files already exist.
    staged = []
    try:
        for path, records in (
            (output_path, (json.dumps(session, ensure_ascii=False, allow_nan=False) for session in sessions)),
            (report_path, [json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)]),
        ):
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as handle:
                staged.append((Path(handle.name), path))
                for record in records:
                    handle.write(record + "\n")
        for temporary, path in staged:
            temporary.replace(path)
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def positive_int(value):
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", choices=("claude", "chatgpt"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--include-attachment-text", action="store_true")
    parser.add_argument("--include-do-not-remember", action="store_true")
    parser.add_argument("--assistant-max-chars", type=positive_int, help="limit per merged reply")
    parser.add_argument("--split-max-chars", type=positive_int, help="target text size per session; keep whole turns")
    parser.add_argument("--sample", type=positive_int, help="sample this many conversations after selection filters")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--ids-file", type=Path, help="one original export ID per line")
    parser.add_argument("--since", type=date.fromisoformat, help="inclusive UTC creation date (YYYY-MM-DD)")
    parser.add_argument("--until", type=date.fromisoformat, help="inclusive UTC creation date (YYYY-MM-DD)")
    args = parser.parse_args()
    if args.since and args.until and args.since > args.until:
        parser.error("--since must be on or before --until")
    if args.assistant_max_chars is not None and args.assistant_max_chars < len(OMISSION) + 2:
        parser.error(f"--assistant-max-chars must be at least {len(OMISSION) + 2}")

    try:
        inputs = [args.input] + ([args.ids_file] if args.ids_file else [])
        if paths_overlap(args.output, args.report) or any(
            paths_overlap(path, dest) for path in inputs for dest in (args.output, args.report)
        ):
            raise ValueError("input and destination files must be distinct")
        with args.input.open(encoding="utf-8-sig") as handle:
            conversations = json.load(handle)
        if not isinstance(conversations, list):
            raise ValueError("export must be a JSON array")
        selected_ids = None
        if args.ids_file:
            selected_ids = {line.strip() for line in args.ids_file.read_text(encoding="utf-8-sig").splitlines()
                            if line.strip()}
        sessions, report = convert(conversations, args, selected_ids)
        write_results(args.output, args.report, sessions, report)
    except (OSError, UnicodeError):
        # File paths and text fragments can carry personal data.
        parser.exit(1, "Could not read or write the import files.\n")
    except json.JSONDecodeError as exc:
        parser.exit(1, f"Invalid export JSON at line {exc.lineno}, column {exc.colno}.\n")
    except ValueError as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
