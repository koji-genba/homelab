#!/bin/sh
set -eu

python3 <<'PY'
import pathlib

root = pathlib.Path("files/infrastructure/ansible/apps/roles/compose/templates")
reconcile = (root / "homelab-app-reconcile.sh.j2").read_text()
rollback = (root / "homelab-rollback-app.sh.j2").read_text()

force_call = 'HOMELAB_FORCE_RECREATE=true /usr/local/sbin/homelab-compose-up "$project"'
assert force_call in reconcile
assert force_call in rollback

# Keep the existing retry and rollback work-item semantics intact.
assert 'printf \'%s %s\\n\' "$new_sha" "$project" >>"$pending"' in reconcile
assert 'mv "$pending_tmp" "$pending"' in rollback
PY

echo "Compose reconcile bind-mount recreation fixture: ok"
