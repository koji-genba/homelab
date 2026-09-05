#!/bin/sh
set -eu

repo_root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)}
state_root="$repo_root/files/infrastructure/terraform"
test -d "$state_root" || exit 0

# State is plaintext at rest in the local checkout. Refuse permissive modes;
# never repair them implicitly because that would hide an unsafe boundary.
find "$state_root" -type f \( -name '*.tfstate' -o -name '*.tfstate.*' \) -print |
while IFS= read -r state; do
  mode=$(stat -c '%a' "$state")
  case "$mode" in
    600) ;;
    *)
      echo "Terraform state must be mode 0600: ${state#"$repo_root/"} (mode $mode)" >&2
      exit 1
      ;;
  esac
done
