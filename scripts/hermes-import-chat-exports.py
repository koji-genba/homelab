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
ATTACHMENT_READ_LIMIT = 4 * 1024 * 1024
TEXT_ATTACHMENT_TYPES = {
    "application/javascript", "application/json", "application/toml",
    "application/x-ndjson", "application/xml", "application/yaml", "application/x-yaml",
}
BINARY_ATTACHMENT_SUFFIXES = {
    ".avif", ".bmp", ".gif", ".heic", ".ico", ".jpeg", ".jpg", ".pdf",
    ".png", ".svg", ".tif", ".tiff", ".webp",
}
NON_TEXT_CONTROLS = re.compile(r"[\x00-\x08\x0b\x0e-\x1f\x7f]")
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


def text_attachment_type(mime, name):
    mime = string(mime).partition(";")[0].strip().lower()
    if Path(name).suffix.lower() in BINARY_ATTACHMENT_SUFFIXES:
        return False
    if mime in ("", "application/octet-stream"):
        return True
    return mime.startswith("text/") or mime in TEXT_ATTACHMENT_TYPES or (
        mime.startswith("application/") and mime.endswith(("+json", "+xml"))
    )


def read_attachment_text(path):
    try:
        if path.is_symlink() or not path.is_file():
            return ""
        with path.open("rb") as handle:
            data = handle.read(ATTACHMENT_READ_LIMIT + 1)
        if len(data) > ATTACHMENT_READ_LIMIT:
            return ""
        text = data.decode("utf-8-sig")
    except (OSError, UnicodeError):
        return ""
    if NON_TEXT_CONTROLS.search(text) or text.lstrip().startswith("%PDF-"):
        return ""
    return text.strip()


def chatgpt_attachments(metadata, args, asset_names):
    parts = []
    counts = Counter()
    redactions = Counter()
    for attachment in as_list(metadata.get("attachments")):
        if not isinstance(attachment, dict):
            continue
        attachment_id = string(attachment.get("id"))
        dat_name = f"{attachment_id}.dat"
        name = string(asset_names.get(dat_name)) or string(attachment.get("name")) or "ファイル"
        parts.append(f"[添付: {name}]")
        text = ""
        if args.include_attachment_text and EXPORT_ID.fullmatch(attachment_id):
            if args.attachment_text_dir:
                text = read_attachment_text(args.attachment_text_dir / f"{attachment_id}.txt")
            if not text and args.attachments_dir and text_attachment_type(attachment.get("mime_type"), name):
                text = read_attachment_text(args.attachments_dir / dat_name)
        if not text:
            counts["placeholder_only"] += 1
            continue
        counts["inlined"] += 1
        # Redact before shortening so a cut cannot expose a fragment of a secret.
        text = redact(text, redactions)
        if len(text) > args.attachment_max_chars:
            counts["truncated"] += 1
            text = shorten(text, args.attachment_max_chars)
        parts.append(text)
    return parts, counts, redactions


def normalized_messages(path, args, asset_names):
    for message in path:
        stats = {}
        if args.source == "claude":
            sender = message.get("sender")
            if sender not in ("human", "assistant"):
                continue
            role = "user" if sender == "human" else "assistant"
            content = claude_text(message, args.include_attachment_text)
            created = timestamp(message.get("created_at"))
        else:
            role = as_dict(message.get("author")).get("role")
            metadata = as_dict(message.get("metadata"))
            if role not in ("user", "assistant") or metadata.get("is_visually_hidden_from_conversation"):
                continue
            content = chatgpt_text(message)
            created = timestamp(message.get("create_time"))
            content_type = as_dict(message.get("content")).get("content_type")
            if role == "user" and metadata.get("attachments") and content_type in (None, "text", "multimodal_text"):
                parts, attachment_counts, redactions = chatgpt_attachments(metadata, args, asset_names)
                if parts:
                    content = "\n".join(filter(None, [content, *parts]))
                    stats = {"_attachments": attachment_counts, "_attachment_redactions": redactions}
        if content:
            yield dict(role=role, content=content, timestamp=created.isoformat() if created else None, **stats)


def project_materials(project, created):
    for key, label in (("description", "概要"), ("prompt_template", "プロンプトテンプレート")):
        content = string(project.get(key))
        if content:
            yield label, content, created
    for doc in as_list(project.get("docs")):
        doc = as_dict(doc)
        content = string(doc.get("content"))
        if content:
            filename = string(doc.get("filename")) or "ファイル"
            yield f"資料: {filename}", content, timestamp(doc.get("created_at")) or created


def project_turns(project, created, stats):
    name = string(project.get("name")) or "名称未設定"
    for label, content, material_time in project_materials(project, created):
        if material_time is None:
            stats["missing_timestamp"] += 1
            continue
        yield {
            "role": "user",
            "content": f"[Claude Project「{name}」の{label}]\n{content}",
            "timestamp": material_time.isoformat(),
        }, None


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
        counts = user.pop("_attachment_redactions", Counter())
        user["content"] = redact(user["content"], counts)
        if assistant is not None:
            assistant["content"] = shorten(redact(assistant["content"], counts), assistant_limit)
        yield user, assistant, counts


