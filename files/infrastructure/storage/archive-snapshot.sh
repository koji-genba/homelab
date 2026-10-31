#!/bin/bash
set -euo pipefail
# cron has a minimal PATH; zfs is normally installed in /usr/sbin.
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
DATASET=tank-gen3/data/archive
LOCKFILE=${ARCHIVE_SNAPSHOT_LOCKFILE:-/var/run/archive-snapshot.lock}
LOGFILE=${ARCHIVE_SNAPSHOT_LOGFILE:-/var/log/archive-snapshot.log}
exec >> "$LOGFILE" 2>&1
log() { echo "$(date '+%F %T') $*"; }
trap 'log "ERROR: archive snapshot failed (line $LINENO)"' ERR

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log 'already running, skip'
    exit 0
fi

if ! zfs list -H -o name "$DATASET" >/dev/null; then
    log "ERROR: $DATASET does not exist, abort"
    exit 1
fi
if [ "$(zfs get -H -o value mounted "$DATASET")" != yes ]; then
    log "ERROR: $DATASET not mounted, abort"
    exit 1
fi
log 'start'
# Capture the date once, including weekday/monthday, to avoid a midnight rollover.
read -r TODAY DOW DOM <<< "$(date '+%Y%m%d %u %d')"
# Keep listing errors fatal; process substitution would hide them.
snapshots=$(zfs list -H -t snapshot -o name -s creation "$DATASET")
snapshot() {
    local name="${DATASET}@$1-${TODAY}"
    if grep -Fxq "$name" <<< "$snapshots"; then
        log "snapshot $name already exists, skip"
    else
        zfs snapshot "$name"
        log "snapshot $name"
    fi
}

# Daily protection even without writes; extra tiers use mover's calendar rules.
snapshot daily
if [ "$DOM" = 01 ]; then
    snapshot monthly
elif [ "$DOW" = 1 ]; then
    snapshot weekly
fi

snapshots=$(zfs list -H -t snapshot -o name -s creation "$DATASET")
prune() {
    local tier=$1 keep=$2 name
    local -a owned=()
    while IFS= read -r name; do
        # Exact dataset and date-shaped names only, never children or manual tags.
        if [[ "$name" =~ ^${DATASET}@${tier}-[0-9]{8}$ ]]; then
            owned+=("$name")
        fi
    done <<< "$snapshots"
    local excess=$((${#owned[@]} - keep)) i
    for ((i=0; i<excess; i++)); do
        zfs destroy "${owned[i]}"
        log "destroy ${owned[i]}"
    done
}
prune daily 14
prune weekly 8
prune monthly 12
log 'done'
