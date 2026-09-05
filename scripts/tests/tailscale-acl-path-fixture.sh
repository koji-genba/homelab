#!/bin/sh
set -eu

# Exercise the host-side ACL path boundary without importing or contacting a
# tailnet. The toolbox receives only the resulting /workspace-relative path.
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)
fixture=$(mktemp -d)
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT INT TERM

mkdir -p "$fixture/repo/subdir"
printf '%s\n' '{"acls":[]}' >"$fixture/repo/subdir/policy.json"
printf '%s\n' outside >"$fixture/outside.json"

relative=$(TAILSCALE_REPO_ROOT="$fixture/repo" \
  "$repo_root/scripts/validate-tailscale-acl-path.sh" subdir/policy.json)
test "$relative" = subdir/policy.json
absolute=$(TAILSCALE_REPO_ROOT="$fixture/repo" \
  "$repo_root/scripts/validate-tailscale-acl-path.sh" \
  "$fixture/repo/subdir/policy.json")
test "$absolute" = subdir/policy.json

if TAILSCALE_REPO_ROOT="$fixture/repo" \
  "$repo_root/scripts/validate-tailscale-acl-path.sh" "$fixture/outside.json" \
  >"$fixture/outside.log" 2>&1; then
  echo "outside ACL path was unexpectedly accepted" >&2
  exit 1
fi
ln -s "$fixture/outside.json" "$fixture/repo/escape.json"
if TAILSCALE_REPO_ROOT="$fixture/repo" \
  "$repo_root/scripts/validate-tailscale-acl-path.sh" escape.json \
  >"$fixture/symlink.log" 2>&1; then
  echo "symlink ACL path was unexpectedly accepted" >&2
  exit 1
fi

echo "Tailscale ACL path fixture: ok"
