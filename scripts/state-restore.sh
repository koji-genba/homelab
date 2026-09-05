#!/bin/sh
set -eu
umask 077

# Restore encrypted Terraform state without checking out or merging the
# state-backup branch. The only accepted source paths are the files generated
# by state-backup.sh under terraform-state/files/infrastructure/terraform/.
repo_root=${STATE_RESTORE_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
identity=${AGE_IDENTITY_FILE:-}
test -n "$identity" || {
  echo "AGE_IDENTITY_FILE is required; recover the key from KeePassXC first" >&2
  exit 1
}
test -r "$identity" || { echo "age identity is not readable: $identity" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "age is required" >&2; exit 1; }
git -C "$repo_root" remote get-url origin >/dev/null 2>&1 || {
  echo "repository has no origin remote" >&2
  exit 1
}

paths_file=$(mktemp)
manifest=$(mktemp)
cleanup_files=$(mktemp)
cleanup() {
  if test -r "$cleanup_files"; then
    while IFS= read -r cleanup_file; do
      test -n "$cleanup_file" && rm -f "$cleanup_file"
    done <"$cleanup_files"
  fi
  rm -f "$paths_file" "$manifest" "$cleanup_files"
}
trap cleanup EXIT INT TERM

# Fetch only the remote-tracking ref. This deliberately never checks out the
# branch, so a fresh clone's working tree and current branch remain unchanged.
git -C "$repo_root" fetch --no-tags origin \
  'state-backup:refs/remotes/origin/state-backup' >/dev/null 2>&1 || {
  echo "unable to fetch origin/state-backup" >&2
  exit 1
}
state_ref=refs/remotes/origin/state-backup
git -C "$repo_root" show-ref --verify --quiet "$state_ref" || {
  echo "origin/state-backup does not exist" >&2
  exit 1
}

git -C "$repo_root" ls-tree -r --name-only "$state_ref" -- terraform-state >"$paths_file"
test -s "$paths_file" || {
  echo "origin/state-backup contains no state-backup tree" >&2
  exit 1
}

restored=0
while IFS= read -r source_path; do
  test -n "$source_path" || continue

  # Reject every path outside the exact state-backup output contract. This
  # also rejects ../, absolute paths, duplicate separators, and unrelated
  # files that could otherwise become an unexpected restore input.
  case "$source_path" in
    terraform-state/files/infrastructure/terraform/*/terraform.tfstate.age) ;;
    *)
      echo "refusing unexpected state-backup path: $source_path" >&2
      exit 1
      ;;
  esac
  destination=${source_path#terraform-state/}
  case "$destination" in
    *..*|*//*|*/./*)
      echo "refusing unsafe state-backup path: $source_path" >&2
      exit 1
      ;;
  esac
  destination=${destination%.age}
  test "$destination" != "${source_path#terraform-state/}" || {
    echo "refusing malformed state-backup path: $source_path" >&2
    exit 1
  }
  destination_abs="$repo_root/$destination"
  if test -e "$destination_abs" || test -L "$destination_abs"; then
    echo "refusing to overwrite existing Terraform state: $destination" >&2
    exit 1
  fi
  destination_dir=${destination%/*}
  test -d "$repo_root/$destination_dir" || {
    echo "Terraform root directory is missing: $destination_dir" >&2
    exit 1
  }
  source_type=$(git -C "$repo_root" cat-file -t "$state_ref:$source_path")
  test "$source_type" = blob || {
    echo "state-backup entry is not a blob: $source_path" >&2
    exit 1
  }

  # Keep temporary plaintext and ciphertext in the destination Terraform
  # root. Both names match the repository's *.tfstate.* ignore rule, so even
  # SIGKILL cannot leave an accidentally trackable plaintext file in the
  # checkout. cleanup_files removes them on ordinary failures.
  candidate=$(mktemp "$repo_root/$destination_dir/.terraform.tfstate.restore.XXXXXX")
  printf '%s\n' "$candidate" >>"$cleanup_files"
  ciphertext=$(mktemp "$repo_root/$destination_dir/.terraform.tfstate.ciphertext.XXXXXX")
  printf '%s\n' "$ciphertext" >>"$cleanup_files"
  chmod 0600 "$ciphertext"
  git -C "$repo_root" cat-file blob "$state_ref:$source_path" >"$ciphertext"
  if ! age --decrypt --identity "$identity" "$ciphertext" >"$candidate"; then
    rm -f "$ciphertext"
    echo "unable to decrypt state-backup entry: $source_path" >&2
    exit 1
  fi
  rm -f "$ciphertext"
  chmod 0600 "$candidate"

  # Validate every decrypted file before installing any of them. Terraform
  # state must be JSON with the stable top-level fields used by all roots.
  if ! python3 - "$candidate" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    state = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid Terraform state JSON: {exc}")
if not isinstance(state, dict):
    raise SystemExit("Terraform state must be a JSON object")
if not isinstance(state.get("version"), int):
    raise SystemExit("Terraform state version is missing or not an integer")
if not isinstance(state.get("serial"), int):
    raise SystemExit("Terraform state serial is missing or not an integer")
if not isinstance(state.get("lineage"), str):
    raise SystemExit("Terraform state lineage is missing or not a string")
if not isinstance(state.get("outputs"), dict):
    raise SystemExit("Terraform state outputs is missing or not an object")
if not isinstance(state.get("resources"), list):
    raise SystemExit("Terraform state resources is missing or not an array")
PY
  then
    echo "refusing invalid Terraform state: $source_path" >&2
    exit 1
  fi
  printf '%s\t%s\n' "$destination" "$candidate" >>"$manifest"
  restored=$((restored + 1))
done <"$paths_file"

test "$restored" -gt 0 || { echo "no Terraform states found to restore" >&2; exit 1; }

# All candidates are now decrypted and validated. Rename each candidate from
# the same filesystem into its final path; no existing destination is ever
# intentionally overwritten. A failure before this point leaves no state in
# the checkout.
while IFS="	" read -r destination candidate; do
  test -n "$destination" && test -r "$candidate" || exit 1
  destination_abs="$repo_root/$destination"
  if test -e "$destination_abs" || test -L "$destination_abs"; then
    echo "refusing to overwrite existing Terraform state: $destination" >&2
    exit 1
  fi
  chmod 0600 "$candidate"
  mv "$candidate" "$destination_abs"
  chmod 0600 "$destination_abs"
done <"$manifest"

echo "restored $restored encrypted Terraform state file(s) from origin/state-backup"
