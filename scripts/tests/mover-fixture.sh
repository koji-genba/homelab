#!/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/src/a/b" "$fixture/dst"

cat > "$fixture/bin/mountpoint" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/zfs" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/stat" <<'EOF'
#!/bin/sh
if [ "${MOVER_TEST_BAD_OWNER:-}" = 1 ] && [ "$1" = -c ] &&
   [ "$2" = '%u:%g' ] && [ "$3" = "$MOVER_TEST_DST/a/b/mismatch" ]; then
    printf '0:0\n'
else
    exec /usr/bin/stat "$@"
fi
EOF
chmod +x "$fixture/bin/"*

printf 'moved data\n' > "$fixture/src/a/b/file with spaces"
chmod 0750 "$fixture/src/a"
chmod 0770 "$fixture/src/a/b"
chmod 0640 "$fixture/src/a/b/file with spaces"
mkdir -p "$fixture/dst/a"
chmod 0777 "$fixture/dst/a"
src_a_mode=$(stat -c %a "$fixture/src/a")
src_b_mode=$(stat -c %a "$fixture/src/a/b")
src_owner=$(stat -c '%u:%g' "$fixture/src/a/b/file with spaces")

run_mover() {
    PATH="$fixture/bin:$PATH" SRC="$fixture/src" DST="$fixture/dst" \
        SETTLE_MINUTES=0 MOVER_LOGFILE="$fixture/mover.log" MOVER_LOCKFILE="$fixture/mover.lock" \
        MOVER_TEST_DST="$fixture/dst" "$repo_root/files/infrastructure/storage/mover.sh"
}

run_mover
test ! -e "$fixture/src/a/b/file with spaces"
test "$(cat "$fixture/dst/a/b/file with spaces")" = 'moved data'
test "$(stat -c %a "$fixture/dst/a")" = "$src_a_mode"
test "$(stat -c %a "$fixture/dst/a/b")" = "$src_b_mode"
test "$(stat -c '%u:%g' "$fixture/dst/a/b/file with spaces")" = "$src_owner"
test "$(stat -c %a "$fixture/dst/a/b/file with spaces")" = 640

mkdir -p "$fixture/src/a/b"
printf 'must remain\n' > "$fixture/src/a/b/mismatch"
if MOVER_TEST_BAD_OWNER=1 run_mover; then
    echo 'owner mismatch was unexpectedly accepted' >&2
    exit 1
fi
test -f "$fixture/src/a/b/mismatch"
test ! -e "$fixture/dst/a/b/mismatch"
grep -q 'FAILED (owner mismatch): a/b/mismatch' "$fixture/mover.log"
grep -q 'snapshot skipped due to errors' "$fixture/mover.log"

echo 'mover fixture: ok'
