#!/usr/bin/env python3
"""Exercise the image's remote MEDIA delivery without SSH or network access.

Run from the repo root after building homelab-hermes-agent:remote-media-test:
  docker run --rm -i --network none --entrypoint python \
    homelab-hermes-agent:remote-media-test - < scripts/tests/hermes-remote-media-fixture.py
"""

import os
from pathlib import Path
import tempfile
from unittest.mock import patch


class RemoteEnv:
    _remote_home = "/home/hermes-runner"
    payload = b"\x89PNG\r\n\x1a\nremote-media-fixture"

    def __init__(self):
        self.resolved = None
        self.reads = []

    def fetch_realpath(self, path):
        self.reads.append(("realpath", path))
        return self.resolved or path

    def fetch_file(self, path, dest, *, max_bytes):
        assert max_bytes >= len(self.payload)
        self.reads.append(("file", path))
        Path(dest).write_bytes(self.payload)


def check_delivery():
    from gateway.config import Platform
    from gateway.media_fetch import _active_remote_env, fetch_remote_media
    from gateway.platforms.base import DOCUMENT_CACHE_DIR, _validated_delivery_path
    from gateway.session import SessionSource, build_session_key
    from gateway.session_context import clear_session_vars, get_session_env, set_session_vars
    from tools.terminal_tool import _active_environments, _resolve_container_task_id

    source = SessionSource(platform=Platform.DISCORD, chat_type="thread",
                           chat_id="chat", thread_id="thread", user_id="user")
    key = build_session_key(source, thread_sessions_per_user=True)
    assert key == "agent:main:discord:thread:chat:thread:user"
    remote_path = "/srv/agent-work/x.png"
    env = RemoteEnv()
    assert not _active_environments
    _active_environments[f"session:{key}"] = env
    try:
        # No session ContextVar has been set: this is the post-handler failure case.
        assert not get_session_env("HERMES_SESSION_KEY")
        assert not get_session_env("HERMES_SESSION_ID")
        assert _resolve_container_task_id(key) == "default"
        assert fetch_remote_media(remote_path) is None
        assert _validated_delivery_path(remote_path, "", "MEDIA fixture") is None
        assert _validated_delivery_path(remote_path, key + ":missing", "MEDIA fixture") is None
        assert not env.reads

        delivered = _validated_delivery_path(remote_path, key, "MEDIA fixture")
        assert delivered is not None
        assert Path(delivered).parent == Path(DOCUMENT_CACHE_DIR)
        assert Path(delivered).read_bytes() == env.payload
        assert env.reads == [("realpath", remote_path), ("file", remote_path)]
        print("PASS: no context + explicit session key -> document cache; missing/wrong key -> None")

        # A live context remains authoritative over the delivery fallback.
        other = RemoteEnv()
        context_key = key + ":context"
        _active_environments[f"session:{context_key}"] = other
        tokens = set_session_vars(session_key=context_key, session_id="fixture-turn")
        try:
            assert _resolve_container_task_id("fixture-turn") == f"session:{context_key}"
            assert _active_remote_env(session_key=key) is other
            assert Path(fetch_remote_media(remote_path)).read_bytes() == other.payload
        finally:
            clear_session_vars(tokens)
        print("PASS: context lookup retains priority and works without an explicit key")

        env.reads.clear()
        for settings in ({"HERMES_MEDIA_DELIVERY_STRICT": "1"}, {"TERMINAL_ENV": "local"}):
            with patch.dict(os.environ, settings):
                assert _validated_delivery_path(remote_path, key, "MEDIA fixture") is None
        for denied in ("/etc/shadow", env._remote_home + "/.ssh/id_ed25519"):
            assert _validated_delivery_path(denied, key, "MEDIA fixture") is None
        assert not env.reads
        env.resolved = "/etc/shadow"
        assert _validated_delivery_path(remote_path, key, "MEDIA fixture") is None
        assert env.reads == [("realpath", remote_path)]
        env.reads.clear()
        with patch.dict(os.environ, {"TERMINAL_ENV": "local"}):
            assert _validated_delivery_path(delivered, key, "MEDIA fixture") == delivered
        assert not env.reads
        print("PASS: strict mode, local backend, denylist and symlink target checks retained")
    finally:
        _active_environments.clear()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="hermes-media-fixture-") as home:
        for name in tuple(os.environ):
            if name.startswith("HERMES_SESSION_"):
                os.environ.pop(name)
        os.environ.update(HERMES_HOME=home, TERMINAL_ENV="ssh", HERMES_MEDIA_DELIVERY_STRICT="0")
        check_delivery()
