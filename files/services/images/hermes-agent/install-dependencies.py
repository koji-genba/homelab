"""Add dependencies with the tools provisioned by PM, keeping upstream versions (build-only)."""

from importlib.metadata import distributions
import json
from pathlib import Path
import re
import subprocess
import sys

from pm import uv_launcher


def inventory():
    return {
        re.sub(r"[-_.]+", "-", dist.metadata["Name"]).lower(): dist.version
        for dist in distributions()
    }


before = inventory()
uv = uv_launcher("uv")
subprocess.run([
    str(uv), "pip", "install", "--no-cache", "--require-hashes",
    "--python", sys.executable,
    "-r", str(Path(__file__).with_name("requirements.txt")),
], cwd="/tmp", check=True)
# Collect in a separate process that does not share the metadata cache.
result = subprocess.check_output([
    sys.executable, "-c",
    "import json; from importlib.metadata import distributions; import re; "
    "print(json.dumps({re.sub(r'[-_.]+', '-', d.metadata['Name']).lower(): "
    "d.version for d in distributions()}))",
], text=True)
after = json.loads(result)
changed = {name: (version, after.get(name)) for name, version in before.items()
           if after.get(name) != version}
if changed:
    raise RuntimeError(f"Upstream dependency versions changed: {changed}")
print(f"PASS: kept versions of {len(before)} upstream dependencies")
