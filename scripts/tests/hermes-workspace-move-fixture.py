#!/usr/bin/env python3
"""Exercise the canonical workspace policy edit and turn readiness offline."""

import asyncio
from dataclasses import asdict, replace
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from gateway.session_mutation_policy import prepare_workspace
from gateway.session_policy import LocalSessionPolicy, restore_policy, workspace_ready
from persistence.core.errors import AuthorityRefusal


def make_policy(cwd, **terminal):
    return LocalSessionPolicy(
        source="gui",
        platform="desktop",
        cwd=cwd,
        model=None,
        toolsets=(),
        config_json="{}",
        request_json="{}",
        terminal_json=json.dumps({"TERMINAL_CWD": cwd, **terminal}),
    )


async def move(policy, cwd):
    prepared = {"snapshot": {"receipt": {"session_id": "fixture", "policy": asdict(policy)}}}
    return await prepare_workspace(None, None, {"cwd": cwd}, prepared)


async def assert_invalid(policy, cwd):
    try:
        await move(policy, cwd)
    except AuthorityRefusal as exc:
        assert exc.reason == "invalid_params", exc
    else:
        raise AssertionError(f"Expected invalid_params for {cwd!r}")


async def main():
    runner_cwd = "/srv/agent-work/projects/x"
    assert not Path(runner_cwd).exists(), runner_cwd
    ssh = make_policy("/srv/agent-work", TERMINAL_ENV="ssh")
    with (
        patch.dict("os.environ", {"TERMINAL_ENV": "local"}),
        patch("tui_gateway.git_probe.branch", side_effect=AssertionError("host git branch probe")),
        patch("tui_gateway.git_probe.common_repo_root", side_effect=AssertionError("host git root probe")),
    ):
        for cwd in (runner_cwd, "/srv/agent-work/projects/./x"):
            result = await move(ssh, cwd)
            moved = restore_policy(result["policy"])
            assert moved.cwd == cwd
            assert json.loads(moved.terminal_json) == {"TERMINAL_ENV": "ssh", "TERMINAL_CWD": cwd}
            assert result["git"] == {"branch": None, "root": None}
            assert workspace_ready(moved), "The next turn must accept the backend workspace"
        for cwd in ("projects/x", "~/projects/x", r"C:\projects\x", "/projects/\x00x"):
            await assert_invalid(ssh, cwd)
    print("PASS: frozen SSH policy preserves an absolute Runner cwd without probing host Git")

    with TemporaryDirectory(prefix="hermes-workspace-fixture-") as local_cwd:
        local = make_policy(local_cwd, TERMINAL_ENV="local")
        mounted = make_policy(
            local_cwd, TERMINAL_ENV="docker", TERMINAL_DOCKER_MOUNT_CWD_TO_WORKSPACE="true"
        )
        with patch.dict("os.environ", {"TERMINAL_ENV": "ssh"}):
            assert workspace_ready(local)
            assert not workspace_ready(replace(local, cwd=runner_cwd))
            await assert_invalid(local, runner_cwd)
            await assert_invalid(mounted, runner_cwd)
    print("PASS: local and host-mounted Docker policies still require a real host directory")


if __name__ == "__main__":
    asyncio.run(main())
