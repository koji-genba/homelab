#!/bin/sh
set -eu
umask 077
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT INT TERM
command -v age >/dev/null
command -v age-keygen >/dev/null
repo="$fixture/repo"
remote="$fixture/remote.git"
git init -q --bare "$remote"
git init -q "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
cp "$repo_root/.gitignore" "$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm fixture
git -C "$repo" remote add origin "$remote"
mkdir -p "$repo/files/infrastructure/terraform/apps-vm"
state="$repo/files/infrastructure/terraform/apps-vm/terraform.tfstate"
age-keygen -o "$fixture/identity" >"$fixture/keygen.log" 2>&1
AGE_RECIPIENT=$(age-keygen -y "$fixture/identity")
AGE_IDENTITY_FILE="$fixture/identity"
STATE_SYNC_REPO_ROOT=$repo
STATE_LOCK_REPO_ROOT=$repo
STATE_BACKUP_REPO_ROOT=$repo
STATE_OPERATION_REPO_ROOT=$repo
export AGE_RECIPIENT AGE_IDENTITY_FILE STATE_SYNC_REPO_ROOT STATE_LOCK_REPO_ROOT STATE_BACKUP_REPO_ROOT STATE_OPERATION_REPO_ROOT
write_state() { printf '{"lineage":"%s","serial":%s%s}\n' "$1" "$2" "${3:-}" >"$state"; chmod 0600 "$state"; }
backup() { "$repo_root/scripts/state-backup.sh" --push >"$fixture/backup.log" 2>&1; }
sync_state() { "$repo_root/scripts/state-sync.sh" >"$fixture/sync.log" 2>&1; }
reject_sync() {
  if sync_state; then echo 'unsafe sync succeeded' >&2; exit 1; fi
  grep -q "$1" "$fixture/sync.log"
}
lock() { "$repo_root/scripts/state-lock.sh" "$@"; }
unlocked() { test -z "$(git -C "$repo" ls-remote origin refs/heads/state-lock)"; }
write_state apps 1
backup
rm "$state"
sync_state
test "$(stat -c %a "$state")" = 600
# Equal JSON (including harmless formatting differences) is a no-op.
mtime=$(stat -c %Y "$state")
sync_state
test "$(stat -c %Y "$state")" = "$mtime"
write_state apps 2
backup
write_state apps 1
sync_state
saved=$(find "$repo/files" -name 'terraform.tfstate.pre-sync.*')
test -n "$saved"
test "$(stat -c %a "$saved")" = 600
git -C "$repo" check-ignore -q "$saved"
"$repo_root/scripts/check-terraform-state-modes.sh" "$repo"
write_state apps 3
reject_sync 'local state is newer'
# Publishing a stale workstation must not roll canonical state backwards.
write_state apps 1
if backup; then echo 'stale backup accepted' >&2; exit 1; fi
write_state other 2
reject_sync 'lineage mismatch'
write_state apps 2 ',"different":true'
reject_sync 'same serial with different contents'
write_state apps 2 ',"different":false'
reject_sync 'same serial with different contents'
printf '%s\n' not-json >"$state"
reject_sync 'invalid Terraform state JSON'
write_state apps 2
# A symlink destination must never be followed, even with valid plaintext.
mv "$state" "$fixture/held-state"
ln -s "$fixture/held-state" "$state"
reject_sync 'refusing symlink'
rm "$state"
mv "$fixture/held-state" "$state"
mkdir -p "$repo/files/infrastructure/terraform/local-only"
printf '%s\n' '{"lineage":"extra","serial":0}' >"$repo/files/infrastructure/terraform/local-only/terraform.tfstate"
sync_state
grep -q 'local root absent from backup' "$fixture/sync.log"
rm "$repo/files/infrastructure/terraform/local-only/terraform.tfstate"
# Fetch failure must stop; skip must work even without an identity.
git -C "$repo" remote set-url origin "$fixture/missing.git"
reject_sync 'unable to fetch'
STATE_SYNC=skip AGE_IDENTITY_FILE='' sync_state
grep -q 'WARNING: STATE_SYNC=skip' "$fixture/sync.log"
git -C "$repo" remote set-url origin "$remote"
# Two workstations compete for the same ref. No checkout/index modification.
before=$(git -C "$repo" status --porcelain)
branch=$(git -C "$repo" symbolic-ref HEAD)
first=$(lock acquire fixture)
git clone -q "$remote" "$fixture/other" 2>"$fixture/clone.log"
if STATE_LOCK_REPO_ROOT="$fixture/other" lock acquire competitor >"$fixture/lock.log" 2>&1; then
  echo 'second lock unexpectedly acquired' >&2; exit 1
