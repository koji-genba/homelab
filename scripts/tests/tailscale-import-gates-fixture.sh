#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)
fixture=$(mktemp -d)
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT INT TERM

# No real Terraform, state or credentials are used by this fixture.
mkdir -p "$fixture/root"
FIXTURE_STATE_ROOT="$fixture/root"
FIXTURE_CALLS="$fixture/calls"
export FIXTURE_STATE_ROOT FIXTURE_CALLS
cat >"$fixture/terraform" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FIXTURE_CALLS"
test "$1" = "-chdir=$FIXTURE_STATE_ROOT"
test "$2" = state
test "$3" = list
test "$4" = -no-color
printf '%s\n' "$FIXTURE_ADDRESSES"
exit "${FIXTURE_STATUS:-0}"
EOF
chmod +x "$fixture/terraform"
PATH="$fixture:$PATH"
export PATH FIXTURE_ADDRESSES FIXTURE_STATUS
FIXTURE_STATUS=0

check() {
  sh "$repo_root/scripts/check-tailscale-import-gates.sh" "$FIXTURE_STATE_ROOT" "$@"
}
reject() {
  if check "$@" >"$fixture/rejected.log" 2>&1; then
    echo "Missing gates were unexpectedly accepted" >&2
    exit 1
  fi
}

FIXTURE_ADDRESSES=''
# Initial import must skip Terraform entirely, even if state list would fail.
FIXTURE_STATUS=1
check true '' '' ''
test ! -e "$FIXTURE_CALLS"
# A workspace directory is unexpected even without a default state file.
mkdir "$FIXTURE_STATE_ROOT/terraform.tfstate.d"
reject true true true true
grep -q 'only the default workspace is supported' "$fixture/rejected.log"
test ! -e "$FIXTURE_CALLS"
rmdir "$FIXTURE_STATE_ROOT/terraform.tfstate.d"
# Synthetic existence marker only; its contents are never read.
: >"$FIXTURE_STATE_ROOT/terraform.tfstate"
reject true true true true
grep -q 'Cannot list Tailscale state; import aborted' "$fixture/rejected.log"
FIXTURE_STATUS=0
check true '' '' ''
FIXTURE_ADDRESSES='tailscale_acl.policy[0]'
check true '' '' ''
reject false '' '' ''
FIXTURE_ADDRESSES='tailscale_dns_configuration.adguard[0]'
reject true '' '' true
reject true false true true
reject true true false true
reject true true '' true
check true true true ''
for address in 'tailscale_device_tags.subnet_router[0]' 'tailscale_device_subnet_routes.subnet_router[0]'; do
  FIXTURE_ADDRESSES=$address
  reject true true true ''
  reject true true true false
  check true '' '' true
done
FIXTURE_ADDRESSES='tailscale_acl.policy[0]
tailscale_dns_configuration.adguard[0]
tailscale_device_tags.subnet_router[0]
tailscale_device_subnet_routes.subnet_router[0]'
check true true true true
reject true true true false
reject true false true true
FIXTURE_STATUS=1
reject true true true true
grep -q 'Cannot list Tailscale state; import aborted' "$fixture/rejected.log"
# Workspace directories are rejected with a default state file present too.
mkdir "$FIXTURE_STATE_ROOT/terraform.tfstate.d"
reject true true true true
grep -q 'only the default workspace is supported' "$fixture/rejected.log"
rmdir "$FIXTURE_STATE_ROOT/terraform.tfstate.d"

