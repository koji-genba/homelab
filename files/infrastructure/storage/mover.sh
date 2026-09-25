#!/bin/bash
SETTLE_MINUTES=${SETTLE_MINUTES:-30}
SRC=${SRC:-/mnt/cache-sata}
DST=${DST:-/mnt/tank-gen2/data/shared}
DATASET=tank-gen2/data/shared
LOCKFILE=${MOVER_LOCKFILE:-/var/run/mover.lock}
LOGFILE=${MOVER_LOGFILE:-/var/log/mover.log}

exec >> "$LOGFILE" 2>&1

if ! mountpoint -q "$SRC" || ! mountpoint -q "$DST"; then
    echo "$(date '+%F %T') ERROR: $SRC or $DST not mounted, abort"
    exit 1
fi

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "$(date '+%F %T') already running, skip"
    exit 0
fi

echo "$(date '+%F %T') start (SETTLE_MINUTES=${SETTLE_MINUTES})"

errors=0
while IFS= read -r -d '' src_file; do
    rel="${src_file#$SRC/}"
    dst_file="$DST/$rel"

    source_before=$(stat -c '%Y:%u:%g' "$src_file" 2>/dev/null) || continue

    # /./ marks the start of the destination-relative path. With --relative,
    # rsync also creates the parent directories with their source metadata.
    if rsync -a --numeric-ids --relative "$SRC/./$rel" "$DST/"; then
        source_after=$(stat -c '%Y:%u:%g' "$src_file" 2>/dev/null)
        if [ "$source_before" != "$source_after" ]; then
            rm -f "$dst_file"
            echo "SKIP (modified during transfer): $rel"
        elif [ "$(stat -c '%u:%g' "$dst_file" 2>/dev/null)" != "${source_after#*:}" ]; then
            rm -f "$dst_file"
            echo "FAILED (owner mismatch): $rel"
            ((errors++))
        else
            rm -f "$src_file"
            echo "moved: $rel"
        fi
    else
        rm -f "$dst_file"
        echo "FAILED: $rel"
        ((errors++))
    fi
done < <(find "$SRC" -type f -cmin +${SETTLE_MINUTES} -print0)

find "$SRC" -mindepth 1 -type d -empty -delete

echo "$(date '+%F %T') done (errors=${errors})"

if [ "$errors" -gt 0 ]; then
    echo "$(date '+%F %T') snapshot skipped due to errors"
    exit 1
fi

# --- snapshot ---
TODAY=$(date +%Y-%m-%d)
DOW=$(date +%u)   # 1=月曜
DOM=$(date +%d)   # 01-31

# 月次（毎月1日）
if [ "$DOM" = "01" ]; then
    zfs snapshot "${DATASET}@monthly-${TODAY}"
    echo "$(date '+%F %T') snapshot monthly-${TODAY}"
    # 12世代超を削除
    zfs list -H -t snapshot -o name -s creation "$DATASET" \
        | grep "@monthly-" | head -n -12 | xargs -r -n1 zfs destroy
# 週次（月曜、ただし月次と重複しない）
elif [ "$DOW" = "1" ]; then
    zfs snapshot "${DATASET}@weekly-${TODAY}"
    echo "$(date '+%F %T') snapshot weekly-${TODAY}"
    # 8世代超を削除
    zfs list -H -t snapshot -o name -s creation "$DATASET" \
        | grep "@weekly-" | head -n -8 | xargs -r -n1 zfs destroy
# 日次
else
    zfs snapshot "${DATASET}@daily-${TODAY}"
    echo "$(date '+%F %T') snapshot daily-${TODAY}"
    # 14世代超を削除
    zfs list -H -t snapshot -o name -s creation "$DATASET" \
        | grep "@daily-" | head -n -14 | xargs -r -n1 zfs destroy
fi
