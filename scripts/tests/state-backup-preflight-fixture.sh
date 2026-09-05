#!/bin/sh
set -eu

# Exercise the preflight with a real age key when run in the toolbox. The
# configured SSH URL is inspected only; this fixture never contacts GitHub.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
cleanup() {
  if test -n "${SSH_AGENT_PID:-}"; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT INT TERM

remote="$fixture/remote.git"
repo="$fixture/repo"
git init -q --bare "$remote"
git init -q "$repo"
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config user.name fixture
git -C "$repo" remote add origin "$remote"
git -C "$repo" remote set-url --push origin git@github.com:koji-genba/homelab.git
git -C "$repo" commit --allow-empty -qm fixture

age-keygen -o "$fixture/identity" >"$fixture/keygen.log" 2>&1
chmod 0600 "$fixture/identity"
recipient=$(awk '/[Pp]ublic key:/ {print $NF; exit}' "$fixture/keygen.log")
test -n "$recipient"
eval "$(ssh-agent -s)" >/dev/null

AGE_RECIPIENT="$recipient" AGE_IDENTITY_FILE="$fixture/identity" \
  SSH_AUTH_SOCK="$SSH_AUTH_SOCK" STATE_BACKUP_REPO_ROOT="$repo" \
  "$repo_root/scripts/state-backup-preflight.sh"

mkdir -p "$repo/files/infrastructure/terraform/apps-vm"
printf '%s\n' '{"fixture":true}' >"$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate"
printf '%s\n' stale-backup >"$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"
chmod 0644 \
  "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate" \
  "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"
if AGE_RECIPIENT="$recipient" AGE_IDENTITY_FILE="$fixture/identity" \
  SSH_AUTH_SOCK="$SSH_AUTH_SOCK" STATE_BACKUP_REPO_ROOT="$repo" \
  "$repo_root/scripts/state-backup-preflight.sh" >"$fixture/mode.log" 2>&1; then
  echo "permissive Terraform state mode was unexpectedly accepted" >&2
  exit 1
fi
grep -q 'Terraform state must be mode 0600' "$fixture/mode.log"
chmod 0600 "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate"
chmod 0600 "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"
AGE_RECIPIENT="$recipient" AGE_IDENTITY_FILE="$fixture/identity" \
  SSH_AUTH_SOCK="$SSH_AUTH_SOCK" STATE_BACKUP_REPO_ROOT="$repo" \
  "$repo_root/scripts/state-backup-preflight.sh"
rm -f "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate"
rm -f "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"

if AGE_RECIPIENT=age1invalid AGE_IDENTITY_FILE="$fixture/identity" \
  SSH_AUTH_SOCK="$SSH_AUTH_SOCK" STATE_BACKUP_REPO_ROOT="$repo" \
  "$repo_root/scripts/state-backup-preflight.sh" >"$fixture/bad-age.log" 2>&1; then
  echo "invalid age recipient was accepted" >&2
  exit 1
fi
if AGE_RECIPIENT="$recipient" AGE_IDENTITY_FILE="$fixture/identity" \
  SSH_AUTH_SOCK="$fixture/missing.sock" STATE_BACKUP_REPO_ROOT="$repo" \
  "$repo_root/scripts/state-backup-preflight.sh" >"$fixture/bad-socket.log" 2>&1; then
  echo "invalid SSH socket was accepted" >&2
  exit 1
fi

mkdir -p "$repo/files/infrastructure/terraform/apps-vm"
printf '%s\n' '{"fixture":true}' >"$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate"
chmod 0600 "$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate"
# Force this fixture file into the index so a host/system Git ignore rule
# cannot prevent the mode-0600 tracked-state rejection from being exercised.
git -C "$repo" add -f files/infrastructure/terraform/apps-vm/terraform.tfstate
git -C "$repo" commit -qm tracked-state
if AGE_RECIPIENT="$recipient" AGE_IDENTITY_FILE="$fixture/identity" \
  SSH_AUTH_SOCK="$SSH_AUTH_SOCK" STATE_BACKUP_REPO_ROOT="$repo" \
  "$repo_root/scripts/state-backup-preflight.sh" >"$fixture/tracked.log" 2>&1; then
  echo "tracked plaintext state was accepted" >&2
  exit 1
fi
grep -q 'plaintext Terraform state is tracked' "$fixture/tracked.log" || {
  echo "tracked-state preflight log did not contain the expected rejection:" >&2
  cat "$fixture/tracked.log" >&2
  exit 1
}
echo "state-backup preflight fixture: ok"