# Exercise recursive make too: unexported parent Makefile values must reach
# every internal plan, including the core alias and both router imports.
mkdir -p "$fixture/repo/root"
cp "$repo_root/Makefile" "$fixture/repo/Makefile"
ln -s "$repo_root/scripts" "$fixture/repo/scripts"
printf '%s\n' '{"acls":[]}' >"$fixture/repo/policy.json"
cat >>"$fixture/repo/Makefile" <<'EOF'
ifeq ($(MAKELEVEL),0)
MANAGE_TAILNET ?= true
ENABLE_ADGUARD_DNS ?= true
ADGUARD_READY ?= true
MANAGE_SUBNET_ROUTER ?= true
endif
EOF
cat >"$fixture/terraform" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FIXTURE_CALLS"
test "$1" = -chdir=root
case "$2" in
  init) test "$FIXTURE_RUNNER" = local ;;
  import) test "$FIXTURE_RUNNER" = tailscale ;;
  state)
    test "$FIXTURE_RUNNER" = local
    printf '%s\n' "$FIXTURE_ADDRESSES"
    exit "$FIXTURE_STATUS"
    ;;
  plan)
    test "$FIXTURE_RUNNER" = tailscale
    : >root/terraform.tfplan
    ;;
  *) exit 1 ;;
esac
EOF
FIXTURE_CALLS="$fixture/calls"
export FIXTURE_CALLS
FIXTURE_STATUS=0
FIXTURE_ADDRESSES='tailscale_dns_configuration.adguard[0]
tailscale_device_subnet_routes.subnet_router[0]'
run_make() {
  (
    unset MAKELEVEL MAKEFLAGS MFLAGS
    make --no-print-directory -C "$fixture/repo" "$@" \
      'TOOLBOX_RUN=env FIXTURE_RUNNER=local' \
      'TOOLBOX_TAILSCALE_RUN=env FIXTURE_RUNNER=tailscale' TAILSCALE_ROOT=root \
      ACL_POLICY_FILE=policy.json TAILSCALE_DEVICE_ID=dummy-node
  ) >"$fixture/make.log" 2>&1
}
for target in acl dns router core; do
  # First import succeeds without querying state or passing provider
  # credentials to the gate check.
  rm -f "$fixture/repo/root/terraform.tfstate"
  FIXTURE_STATUS=1
  : >"$FIXTURE_CALLS"
  run_make "tailscale-import-$target" || { cat "$fixture/make.log"; exit 1; }
  if grep -q ' state ' "$FIXTURE_CALLS"; then
    echo "Initial import unexpectedly queried state: $target" >&2
    exit 1
  fi
  : >"$fixture/repo/root/terraform.tfstate"
  FIXTURE_STATUS=0
  : >"$FIXTURE_CALLS"
  run_make "tailscale-import-$target" || { cat "$fixture/make.log"; exit 1; }
  expected=1
  test "$target" != router || expected=2
  test "$(grep -c ' import ' "$FIXTURE_CALLS")" -eq "$expected"
  test "$(grep -c ' plan ' "$FIXTURE_CALLS")" -eq "$expected"
  grep ' plan ' "$FIXTURE_CALLS" | while IFS= read -r plan; do
    for gate in manage_tailnet enable_adguard_dns adguard_ready manage_subnet_router; do
      case "$plan" in
        *"-var=$gate=true"*) ;;
        *) echo "Internal plan lost $gate: $target" >&2; exit 1 ;;
      esac
    done
  done
  for missing in ENABLE_ADGUARD_DNS ADGUARD_READY MANAGE_SUBNET_ROUTER; do
    : >"$FIXTURE_CALLS"
    if run_make "tailscale-import-$target" "$missing=false"; then
      echo "Import unexpectedly accepted $missing=false: $target" >&2
      exit 1
    fi
    if grep -Eq ' (import|plan) ' "$FIXTURE_CALLS"; then
      echo "Missing gate was detected after import/plan: $target" >&2
      exit 1
    fi
  done
  FIXTURE_STATUS=1
  : >"$FIXTURE_CALLS"
  if run_make "tailscale-import-$target"; then
    echo "Import unexpectedly accepted a failed state read: $target" >&2
    exit 1
  fi
  if grep -Eq ' (import|plan) ' "$FIXTURE_CALLS"; then
    echo "Failed state read allowed import/plan: $target" >&2
    exit 1
  fi
  FIXTURE_STATUS=0
done

echo "Tailscale import gates fixture: ok"
