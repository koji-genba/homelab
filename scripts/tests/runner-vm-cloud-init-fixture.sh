#!/bin/sh
set -eu

template="files/infrastructure/terraform/runner-vm/cloud-init.yaml.tftpl"
test -f "$template"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
rendered="$tmp_dir/runner-cloud-init.yaml"

# Keep this fixture dependency-light while checking the exact cloud-config
# shape that cloud-init validates. These values mirror the Terraform defaults;
# the template itself is rendered by Terraform during the real apply.
sed \
  -e "s/\${deploy_user}/deploy/g" \
  -e "s/\${ssh_public_key}/ssh-ed25519 AAAAfixture deploy@example.invalid/g" \
  -e "s/\${vm_name}/runner/g" \
  "$template" > "$rendered"

python3 - "$rendered" <<'PY'
import pathlib
import sys

import yaml

config = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
assert config["hostname"] == "runner"
assert config["ssh_pwauth"] is False
assert config["disable_root"] is True
names = {user.get("name") for user in config["users"] if isinstance(user, dict)}
# The unprivileged hermes-runner / hermes-cdp accounts are created by Ansible,
# not cloud-init; cloud-init only seeds the operator deploy account.
assert "deploy" in names
assert "hermes-runner" not in names
assert "hermes-cdp" not in names
deploy = next(user for user in config["users"] if isinstance(user, dict) and user.get("name") == "deploy")
assert deploy["lock_passwd"] is True
assert deploy["ssh_authorized_keys"] == ["ssh-ed25519 AAAAfixture deploy@example.invalid"]
assert "password" not in pathlib.Path(sys.argv[1]).read_text().lower()
PY

if command -v cloud-init >/dev/null 2>&1; then
  cloud-init schema --config-file "$rendered" >/dev/null
fi

echo "Runner VM cloud-init fixture: ok"
