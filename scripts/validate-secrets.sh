#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
bad=0

# Inspect tracked and ordinary untracked files, but not deliberately ignored
# local runtime files. This keeps the check useful in a worktree containing
# old local state while making CI fail on anything that could be committed.
tracked_files=$(git -C "$repo_root" ls-files -co --exclude-standard)
for path in $tracked_files; do
  case "$path" in
    *.tfstate|*.tfstate.*|*/runtime.yaml|*/.env|.env)
      echo "forbidden plaintext state/runtime file: $path" >&2
      bad=1
      ;;
  esac
done

for path in $(git -C "$repo_root" ls-files -co --exclude-standard '*runtime.sops.yaml'); do
  test -f "$repo_root/$path" || continue
  grep -q '^sops:' "$repo_root/$path" || {
    echo "runtime.sops.yaml lacks SOPS metadata: $path" >&2
    bad=1
  }
done

if git -C "$repo_root" grep -nI -E 'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}' -- ':!*.example' ':!*.template' >/dev/null 2>&1; then
  echo "possible private key or access token found in tracked content" >&2
  bad=1
fi

test "$bad" -eq 0 || exit 1
echo "secret/state scan: clean"