fi
grep -q "$first" "$fixture/lock.log"
wrong=0000000000000000000000000000000000000001
if lock release "$wrong" >"$fixture/release.log" 2>&1; then echo 'foreign lock released' >&2; exit 1; fi
if lock unlock >"$fixture/unlock.log" 2>&1; then echo 'unconfirmed unlock accepted' >&2; exit 1; fi
if CONFIRM=000000000000 lock unlock >"$fixture/unlock.log" 2>&1; then echo 'wrong confirmation accepted' >&2; exit 1; fi
test "$before" = "$(git -C "$repo" status --porcelain)"
test "$branch" = "$(git -C "$repo" symbolic-ref HEAD)"
lock release "$first" >"$fixture/release.log" 2>&1
unlocked
# Run the real host wrapper with a fixture-only Makefile. Preflight is stubbed
# because a local bare remote needs no SSH; sync/backup/lease remain real.
cat >"$repo/Makefile" <<'MAKE'
.PHONY: state-backup-preflight state-sync _state-backup
state-backup-preflight:
	@echo preflight >>"$(CALLS)"
state-sync:
	@echo sync >>"$(CALLS)"
	@"$(SCRIPTS)/state-sync.sh"
_state-backup:
	@echo backup >>"$(CALLS)"
	@test "$(FAIL_BACKUP)" != 1
	@"$(SCRIPTS)/state-backup.sh" --no-push
	@git push origin refs/heads/state-backup:refs/heads/state-backup
MAKE
SCRIPTS="$repo_root/scripts"
CALLS="$fixture/calls"
export SCRIPTS CALLS
cat >"$fixture/apply" <<'APPLY'
#!/bin/sh
set -eu
printf '{"lineage":"apps","serial":%s}\n' "$NEXT_SERIAL" >"$STATE_SYNC_REPO_ROOT/files/infrastructure/terraform/apps-vm/terraform.tfstate"
if test "${WAIT_SIGNAL:-0}" = 1; then
  touch "$SIGNAL_READY"
  sleep 30 &
  wait
fi
exit "${APPLY_STATUS:-0}"
APPLY
chmod +x "$fixture/apply"
run_apply() { "$repo_root/scripts/state-operation.sh" fixture-apply "$fixture/apply" >"$fixture/operation.log" 2>&1; }
NEXT_SERIAL=3 APPLY_STATUS=7
export NEXT_SERIAL APPLY_STATUS
code=0
run_apply || code=$?
test "$code" -eq 7
unlocked
grep -q backup "$CALLS"
rm "$state"
sync_state
python3 - "$state" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['serial'] == 3
PY
# An unchanged operation must unlock without creating a backup.
: >"$CALLS"
"$repo_root/scripts/state-operation.sh" fixture-noop true >"$fixture/noop.log" 2>&1
unlocked
if grep -q backup "$CALLS"; then echo 'unchanged operation backed up' >&2; exit 1; fi
# Failed publication retains ownership and preserves the original apply code.
NEXT_SERIAL=4 FAIL_BACKUP=1
export FAIL_BACKUP
code=0
run_apply || code=$?
test "$code" -eq 7
grep -q 'Backup failed; lock retained' "$fixture/operation.log"
held=$(git -C "$repo" ls-remote origin refs/heads/state-lock | cut -f1)
test -n "$held"
FAIL_BACKUP=0
make --no-print-directory -C "$repo" _state-backup >"$fixture/recover.log" 2>&1
CONFIRM=$(printf '%.12s' "$held") lock unlock >"$fixture/unlock.log" 2>&1
unlocked
NEXT_SERIAL=5 APPLY_STATUS=0 FAIL_BACKUP=1
code=0
run_apply || code=$?
test "$code" -eq 1
held=$(git -C "$repo" ls-remote origin refs/heads/state-lock | cut -f1)
test -n "$held"
FAIL_BACKUP=0
make --no-print-directory -C "$repo" _state-backup >"$fixture/recover.log" 2>&1
lock release "$held" >"$fixture/release.log" 2>&1
unlocked
# TERM and INT stop the child group, publish partial state, then release.
SIGNAL_READY="$fixture/ready"
export SIGNAL_READY
for signal in TERM INT; do
  NEXT_SERIAL=$((NEXT_SERIAL + 1))
  export NEXT_SERIAL
  rm -f "$SIGNAL_READY"
  WAIT_SIGNAL=1 python3 - "$repo_root/scripts/state-operation.sh" "$fixture/apply" "$signal" "$fixture/signal.log" <<'PY'
