#!/bin/sh
set -eu
umask 077
repo_root=${STATE_SYNC_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
script_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
case ${STATE_SYNC:-} in
  skip) echo 'WARNING: STATE_SYNC=skip: using local state without remote synchronization' >&2; exit 0 ;;
  '') ;;
  *) echo 'STATE_SYNC must be empty or skip' >&2; exit 1 ;;
esac
test -r "${AGE_IDENTITY_FILE:-}" || {
  echo 'AGE_IDENTITY_FILE must be readable for state sync (plan also needs the age identity recovered from KeePassXC)' >&2
  exit 1
}
"$script_root/check-terraform-state-modes.sh" "$repo_root"
git -C "$repo_root" fetch --no-tags origin \
  '+refs/heads/state-backup:refs/remotes/origin/state-backup' >/dev/null 2>&1 || {
  echo 'unable to fetch origin/state-backup; refusing sync (explicit offline escape: STATE_SYNC=skip)' >&2
  exit 1
}
temporary=$(mktemp -d "$repo_root/files/infrastructure/terraform/.terraform.tfstate.sync.XXXXXX")
chmod 0700 "$temporary"
cleanup() { rm -rf "$temporary"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 "$script_root/state-files.py" sync "$repo_root" "$temporary" "$AGE_IDENTITY_FILE"
