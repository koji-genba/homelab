#!/bin/bash
# Host prompts only; no plaintext file or secret command-line argument.
set -euo pipefail
set +x
provider=${1:-}
case "$provider" in
  proxmox|tailscale) ;;
  *) echo 'PROVIDER must be proxmox or tailscale' >&2; exit 1 ;;
esac
cd "$(dirname "$0")/.."
target="files/infrastructure/secrets/operator/$provider.sops.yaml"
if [[ -e "$target" || -L "$target" ]]; then
  read -r -p 'Replace existing operator bundle? [y/N] ' answer
  [[ "$answer" == y ]] || exit 1
fi
fields=(TF_VAR_proxmox_api_token)
if [[ "$provider" == tailscale ]]; then
  read -r -p 'Authentication [oauth/api] (oauth): ' mode
  case "${mode:-oauth}" in
    oauth) fields=(TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET) ;;
    api) fields=(TAILSCALE_API_KEY) ;;
    *) echo 'Choose oauth or api' >&2; exit 1 ;;
  esac
fi
# A subshell owns input and the pipe. The serializer receives only stdin.
{
  for field in "${fields[@]}"; do
    read -rs -p "$field: " value
    printf '\n' >&2
    [[ -n "$value" ]] || { echo 'Empty credential rejected' >&2; exit 1; }
    printf '%s\0%s\0' "$field" "$value"
  done
} | python3 -c 'import json,sys; a=sys.stdin.buffer.read().decode().split("\0")[:-1]; json.dump(dict(zip(a[::2],a[1::2])),sys.stdout)' \
  | make --no-print-directory --silent _operator-secrets-encrypt PROVIDER="$provider"
