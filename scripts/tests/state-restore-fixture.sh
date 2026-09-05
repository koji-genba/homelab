#!/bin/sh
set -eu

# Offline fixture for state-restore.sh. It uses a local bare Git remote and a
# fake age decryptor; no real credentials, remote service, or repository state
# is touched.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
bin=$(mktemp -d)
cleanup() { rm -rf "$fixture" "$bin"; }
trap cleanup EXIT INT TERM

cat >"$bin/age" <<'AGE'
#!/bin/sh
set -eu
input=
decrypt=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --decrypt) decrypt=1; shift ;;
    --identity) shift 2 ;;
    *) input=$1; shift ;;
  esac
done
test "$decrypt" -eq 1
tail -n +2 "$input"
AGE
chmod 0755 "$bin/age"
touch "$fixture/identity"

remote="$fixture/remote.git"
source_repo="$fixture/source"
clone="$fixture/clone"
git init -q --bare "$remote"
git init -q "$source_repo"
git -C "$source_repo" config user.email fixture@example.invalid
git -C "$source_repo" config user.name fixture
git -C "$source_repo" remote add origin "$remote"

mkdir -p \
  "$source_repo/terraform-state/files/infrastructure/terraform/apps-vm" \
  "$source_repo/terraform-state/files/infrastructure/terraform/tailscale"
printf '%s\n%s\n' fixture-ciphertext \
  '{"version":4,"terraform_version":"1.15.4","serial":1,"lineage":"apps","outputs":{},"resources":[]}' \
  >"$source_repo/terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age"
printf '%s\n%s\n' fixture-ciphertext \
  '{"version":4,"terraform_version":"1.15.4","serial":2,"lineage":"tailscale","outputs":{},"resources":[]}' \
  >"$source_repo/terraform-state/files/infrastructure/terraform/tailscale/terraform.tfstate.age"
git -C "$source_repo" add terraform-state
git -C "$source_repo" commit -qm initial
git -C "$source_repo" branch -M state-backup
git -C "$source_repo" push -q origin state-backup

# A fresh clone has no Terraform roots checked out, so create only the empty
# desired destination directories. state-restore must fetch the remote ref,
# never checkout state-backup, and install both files.
git clone -q --no-checkout "$remote" "$clone"
cp "$repo_root/.gitignore" "$clone/.gitignore"
mkdir -p "$clone/files/infrastructure/terraform/apps-vm" \
  "$clone/files/infrastructure/terraform/tailscale"
# A crash can leave a candidate behind. Its name must match the existing
# Terraform state ignore rule, so it is never an accidental Git addition.
stale="$clone/files/infrastructure/terraform/apps-vm/.terraform.tfstate.restore.stale"
printf '%s\n' stale >"$stale"
git -C "$clone" check-ignore -q "$stale"
clone_status=$(git -C "$clone" status --porcelain --untracked-files=all)
case "$clone_status" in
  *stale*) echo "stale restore candidate is trackable" >&2; exit 1 ;;
esac
PATH="$bin:$PATH" AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_RESTORE_REPO_ROOT="$clone" "$repo_root/scripts/state-restore.sh"
test -f "$clone/files/infrastructure/terraform/apps-vm/terraform.tfstate"
test -f "$clone/files/infrastructure/terraform/tailscale/terraform.tfstate"
test "$(stat -c '%a' "$clone/files/infrastructure/terraform/apps-vm/terraform.tfstate")" = 600
rm -f "$stale"
python3 - "$clone/files/infrastructure/terraform/apps-vm/terraform.tfstate" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["version"] == 4
assert state["resources"] == []
PY

# Existing plaintext state is refused before another installation is started.
if PATH="$bin:$PATH" AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_RESTORE_REPO_ROOT="$clone" "$repo_root/scripts/state-restore.sh" \
  >"$fixture/existing.log" 2>&1; then
  echo "existing state was unexpectedly overwritten" >&2
  exit 1
fi
grep -q 'refusing to overwrite existing Terraform state' "$fixture/existing.log"

# Publish a tampered encrypted payload whose decrypted content is not valid
# Terraform JSON. A new clone proves that preflight rejects it without a
# partially restored destination.
printf '%s\n%s\n' fixture-ciphertext not-json \
  >"$source_repo/terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age"
git -C "$source_repo" add terraform-state
git -C "$source_repo" commit -qm tampered
git -C "$source_repo" push -q origin state-backup
bad_clone="$fixture/bad-clone"
git clone -q --no-checkout "$remote" "$bad_clone"
mkdir -p "$bad_clone/files/infrastructure/terraform/apps-vm" \
  "$bad_clone/files/infrastructure/terraform/tailscale"
if PATH="$bin:$PATH" AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_RESTORE_REPO_ROOT="$bad_clone" "$repo_root/scripts/state-restore.sh" \
  >"$fixture/bad.log" 2>&1; then
  echo "invalid state was unexpectedly restored" >&2
  exit 1
fi
test ! -e "$bad_clone/files/infrastructure/terraform/apps-vm/terraform.tfstate"
test ! -e "$bad_clone/files/infrastructure/terraform/tailscale/terraform.tfstate"

# Restore the valid payload, then add an unrelated path under terraform-state;
# the path allowlist must reject the branch before installing any file.
printf '%s\n%s\n' fixture-ciphertext \
  '{"version":4,"terraform_version":"1.15.4","serial":3,"lineage":"apps","outputs":{},"resources":[]}' \
  >"$source_repo/terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age"
printf '%s\n' unexpected >"$source_repo/terraform-state/unexpected.txt"
git -C "$source_repo" add terraform-state
git -C "$source_repo" commit -qm unexpected-path
git -C "$source_repo" push -q origin state-backup
path_clone="$fixture/path-clone"
git clone -q --no-checkout "$remote" "$path_clone"
mkdir -p "$path_clone/files/infrastructure/terraform/apps-vm" \
  "$path_clone/files/infrastructure/terraform/tailscale"
if PATH="$bin:$PATH" AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_RESTORE_REPO_ROOT="$path_clone" "$repo_root/scripts/state-restore.sh" \
  >"$fixture/path.log" 2>&1; then
  echo "unexpected state-backup path was accepted" >&2
  exit 1
fi
test ! -e "$path_clone/files/infrastructure/terraform/apps-vm/terraform.tfstate"
grep -q 'refusing unexpected state-backup path' "$fixture/path.log"

echo "state-restore fixture: ok"
