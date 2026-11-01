#!/usr/bin/env python3
"""ビルド済み Hermes イメージをネットワークなしで検査する。"""

from importlib.metadata import version
import inspect
from pathlib import Path
import sys
from unittest.mock import patch

import hindsight_client
from plugins.memory import import_provider_module, load_memory_provider


assert sys.version_info[:2] == (3, 14), sys.version
assert version("hindsight-client") == "0.10.2"
module = import_provider_module("hindsight")
assert module is not None
with patch.object(module, "register", wraps=module.register) as register:
    provider = load_memory_provider("hindsight", register_skills=False)
    assert provider is not None, "Hindsight provider の登録失敗"
    register.assert_called_once()
assert provider.__class__.__module__ == module.__name__
print("PASS: Python 3.14 / hindsight-client 0.10.2 / provider import・登録")

bundle = Path("/opt/hermes/apps/desktop/dist-webapp")
assert (bundle / "index.html").is_file()
assert any((bundle / "assets").glob("*.js"))
print("PASS: Webapp index.html と JavaScript bundle")

from gateway.media_fetch import _active_remote_env, fetch_remote_media
from gateway.platforms.base import _validated_delivery_path

assert "session_key" in inspect.signature(_active_remote_env).parameters
assert "session_key" in inspect.signature(fetch_remote_media).parameters
assert "session_key=session_key" in inspect.getsource(_validated_delivery_path)
print("PASS: remote MEDIA patch の引数と呼び出し")
