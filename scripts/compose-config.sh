#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
mkdir -p "$tmp_dir/secrets" "$tmp_dir/data"
: >"$tmp_dir/secrets/edge.env"
: >"$tmp_dir/secrets/gatus.env"
: >"$tmp_dir/secrets/sillytavern.env"
: >"$tmp_dir/secrets/healthchecks.env"
mkdir -p "$tmp_dir/secrets/samba"
: >"$tmp_dir/secrets/samba/koji-genba-password"

cat >"$tmp_dir/env" <<EOF
SECRETS_DIR=$tmp_dir/secrets
ADGUARD_CONFIG_DIR=$tmp_dir/adguard
ACME_EMAIL=operator@example.invalid
GATUS_BASIC_AUTH_USER=operator
CADDY_TRUSTED_NETWORKS=192.168.10.0/24 192.168.11.0/24 192.168.20.0/24 100.64.0.0/10
EDGE_BIND_IP=0.0.0.0
DNS_BIND_IP=0.0.0.0
SMB_BIND_IP=0.0.0.0
SHARED_MOUNT_PATH=$tmp_dir/data
SHARED_HDD_MOUNT_PATH=$tmp_dir/data
ARCHIVE_MOUNT_PATH=$tmp_dir/data
STASHPAD_MEDIA_MOUNT_PATH=$tmp_dir/data
STASHPAD_DATA_PATH=$tmp_dir/data
STASHPAD_STAGING_DATA_PATH=$tmp_dir/data
SILLYTAVERN_DATA_PATH=$tmp_dir/data
EOF
mkdir -p "$tmp_dir/adguard"

find "$repo_root/files/services/compose" -mindepth 2 -maxdepth 2 -name compose.yaml -print |
while IFS= read -r file; do
  project=$(basename "$(dirname "$file")")
  echo "checking $project"
  docker compose --project-name "lint-$project" --env-file "$tmp_dir/env" \
    --file "$file" config --quiet
done
