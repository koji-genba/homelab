"""Regenerate constraints and the hash lock with the pinned-base Python/PM. See README.md."""

from importlib.metadata import distributions
from pathlib import Path
import re
import subprocess

from pm import uv_launcher


root = Path("/lock")
versions = {
    re.sub(r"[-_.]+", "-", dist.metadata["Name"]).lower(): dist.version
    for dist in distributions()
    if dist.metadata["Name"].lower() != "hermes-agent"
}
(root / "base-constraints.txt").write_text(
    "# All dependencies present in the pinned-base Python 3.14 venv. Do not edit by hand.\n"
    "# Regenerate: see the regenerate-requirements.py procedure in README.md.\n"
    + "".join(f"{name}=={version}\n" for name, version in sorted(versions.items()))
)
subprocess.run([
    str(uv_launcher("uv")), "pip", "compile", "--quiet", "--generate-hashes",
    "--python-version", "3.14", "--upgrade", "-c", "base-constraints.txt",
    "requirements.in", "-o", "requirements.txt",
    "--custom-compile-command", "python /lock/regenerate-requirements.py (see README.md)",
], cwd=root, check=True)
