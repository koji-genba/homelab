#!/bin/sh
set -eu

# Offline fixture for the worktree/replace/decrypt path. It deliberately uses
# a fake age binary and --no-push, so this test never contacts a remote or
# handles a real secret key.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
bin=$(mktemp -d)
remote=
cleanup() {
  rm -rf "$fixture" "$bin"
  test -z "$remote" || rm -rf "$remote"
}
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

# Exercise synchronization with a local bare origin. The script must recover
# a missing local branch from the remote, retain local commits that are ahead,
# fast-forward a stale local branch, and fail closed on divergence.
remote=$(mktemp -d)
git -C "$remote" init --bare -q
git -C "$fixture" remote add origin "$remote"
git -C "$fixture" push -q origin state-backup
base=$(git -C "$fixture" rev-parse refs/heads/state-backup)
git -C "$fixture" update-ref -d refs/heads/state-backup
PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push >/dev/null
test "$(git -C "$fixture" rev-parse refs/heads/state-backup)" = "$base"

make_child() {
  parent=$1
  tree=$(git -C "$fixture" rev-parse "$parent^{tree}")
  printf '%s\n' "$2" | git -C "$fixture" commit-tree "$tree" -p "$parent"
}

local_ahead=$(make_child "$base" local-ahead)
git -C "$fixture" update-ref refs/heads/state-backup "$local_ahead" "$base"
PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push >/dev/null
test "$(git -C "$fixture" rev-parse refs/heads/state-backup)" = "$local_ahead"

git -C "$fixture" update-ref refs/heads/state-backup "$base" "$local_ahead"
remote_ahead=$(make_child "$base" remote-ahead)
git -C "$fixture" push -q origin "$remote_ahead:refs/heads/state-backup"
PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push >/dev/null
test "$(git -C "$fixture" rev-parse refs/heads/state-backup)" = "$remote_ahead"

local_diverged=$(make_child "$remote_ahead" local-diverged)
git -C "$fixture" update-ref refs/heads/state-backup "$local_diverged" "$remote_ahead"
remote_diverged=$(make_child "$remote_ahead" remote-diverged)
git -C "$fixture" push -q origin "$remote_diverged:refs/heads/state-backup"
if PATH="$bin:$PATH" AGE_RECIPIENT=age1fixture AGE_IDENTITY_FILE="$fixture/identity" \
  STATE_BACKUP_REPO_ROOT="$fixture" "$repo_root/scripts/state-backup.sh" --no-push \
  >"$fixture/diverged.log" 2>&1; then
  echo "diverged state-backup branches were unexpectedly accepted" >&2
  exit 1
fi
grep -q 'refusing diverged state-backup branches' "$fixture/diverged.log"
test "$(git -C "$fixture" rev-parse refs/heads/state-backup)" = "$local_diverged"
git -C "$fixture" update-ref refs/heads/state-backup "$remote_diverged" "$local_diverged"

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
