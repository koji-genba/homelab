#!/bin/sh
set -eu
umask 077

repo_root=${STATE_BACKUP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
script_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
recipient=${AGE_RECIPIENT:-}
identity=${AGE_IDENTITY_FILE:-}
ssh_socket=${SSH_AUTH_SOCK:-}
test -n "$recipient" || { echo "AGE_RECIPIENT is required" >&2; exit 1; }
test -r "$identity" || { echo "AGE_IDENTITY_FILE must be readable" >&2; exit 1; }
"$script_root/check-terraform-state-modes.sh" "$repo_root"
test -S "$ssh_socket" || { echo "SSH_AUTH_SOCK must point to a live Unix socket" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "age is required" >&2; exit 1; }
git -C "$repo_root" remote get-url origin >/dev/null 2>&1 || {
  echo "repository has no origin remote" >&2
  exit 1
}

push_url=$(git -C "$repo_root" remote get-url --push origin 2>/dev/null || true)
case "$push_url" in
  ssh://*|*@*:* ) ;;
  *)
    echo "origin push URL must use SSH (configure an SSH pushurl): $push_url" >&2
    exit 1
    ;;
esac

tracked_state=$(git -C "$repo_root" ls-files | awk '/(^|\/)[^/]+\.tfstate(\.|$)/ {print}')
test -z "$tracked_state" || {
  echo "refusing to continue: plaintext Terraform state is tracked: $tracked_state" >&2
  exit 1
}

probe_dir=$(mktemp -d)
plaintext="$probe_dir/plaintext"
ciphertext="$probe_dir/ciphertext.age"
decrypted="$probe_dir/decrypted"
cleanup() { rm -rf "$probe_dir"; }
trap cleanup EXIT INT TERM
printf '%s\n' homelab-state-backup-preflight >"$plaintext"
chmod 0600 "$plaintext"
age --recipient "$recipient" --output "$ciphertext" "$plaintext"
chmod 0600 "$ciphertext"
age --decrypt --identity "$identity" "$ciphertext" >"$decrypted"
chmod 0600 "$decrypted"
cmp -s "$plaintext" "$decrypted" || {
  echo "AGE_RECIPIENT and AGE_IDENTITY_FILE failed the age roundtrip" >&2
  exit 1
}
echo "state-backup preflight: ready (SSH pushurl, age roundtrip, and plaintext-state scan passed)"
