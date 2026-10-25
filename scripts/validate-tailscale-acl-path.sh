#!/bin/sh
set -eu

# Validate a live ACL export before exposing it to Terraform in the toolbox.
# The export is intentionally an ignored local input, never a symlink or a
# path whose resolved file escapes the repository.
repo_root=${TAILSCALE_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)}
# Recovery may create a missing file, but its parent must already be in-repo.
allow_missing=false
if test "${1:-}" = --allow-missing; then
  allow_missing=true
  shift
fi
path=${1:-}
test -n "$path" || { echo "ACL_POLICY_FILE is required" >&2; exit 1; }
case "$path" in
  *..*) echo "ACL policy path must not contain '..': $path" >&2; exit 1 ;;
esac
case "$path" in
  /*) candidate=$path ;;
  *) candidate="$repo_root/$path" ;;
esac
if test "$allow_missing" != true || test -e "$candidate"; then
  test -f "$candidate" || { echo "ACL policy is not a regular file: $path" >&2; exit 1; }
fi
test ! -L "$candidate" || { echo "ACL policy symlinks are not accepted: $path" >&2; exit 1; }
repo_real=$(CDPATH='' cd -- "$repo_root" && pwd -P)
file_real=$(CDPATH='' cd -- "$(dirname -- "$candidate")" && pwd -P)/$(basename -- "$candidate")
case "$file_real" in
  "$repo_real"/*) ;;
  *) echo "ACL policy resolves outside the repository: $path" >&2; exit 1 ;;
esac
printf '%s\n' "${file_real#"$repo_real/"}"
