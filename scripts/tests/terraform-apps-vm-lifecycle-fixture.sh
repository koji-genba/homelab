#!/bin/sh
set -eu

python3 <<'PY'
import pathlib
import re

main = pathlib.Path("files/infrastructure/terraform/apps-vm/main.tf").read_text()
lifecycle = re.search(
    r'resource\s+"proxmox_virtual_environment_vm"\s+"apps".*?'
    r'\n\s*lifecycle\s*\{(?P<body>.*?)\n\s*\}',
    main,
    flags=re.DOTALL,
)
assert lifecycle, "Apps VM lifecycle protection is missing"
ignore_changes = lifecycle.group("body")
assert "ignore_changes = [" in ignore_changes, "Apps VM ignore_changes is missing"
assert ignore_changes.count("initialization[0].user_data_file_id") == 1
PY

echo "Apps VM cloud-init lifecycle fixture: ok"
