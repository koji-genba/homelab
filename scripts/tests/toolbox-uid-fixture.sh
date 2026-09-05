#!/bin/sh
set -eu

uid="$(id -u)"
gid="$(id -g)"
passwd_record="$(getent passwd "$uid")"
group_record="$(getent group "$gid")"

test -n "$passwd_record"
test -n "$group_record"
test "$(printf '%s\n' "$passwd_record" | cut -d: -f3)" = "$uid"
test "$(printf '%s\n' "$group_record" | cut -d: -f3)" = "$gid"

# OpenSSH performs this passwd lookup before connecting. A refused connection
# is expected in the fixture; the old failure must not be present.
ssh_output="$(ssh -o BatchMode=yes -o ConnectTimeout=1 -p 1 127.0.0.1 true 2>&1 || true)"
case "$ssh_output" in
  *"No user exists for uid"*)
    echo "$ssh_output" >&2
    exit 1
    ;;
esac

echo "toolbox arbitrary UID/GID fixture: ok"
