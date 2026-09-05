#!/bin/sh
set -eu

test "$#" -gt 0 || {
  echo "usage: homelab-toolbox COMMAND [ARG...]" >&2
  exit 2
}
umask 077
mkdir -p "$HOME"
chmod 0700 "$HOME"
: "${USER:=homelab-toolbox}"
: "${LOGNAME:=$USER}"
export USER LOGNAME

# Docker runs this image as the invoking host UID/GID so files created in the
# checkout remain owned by that user. That UID normally has no record in the
# image's /etc/passwd, which makes OpenSSH abort before it can connect. NSS
# wrapper supplies a private passwd/group view for the process tree without
# needing root, modifying /etc/passwd, or changing the container user.
case "$USER" in
  ''|*[!A-Za-z0-9._-]*)
    echo "USER must contain only letters, digits, '.', '_' or '-'" >&2
    exit 1
    ;;
esac

uid="$(id -u)"
gid="$(id -g)"
passwd_record="$(getent passwd "$uid" || true)"
group_record="$(getent group "$gid" || true)"
passwd_name="$(printf '%s\n' "$passwd_record" | cut -d: -f1)"
group_name="$(printf '%s\n' "$group_record" | cut -d: -f1)"
if test "$passwd_name" != "$USER" || test "$group_name" != "$USER"; then
  nss_dir="$(mktemp -d "$HOME/.nss.XXXXXX")"
  # Keep the base image's records available to child tools, while removing
  # possible name/ID collisions before adding the current identity.
  awk -F: -v name="$USER" -v id="$uid" '$1 != name && $3 != id' /etc/passwd > "$nss_dir/passwd"
  awk -F: -v name="$USER" -v id="$gid" '$1 != name && $3 != id' /etc/group > "$nss_dir/group"
  printf '%s:x:%s:%s::%s:/bin/sh\n' "$USER" "$uid" "$gid" "$HOME" >> "$nss_dir/passwd"
  printf '%s:x:%s:\n' "$USER" "$gid" >> "$nss_dir/group"
  export NSS_WRAPPER_PASSWD="$nss_dir/passwd"
  export NSS_WRAPPER_GROUP="$nss_dir/group"
  export LD_PRELOAD="/usr/local/lib/libnss_wrapper.so${LD_PRELOAD:+:$LD_PRELOAD}"
fi

exec "$@"
