"""固定ベースの Python/PM で制約と hash lock を再生成する。README.md 参照。"""

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
    "# 固定ベースの Python 3.14 venv に存在する全依存。手編集しない。\n"
    "# 再生成: README.md の regenerate-requirements.py 実行手順を参照。\n"
    + "".join(f"{name}=={version}\n" for name, version in sorted(versions.items()))
)
subprocess.run([
    str(uv_launcher("uv")), "pip", "compile", "--quiet", "--generate-hashes",
    "--python-version", "3.14", "--upgrade", "-c", "base-constraints.txt",
    "requirements.in", "-o", "requirements.txt",
    "--custom-compile-command", "python /lock/regenerate-requirements.py (README.md 参照)",
], cwd=root, check=True)
