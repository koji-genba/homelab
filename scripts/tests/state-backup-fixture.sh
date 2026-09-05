#!/bin/sh
set -eu

# Offline fixture for the worktree/replace/decrypt path. It deliberately uses
# a fake age binary and --no-push, so this test never contacts a remote or
# handles a real secret key.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
bin=$(mktemp -d)
cleanup() { rm -rf "$fixture" "$bin"; }
trap cleanup EXIT INT TERM

cat >"$bin/age" <<'AGE'
#!/bin/sh
set -eu
output=
input=
decrypt=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --decrypt) decrypt=1; shift ;;
    --recipient|--identity) shift 2 ;;
    *) input=$1; shift ;;
  esac
done
if [ "$decrypt" -eq 1 ]; then
  # The first line is random ciphertext metadata; the remainder is the
  # plaintext. This models age's randomized encryption for the no-op test.
  tail -n +2 "$input"
else
  {
    printf 'FAKE-CIPHERTEXT-%s\n' "$(date +%s%N)"
    cat "$input"
  } >"$output"
fi
AGE
chmod 0755 "$bin/age"
touch "$fixture/identity"
mkdir -p "$fixture/files/infrastructure/terraform/apps-vm"
printf '%s\n' '{"fixture":true}' >"$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate"
mkdir -p "$fixture/files/infrastructure/terraform/tailscale"
printf '%s\n' '{"fixture":"second"}' >"$fixture/files/infrastructure/terraform/tailscale/terraform.tfstate"
printf '%s\n' stale-backup >"$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"
chmod 0644 \
  "$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate" \
  "$fixture/files/infrastructure/terraform/tailscale/terraform.tfstate" \
  "$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"
printf '%s\n' '*.tfstate' >"$fixture/.gitignore"
git -C "$fixture" init -q
git -C "$fixture" config user.email fixture@example.invalid
git -C "$fixture" config user.name fixture
git -C "$fixture" add .gitignore
git -C "$fixture" commit -qm fixture

if PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push \
  >"$fixture/mode.log" 2>&1; then
  echo "permissive Terraform state mode was unexpectedly accepted" >&2
  exit 1
fi
grep -q 'Terraform state must be mode 0600' "$fixture/mode.log"
chmod 0600 "$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate" \
  "$fixture/files/infrastructure/terraform/tailscale/terraform.tfstate" \
  "$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate.backup"

PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push
git -C "$fixture" cat-file -e state-backup:terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age
first_ciphertext=$(git -C "$fixture" show state-backup:terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age | sha256sum | awk '{print $1}')
second_ciphertext=$(git -C "$fixture" show state-backup:terraform-state/files/infrastructure/terraform/tailscale/terraform.tfstate.age | sha256sum | awk '{print $1}')
# A second run exercises the unchanged-branch path; it must succeed without
# attempting a no-op commit. The ciphertext hashes must remain stable despite
# the fake age tool randomizing every new encryption.
PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push >/dev/null
test "$first_ciphertext" = "$(git -C "$fixture" show state-backup:terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age | sha256sum | awk '{print $1}')"
test "$second_ciphertext" = "$(git -C "$fixture" show state-backup:terraform-state/files/infrastructure/terraform/tailscale/terraform.tfstate.age | sha256sum | awk '{print $1}')"
# A removed state is removed from the backup branch while another state keeps
# the run valid.
rm "$fixture/files/infrastructure/terraform/apps-vm/terraform.tfstate"
PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push >/dev/null
if git -C "$fixture" cat-file -e state-backup:terraform-state/files/infrastructure/terraform/apps-vm/terraform.tfstate.age 2>/dev/null; then
  echo "deleted state still present in backup" >&2
  exit 1
fi
echo "state-backup fixture: ok"
