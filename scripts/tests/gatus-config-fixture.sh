#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
config="$repo_root/files/services/compose/monitoring/config.yaml"

# Keep this check dependency-free: compose-config already validates the YAML
# syntax, while this regression protects the Caddy-specific HTTP probe option.
caddy_block=$(awk '
  /^  - name: Caddy$/ { in_block=1 }
  in_block && /^  - name:/ && !/^  - name: Caddy$/ { exit }
  in_block { print }
' "$config")

printf '%s\n' "$caddy_block" | grep -Fx '    url: http://caddy:80' >/dev/null
printf '%s\n' "$caddy_block" | grep -Fx '      ignore-redirect: true' >/dev/null
echo "Gatus Caddy probe redirect guard: ok"
