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
test -r "$identity" || { echo "AGE_IDENTITY_FILE must point to the KeePassXC-recovered age identity" >&2; exit 1; }

"$script_root/check-terraform-state-modes.sh" "$repo_root"

tracked_state=$(git -C "$repo_root" ls-files | awk '/(^|\/)[^/]+\.tfstate(\.|$)/ {print}')
test -z "$tracked_state" || { echo "refusing to continue: state is tracked: $tracked_state" >&2; exit 1; }

worktree=$(mktemp -d)
state_list=$(mktemp)
expected=$(mktemp)
cleanup() {
  rm -f "$state_list" "$expected"
  git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  rmdir "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

git -C "$repo_root" fetch --no-tags origin state-backup:refs/remotes/origin/state-backup >/dev/null 2>&1 || true
git -C "$repo_root" worktree add --detach "$worktree" HEAD >/dev/null

if git -C "$repo_root" show-ref --verify --quiet refs/heads/state-backup; then
  git -C "$worktree" checkout -B state-backup state-backup >/dev/null
elif git -C "$repo_root" show-ref --verify --quiet refs/remotes/origin/state-backup; then
  git -C "$worktree" checkout -B state-backup origin/state-backup >/dev/null
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
  relative=${state#"$repo_root/"}
  destination="$worktree/terraform-state/$relative.age"
  printf '%s\n' "$destination" >>"$expected"
  mkdir -p "$(dirname "$destination")"
  decrypted=$(mktemp)
  keep=0
  if test -r "$destination" && age --decrypt --identity "$identity" "$destination" >"$decrypted" 2>/dev/null \
    && cmp -s "$state" "$decrypted"; then
    keep=1
  fi
  rm -f "$decrypted"
  if test "$keep" -eq 0; then
    encrypted="$destination.new.$$"
    age --recipient "$recipient" --output "$encrypted" "$state"
    mv -f "$encrypted" "$destination"
  fi
  decrypted=$(mktemp)
  age --decrypt --identity "$identity" "$destination" >"$decrypted"
  cmp -s "$state" "$decrypted" || {
    rm -f "$decrypted"
    echo "encrypted state failed decrypt verification: $relative" >&2
    exit 1
  }
  rm -f "$decrypted"
done <"$state_list"

# Remove ciphertexts for state files that no longer exist. Restrict the find
# to this generated subtree; unrelated branches/files are never touched.
find "$worktree/terraform-state" -type f -name '*.age' -print |
while IFS= read -r old_ciphertext; do
  if ! grep -Fqx "$old_ciphertext" "$expected"; then
    rm -f "$old_ciphertext"
  fi
done

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
