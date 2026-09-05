#!/bin/sh
set -eu

test "$#" -gt 0 || {
  echo "usage: homelab-toolbox COMMAND [ARG...]" >&2
  exit 2
}
umask 077
mkdir -p "$HOME"
chmod 0700 "$HOME"
# The arbitrary host UID/GID is intentionally not added to /etc/passwd. Python
# tools such as ansible-lint use getpass.getuser(), which falls back to USER or
# LOGNAME when that UID has no passwd entry.
: "${USER:=homelab-toolbox}"
: "${LOGNAME:=$USER}"
export USER LOGNAME
exec "$@"
