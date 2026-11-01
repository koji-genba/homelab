"""PM が配置したツールで依存を追加し、上流の版を維持する（ビルド専用）。"""

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
# metadata のキャッシュを共有しない別プロセスで採取する。
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
    raise RuntimeError(f"上流依存の版が変更された: {changed}")
print(f"PASS: 上流依存 {len(before)} 件の版を維持")
