#!/bin/bash
# Host-side lifecycle: only toolbox children decrypt/encrypt state.
set -euo pipefail
umask 077
script_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=${STATE_OPERATION_REPO_ROOT:-$(CDPATH='' cd -- "$script_root/.." && pwd)}
cd "$repo_root"
operation=${1:?operation required}
shift
make_command=${MAKE:-make}
"$make_command" --no-print-directory state-backup-preflight
lock=$("$script_root/state-lock.sh" acquire "$operation")
temporary=$(mktemp -d)
started=0
child=
signal_code=0
fingerprint() {
  python3 - "$repo_root" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1]) / 'files/infrastructure/terraform'
for path in sorted(root.glob('*/terraform.tfstate')):
    if path.is_symlink() or not path.is_file():
        raise SystemExit('refusing nonregular active state')
    print(path.parent.name, hashlib.sha256(path.read_bytes()).hexdigest())
PY
}
# shellcheck disable=SC2317 # Invoked through EXIT trap.
finish() {
  code=$?
  trap - EXIT
  trap '' INT TERM
  retained=0
  if [ "$started" = 1 ]; then
    if ! fingerprint >"$temporary/after"; then
      echo "Cannot inspect changed state; lock retained: $lock" >&2
      retained=1
      [ "$code" -ne 0 ] || code=1
    elif [ "$operation" = state-backup ] || ! cmp -s "$temporary/before" "$temporary/after"; then
      if ! "$make_command" --no-print-directory _state-backup; then
        echo "Backup failed; lock retained: $lock" >&2
        echo 'Stop all writers. On this workstation repair credentials/network, run make _state-backup, then make state-lock-status and make state-unlock CONFIRM=<SHA prefix>. Do not sync another workstation first.' >&2
        retained=1
        [ "$code" -ne 0 ] || code=1
      fi
    fi
  fi
  if [ "$retained" = 0 ]; then
    if ! "$script_root/state-lock.sh" release "$lock"; then
      echo "Unlock failed; inspect make state-lock-status ($lock)" >&2
      [ "$code" -ne 0 ] || code=1
    fi
  fi
  rm -rf "$temporary"
  exit "$code"
}
# shellcheck disable=SC2317 # Invoked through signal traps.
interrupted() {
  signal_code=$1
  if [ -n "$child" ]; then
    kill -TERM -- "-$child" 2>/dev/null || true
    # The first wait can be interrupted by a signal; wait again before backup.
    wait "$child" 2>/dev/null || true
  fi
  exit "$signal_code"
}
trap finish EXIT
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
case "$operation" in
  state-backup|state-restore) ;;
  *) "$make_command" --no-print-directory state-sync ;;
esac
fingerprint >"$temporary/before"
started=1
if [ "$operation" = state-backup ]; then
  exit 0 # finish publishes even if the local fingerprint is unchanged.
fi
# A separate process group lets INT/TERM stop make and its toolbox child before
# inspecting state. SIGKILL/power loss deliberately leaves the remote lock.
set -m
"$@" &
child=$!
code=0
wait "$child" || code=$?
child=
exit "$code"
