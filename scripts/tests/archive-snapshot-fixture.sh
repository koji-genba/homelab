#!/bin/bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
export FIXTURE="$fixture"
cat > "$fixture/bin/zfs" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path
root = Path(os.environ['FIXTURE'])
a = sys.argv[1:]
with (root / 'calls').open('a') as f:
    f.write(' '.join(a) + '\n')
if os.environ.get('FAIL') == a[0]:
    sys.exit(1)
state = root / 'snapshots'
names = state.read_text().splitlines()
if a[0] == 'list':
    if '-t' in a:
        if os.environ.get('FAIL') == 'snapshot-list':
            sys.exit(1)
        print('\n'.join(names))
    elif os.environ.get('MISSING'):
        sys.exit(1)
    else:
        print('tank-gen3/data/archive')
elif a[0] == 'get':
    print(os.environ.get('MOUNTED', 'yes'))
elif a[0] == 'snapshot':
    assert a[1] not in names, a
    state.write_text('\n'.join(names + [a[1]]) + '\n')
elif a[0] == 'destroy':
    assert len(a) == 2 and a[1] in names, a
    names.remove(a[1])
    state.write_text('\n'.join(names) + '\n')
else:
    raise AssertionError(a)
PY
cat > "$fixture/bin/date" <<'EOF_DATE'
#!/bin/sh
if [ "$1" = '+%Y%m%d %u %d' ]; then
    printf '%s\n' "$TEST_DATE"
else
    exec /bin/date "$@"
fi
EOF_DATE
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
export ARCHIVE_SNAPSHOT_LOGFILE="$fixture/archive.log"
export ARCHIVE_SNAPSHOT_LOCKFILE="$fixture/archive.lock"
export TEST_DATE='20261031 6 31'
ds=tank-gen3/data/archive
reset() { : > "$fixture/snapshots"; : > "$fixture/calls"; }
run() { "$repo_root/files/infrastructure/storage/archive-snapshot.sh"; }
expect_failure() {
    if run; then
        echo 'unexpected success' >&2
        exit 1
    fi
    ! grep -Eq '^(snapshot|destroy) ' "$fixture/calls"
}
# Dataset/mount/list failures cannot mutate ZFS.
reset; MISSING=1 expect_failure
reset; MOUNTED=no expect_failure
reset; FAIL=snapshot-list expect_failure
# Ordinary day, no writes, and safe repeat on the same day.
reset; run; run
test "$(cat "$fixture/snapshots")" = "$ds@daily-20261031"
test "$(grep -c '^snapshot ' "$fixture/calls")" = 1
# Monday and month-start; monthly takes precedence even on a Monday.
reset; TEST_DATE='20261102 1 02' run
grep -Fxq "$ds@daily-20261102" "$fixture/snapshots"
grep -Fxq "$ds@weekly-20261102" "$fixture/snapshots"
test "$(wc -l < "$fixture/snapshots")" = 2
reset; TEST_DATE='20270201 1 01' run
grep -Fxq "$ds@daily-20270201" "$fixture/snapshots"
grep -Fxq "$ds@monthly-20270201" "$fixture/snapshots"
if grep -q '@weekly-' "$fixture/snapshots"; then exit 1; fi
# All tiers prune only exact dataset, tier and date-shaped names, oldest first.
reset
for tier in daily weekly monthly; do
    for ((i=1; i<=16; i++)); do
        printf '%s@%s-202601%02d\n' "$ds" "$tier" "$i" >> "$fixture/snapshots"
    done
done
cat >> "$fixture/snapshots" <<EOF_KEEP
$ds@to-gen3-1
$ds@to-gen3-2
$ds@verified-20261031
$ds@pre-daily-20260101
$ds@daily-manual
$ds@daily-20260101-keep
$ds/child@daily-20260101
other/data/archive@daily-20260101
EOF_KEEP
tail -n 8 "$fixture/snapshots" > "$fixture/protected"
run
for tier_keep in 'daily 14' 'weekly 8' 'monthly 12'; do
    read -r tier keep <<< "$tier_keep"
    test "$(grep -Ec "^$ds@$tier-[0-9]{8}$" "$fixture/snapshots")" = "$keep"
done
while IFS= read -r name; do
    grep -Fxq "$name" "$fixture/snapshots"
done < "$fixture/protected"
grep -Fxq "destroy $ds@daily-20260101" "$fixture/calls"
grep -Fxq "$ds@daily-20261031" "$fixture/snapshots"
# Snapshot failure must prevent all pruning; destroy failure must be nonzero.
: > "$fixture/calls"
if FAIL=snapshot TEST_DATE='20261101 7 01' run; then exit 1; fi
if grep -q '^destroy ' "$fixture/calls"; then exit 1; fi
printf '%s@daily-20260100\n' "$ds" >> "$fixture/snapshots"
if FAIL=destroy run; then exit 1; fi
# A competing invocation does not run ZFS at all.
reset
exec 8> "$ARCHIVE_SNAPSHOT_LOCKFILE"
flock -n 8
run
test ! -s "$fixture/calls"
flock -u 8

echo 'archive snapshot fixture: ok'
