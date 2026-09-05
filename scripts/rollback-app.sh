#!/bin/sh
set -eu

project=${PROJECT:-}
rollback_sha=${ROLLBACK_SHA:-}
host=${APPS_HOST:-192.168.10.42}
user=${APPS_USER:-deploy}

case "$project" in
  edge|dns|samba|stashpad-prod|stashpad-staging|sillytavern|monitoring) ;;
  *) echo "PROJECT must name one Compose project" >&2; exit 2 ;;
esac
case "$rollback_sha" in
  ''|*[!0-9a-fA-F]*) echo "ROLLBACK_SHA must be a commit SHA" >&2; exit 2 ;;
esac

exec ssh "$user@$host" sudo /usr/local/sbin/homelab-rollback-app "$project" "$rollback_sha"