def session_parts(turns, limit):
    part = []
    size = 0
    for user, assistant, counts in turns:
        turn_size = len(user["content"]) + (len(assistant["content"]) if assistant is not None else 0)
        if part and limit is not None and size + turn_size > limit:
            yield part, size
            part, size = [], 0
        part.append((user, assistant, counts))
        size += turn_size
    if part:
        yield part, size


def convert(conversations, args, selected_ids, asset_names):
    projects = args.source == "claude-projects"
    source = "claude-project" if projects else args.source
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
    if args.source == "chatgpt":
        report["attachments"] = dict.fromkeys(("inlined", "placeholder_only", "truncated"), 0)
    skipped = report["conversations_skipped"]
    candidates = {}
    for conversation in conversations:
        if not isinstance(conversation, dict):
            skipped["invalid_conversation"] += 1
            continue
        if args.source != "chatgpt":
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
    branch = chatgpt_branch if args.source == "chatgpt" else claude_branch
    for original_id in ids:
        conversation, raw_created, created = candidates[original_id]
        parent_id = f"import-{source}-{original_id}"
        stats = Counter()
        if projects:
            turns = list(project_turns(conversation, created, stats))
        else:
            path, excluded = branch(conversation)
            if path is None:
                skipped["invalid_branch"] += 1
                continue
            if excluded:
                report["branch_notes"][parent_id] = {"off_path_messages": excluded}
            turns = list(complete_turns(normalized_messages(path, args, asset_names), created, stats))
        report["turns_dropped"].update(stats)
        if not turns:
            skipped["no_usable_turns"] += 1
            continue
        report["conversations_out"] += 1

        title_counts = Counter()
        title = redact(string(conversation.get("title" if args.source == "chatgpt" else "name")), title_counts)
        parts = list(session_parts(redact_turns(turns, args.assistant_max_chars), args.split_max_chars))
        for index, (part, size) in enumerate(parts, 1):
            session_id = f"{parent_id}-p{index:02d}" if len(parts) > 1 else parent_id
            if session_id in output_ids:
                raise ValueError("generated session IDs collide")
            output_ids.add(session_id)
            session = dict(id=session_id, source=source, title=title, messages=[])
            if created is not None:
                session.update(created_at=raw_created, started_at=created.isoformat())
            if len(parts) > 1:
                session["parent_session_id"] = parent_id
            output.append(session)

            counts = title_counts.copy()
            for user, assistant, turn_counts in part:
                for key, value in user.pop("_attachments", {}).items():
                    report["attachments"][key] += value
                session["messages"].append(user)
                counts.update(turn_counts)
                report["user_chars"] += len(user["content"])
                if assistant is not None:
                    session["messages"].append(assistant)
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


def read_json(path):
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def project_files(export_dir):
    projects_dir = export_dir / "projects"
    if projects_dir.is_symlink():
        raise ValueError("projects directory must not be a symlink")
    if projects_dir.is_dir():
        export_dir = projects_dir
    if not export_dir.is_dir():
        raise ValueError("project input must be a directory")
    return sorted(path for path in export_dir.glob("*.json") if not path.is_symlink() and path.is_file())


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
    parser.add_argument("--source", choices=("claude", "claude-projects", "chatgpt"), required=True)
    parser.add_argument("--input", type=Path, required=True, help="conversations.json or Claude Projects export directory")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--include-attachment-text", action="store_true")
    parser.add_argument("--attachments-dir", type=Path, help="ChatGPT export directory containing attachment .dat files")
    parser.add_argument("--attachment-text-dir", type=Path, help="ChatGPT pre-extracted UTF-8 text as <attachment-id>.txt")
    parser.add_argument("--attachment-max-chars", type=positive_int, default=64000,
                        help="limit per ChatGPT attachment after redaction (default: %(default)s)")
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
    if args.attachment_max_chars < len(OMISSION) + 2:
        parser.error(f"--attachment-max-chars must be at least {len(OMISSION) + 2}")
    if args.source != "chatgpt" and (args.attachments_dir or args.attachment_text_dir):
        parser.error("attachment directory options require --source chatgpt")

    try:
        projects = args.source == "claude-projects"
        data_files = project_files(args.input) if projects else [args.input]
        input_files = data_files + ([args.ids_file] if args.ids_file else [])
        asset_map = None
        for directory, pattern in ((args.attachments_dir, "*.dat"), (args.attachment_text_dir, "*.txt")):
            if directory:
                if not directory.is_dir():
                    raise ValueError("attachment input must be a directory")
                input_files.extend(directory.glob(pattern))
        if args.attachments_dir:
            candidate = args.attachments_dir / "conversation_asset_file_names.json"
            if not candidate.is_symlink() and candidate.is_file():
                asset_map = candidate
                input_files.append(candidate)
        if paths_overlap(args.output, args.report) or any(
            paths_overlap(path, dest) for path in input_files for dest in (args.output, args.report)
        ):
            raise ValueError("input and destination files must be distinct")
        conversations = [read_json(path) for path in data_files] if projects else read_json(args.input)
        if not isinstance(conversations, list):
            raise ValueError("export must be a JSON array")
        selected_ids = None
        if args.ids_file:
            selected_ids = {line.strip() for line in args.ids_file.read_text(encoding="utf-8-sig").splitlines()
                            if line.strip()}
        asset_names = as_dict(read_json(asset_map)) if asset_map else {}
        sessions, report = convert(conversations, args, selected_ids, asset_names)
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
