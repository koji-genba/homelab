#!/bin/sh
set -eu
umask 077

repo_root=${STATE_BACKUP_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
script_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
push=${STATE_BACKUP_PUSH:-1}
if [ "${1:-}" = "--push" ]; then
  push=1
  shift
elif [ "${1:-}" = "--no-push" ]; then
  push=0
  shift
fi
test $# -eq 0 || { echo "usage: $0 [--push|--no-push]" >&2; exit 2; }
command -v age >/dev/null 2>&1 || { echo "age is required" >&2; exit 1; }
recipient=${AGE_RECIPIENT:-}
identity=${AGE_IDENTITY_FILE:-}
test -n "$recipient" || { echo "AGE_RECIPIENT must contain an age public recipient" >&2; exit 1; }
test -r "$identity" || { echo "age identity missing or unreadable: restore ~/.config/sops/age/keys.txt from KeePassXC or set AGE_IDENTITY_FILE" >&2; exit 1; }

"$script_root/check-terraform-state-modes.sh" "$repo_root"

tracked_state=$(git -C "$repo_root" ls-files | awk '/(^|\/)[^/]+\.tfstate(\.|$)/ {print}')
test -z "$tracked_state" || { echo "refusing to continue: state is tracked: $tracked_state" >&2; exit 1; }

worktree=$(mktemp -d)
scratch=$(mktemp -d)
chmod 0700 "$scratch"
state_list="$scratch/state-list"
cleanup() {
  rm -rf "$scratch"
  git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  rmdir "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git -C "$repo_root" fetch --no-tags origin state-backup:refs/remotes/origin/state-backup >/dev/null 2>&1 || true
git -C "$repo_root" worktree add --detach "$worktree" HEAD >/dev/null

local_ref=refs/heads/state-backup
remote_ref=refs/remotes/origin/state-backup
if git -C "$repo_root" show-ref --verify --quiet "$local_ref"; then
  local_exists=1
else
  local_exists=0
fi
if git -C "$repo_root" show-ref --verify --quiet "$remote_ref"; then
  remote_exists=1
else
  remote_exists=0
fi

if test "$local_exists" -eq 1 && test "$remote_exists" -eq 1; then
  # Keep an existing local commit when it is ahead of the fetched remote, but
  # move a stale local branch to the fetched remote when the remote is ahead.
  # A diverged branch is never silently overwritten: an operator must resolve
  # it explicitly before another encrypted backup can be produced.
  if git -C "$repo_root" merge-base --is-ancestor "$local_ref" "$remote_ref"; then
    backup_base=$remote_ref
  elif git -C "$repo_root" merge-base --is-ancestor "$remote_ref" "$local_ref"; then
    backup_base=$local_ref
  else
    echo "refusing diverged state-backup branches; resolve $local_ref and $remote_ref explicitly" >&2
    exit 1
  fi
  git -C "$worktree" checkout -B state-backup "$backup_base" >/dev/null
elif test "$local_exists" -eq 1; then
  git -C "$worktree" checkout -B state-backup "$local_ref" >/dev/null
elif test "$remote_exists" -eq 1; then
  git -C "$worktree" checkout -B state-backup "$remote_ref" >/dev/null
else
  git -C "$worktree" checkout --orphan state-backup >/dev/null
  git -C "$worktree" rm -rf . >/dev/null 2>&1 || true
fi

find "$repo_root/files/infrastructure/terraform" -type f -name '*.tfstate' -print >"$state_list"
test -s "$state_list" || {
  echo "no local Terraform state found; nothing to back up" >&2
  exit 1
}
mkdir -p "$worktree/terraform-state"

# Keep a ciphertext whose verified plaintext is unchanged. age intentionally
# uses randomized encryption, so encrypting every run would create needless
# state-backup commits.
while IFS= read -r state; do
  python3 "$script_root/state-files.py" check "$state"
  relative=${state#"$repo_root/"}
  destination="$worktree/terraform-state/$relative.age"
  mkdir -p "$(dirname "$destination")"
  decrypted=$(mktemp "$scratch/plaintext.XXXXXX")
  keep=0
  if test -r "$destination"; then
    if ! age --decrypt --identity "$identity" "$destination" >"$decrypted" 2>/dev/null; then
      rm -f "$decrypted"
      echo "refusing to replace unreadable backup: $relative" >&2
      exit 1
    fi
    if ! python3 "$script_root/state-files.py" publish-check "$state" "$decrypted"; then
      rm -f "$decrypted"
      exit 1
    fi
    if cmp -s "$state" "$decrypted"; then keep=1; fi
  fi
  rm -f "$decrypted"
  if test "$keep" -eq 0; then
    encrypted="$destination.new.$$"
    age --recipient "$recipient" --output "$encrypted" "$state"
    mv -f "$encrypted" "$destination"
  fi
  decrypted=$(mktemp "$scratch/plaintext.XXXXXX")
  age --decrypt --identity "$identity" "$destination" >"$decrypted"
  cmp -s "$state" "$decrypted" || {
    rm -f "$decrypted"
    echo "encrypted state failed decrypt verification: $relative" >&2
    exit 1
  }
  rm -f "$decrypted"
done <"$state_list"

# Preserve backup-only roots. Removing a local file is not authorization to
# delete canonical state belonging to another Terraform root/workstation.

git -C "$worktree" add -A terraform-state
if git -C "$worktree" diff --cached --quiet; then
  commit=$(git -C "$worktree" rev-parse HEAD)
  echo "state-backup unchanged at $commit"
else
  git -C "$worktree" -c user.name=homelab-state-backup \
    -c user.email=homelab-state-backup@localhost \
    commit -m "chore: update encrypted Terraform state backup" >/dev/null
  commit=$(git -C "$worktree" rev-parse HEAD)
  echo "state-backup branch updated locally at $commit"
fi
if [ "$push" -eq 1 ]; then
  git -C "$worktree" push origin HEAD:refs/heads/state-backup
  echo "pushed state-backup"
else
  echo "not pushed (STATE_BACKUP_PUSH=0 or --no-push)"
fi
