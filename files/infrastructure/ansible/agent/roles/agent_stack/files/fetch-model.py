#!/usr/bin/env python3
"""Download a pinned HF snapshot without importing or starting model runtimes."""
import os
import re
import sys
from pathlib import Path

from huggingface_hub import snapshot_download


def main():
    model, revision = sys.argv[1:]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("model revision must be a full commit SHA")
    # Public model files must remain readable by the runtime TEI UID.
    os.umask(0o022)
    snapshot = Path(snapshot_download(
        repo_id=model, revision=revision, cache_dir="/data", max_workers=2,
    ))
    if snapshot.name != revision:
        raise ValueError("downloaded snapshot does not match pinned revision")
    # Atomic marker: partial transfers are retried by the Ansible role.
    marker = snapshot / ".homelab-complete"
    temporary = snapshot / ".homelab-complete.tmp"
    temporary.write_text(revision + "\n")
    os.replace(temporary, marker)
    print(f"Downloaded {model}@{revision}")


if __name__ == "__main__":
    main()
