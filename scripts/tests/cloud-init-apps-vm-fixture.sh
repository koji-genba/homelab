#!/bin/sh
set -eu

template="files/infrastructure/terraform/apps-vm/cloud-init.yaml.tftpl"
test -f "$template"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
rendered="$tmp_dir/apps-cloud-init.yaml"

# Keep this fixture dependency-light while checking the exact cloud-config
# shape that cloud-init validates. These values mirror the Terraform defaults;
# the template itself is rendered by Terraform during the real apply.
sed \
  -e "s/\${deploy_user}/deploy/g" \
  -e "s/\${ssh_public_key}/ssh-ed25519 AAAAfixture deploy@example.invalid/g" \
  -e "s/\${vm_name}/apps/g" \
  "$template" > "$rendered"

python3 - "$rendered" <<'PY'
import pathlib
import sys

import yaml

config = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
assert config["hostname"] == "apps"
assert "lock_passwd" not in config
deploy = next(user for user in config["users"] if isinstance(user, dict) and user.get("name") == "deploy")
assert deploy["lock_passwd"] is True
assert deploy["ssh_authorized_keys"] == ["ssh-ed25519 AAAAfixture deploy@example.invalid"]
PY

if command -v cloud-init >/dev/null 2>&1; then
  cloud-init schema --config-file "$rendered" >/dev/null
fi

echo "Apps VM cloud-init fixture: ok"
