#!/bin/sh
set -eu

# Validate a rendered runtime config only when the exact image is already
# present locally. The --pull=never guard makes this target safe to run during
# review: it never downloads an image or contacts a registry.
config_file=${1:-${ADGUARD_CONFIG_FILE:-}}
# Official v0.107.79 Linux amd64 binary checksum. Set ADGUARD_BINARY when the
# locally verified toolbox binary is used instead of the pinned container.
image=${ADGUARD_IMAGE:-adguard/adguardhome:v0.107.79}
official_binary_sha256=7e247573e63ce771a5925d16ca4ca9344e6e888673244289dc302f0fdfdfbf4e
test -n "$config_file" || {
  echo "usage: $0 /path/to/rendered/AdGuardHome.yaml" >&2
  exit 2
}
test -r "$config_file" || { echo "config is not readable: $config_file" >&2; exit 1; }
if test -n "${ADGUARD_BINARY:-}"; then
  test -x "$ADGUARD_BINARY" || { echo "AdGuard binary is not executable: $ADGUARD_BINARY" >&2; exit 1; }
  printf '%s  %s\n' "$official_binary_sha256" "$ADGUARD_BINARY" | sha256sum -c -
  "$ADGUARD_BINARY" --check-config -c "$config_file"
  exit 0
fi
docker image inspect "$image" >/dev/null 2>&1 || {
  echo "skipped: image is not present locally (no pull performed): $image" >&2
  exit 0
}
config_dir=$(CDPATH='' cd -- "$(dirname -- "$config_file")" && pwd)
docker run --rm --pull=never --entrypoint /opt/adguardhome/AdGuardHome \
  -v "$config_dir:/opt/adguardhome/conf:ro" "$image" \
  --check-config -c /opt/adguardhome/conf/AdGuardHome.yaml