import os, signal, subprocess, sys, time
from pathlib import Path
with open(sys.argv[4], 'w') as output:
    process = subprocess.Popen([sys.argv[1], 'fixture-signal', sys.argv[2]], stdout=output, stderr=output)
    deadline = time.monotonic() + 15
    while not Path(os.environ['SIGNAL_READY']).exists():
        if process.poll() is not None or time.monotonic() > deadline:
            process.kill()
            raise SystemExit('signal fixture failed to start')
        time.sleep(.02)
    os.kill(process.pid, getattr(signal, 'SIG' + sys.argv[3]))
    assert process.wait(timeout=15) == {'TERM': 143, 'INT': 130}[sys.argv[3]]
PY
  unlocked
done
# Exercise the actual Makefile entry points with a fake Terraform executable.
# Only preflight's SSH probe is replaced for the bare local remote.
ln -s "$repo_root/scripts" "$repo/scripts"
printf 'include %s/Makefile\n' "$repo_root" >"$repo/Makefile"
cat >>"$repo/Makefile" <<'MAKE'
state-backup-preflight:
	@echo preflight >>"$(CALLS)"
MAKE
mkdir "$fixture/bin"
cat >"$fixture/bin/terraform" <<'TF'
#!/bin/sh
set -eu
root=${1#-chdir=}
case $2 in
  init|validate) ;;
  show) printf '%s\n' '{"variables":{"acl_policy_file":{"value":""}}}' ;;
  apply|import)
    test -n "$(git ls-remote origin refs/heads/state-lock)"
    python3 - "$root/terraform.tfstate" <<'PYTF'
import json, os, sys
from pathlib import Path
path = Path(sys.argv[1])
value = json.loads(path.read_text()) if path.exists() else {'lineage': path.parent.name, 'serial': 0}
value['serial'] += 1
path.write_text(json.dumps(value))
path.chmod(0o600)
PYTF
    exit "${MAKE_APPLY_STATUS:-0}"
    ;;
  plan) : >"$root/terraform.tfplan" ;;
  state) ;; # No existing Tailscale resource gates in this synthetic state.
  *) exit 1 ;;
esac
TF
chmod +x "$fixture/bin/terraform"
PATH="$fixture/bin:$PATH"
export PATH
integration_make() {
  make --no-print-directory -C "$repo" "$@" TOOLBOX_RUN= TOOLBOX_PROXMOX_RUN= TOOLBOX_TAILSCALE_RUN= TF_VAR_proxmox_api_token=fixture TAILSCALE_API_KEY=fixture >"$fixture/make.log" 2>&1 || {
    cat "$fixture/make.log" >&2
    return 1
  }
}
for name in apps-vm agent-vm runner-vm elastiflow tailscale-gateway stashpad-dev tailscale; do
  root="files/infrastructure/terraform/$name"
  mkdir -p "$repo/$root"
  : >"$repo/$root/terraform.tfplan"
  chmod 0600 "$repo/$root/terraform.tfplan"
  integration_make terraform-apply TERRAFORM_ROOT="$root"
  unlocked
done
: >"$repo/files/infrastructure/terraform/tailscale/terraform.tfplan"
chmod 0600 "$repo/files/infrastructure/terraform/tailscale/terraform.tfplan"
integration_make tailscale-apply
unlocked
printf '%s\n' '{"acls":[]}' >"$repo/policy.json"
for name in acl dns router core; do
  integration_make "tailscale-import-$name" MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true ADGUARD_READY=true MANAGE_SUBNET_ROUTER=true TAILSCALE_DEVICE_ID=fixture ACL_POLICY_FILE=policy.json
  unlocked
done
# A read-only plan syncs without acquiring a lock; validate needs no identity.
integration_make terraform-plan
unlocked
AGE_IDENTITY_FILE='' integration_make terraform-validate
# The mode checker includes pre-sync copies, not only the active state.
chmod 0644 "$saved"
if "$repo_root/scripts/check-terraform-state-modes.sh" "$repo" >"$fixture/mode.log" 2>&1; then
  echo 'permissive pre-sync copy accepted' >&2; exit 1
fi
chmod 0600 "$saved"
# Offline ruleset contract, without any gh call.
python3 - "$repo_root" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('policy', sys.argv[1] + '/scripts/github-agent-repo.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
state = policy.desired_state()
assert state['conditions']['ref_name']['include'] == ['refs/heads/state-backup', 'refs/heads/state-lock']
assert state['bypass_actors'] == [{'actor_id': 5, 'actor_type': 'RepositoryRole', 'bypass_mode': 'always'}]
assert {rule['type'] for rule in state['rules']} == {'creation', 'update', 'deletion', 'non_fast_forward'}
assert policy.equivalent(state, state)
PY
echo 'state sync/lock fixture: ok'
