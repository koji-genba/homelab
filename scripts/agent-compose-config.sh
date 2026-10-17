#!/bin/sh
# Validate the Agent VM Compose project without a live host.
#
# The project deliberately lives outside files/services/compose/ so the Apps VM
# reconciler, its digest gate and scripts/compose-config.sh never see it, but it
# still has to pass the same static discipline: `docker compose config` with
# synthetic env/secret files and an all-images-digest check.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
compose_dir="$repo_root/files/services/agent/stack"
compose_file="$compose_dir/compose.yaml"

test -f "$compose_file" || {
  echo "missing Agent Compose file: $compose_file" >&2
  exit 1
}

# Guard the placement rule: the project must stay out of the Apps VM scan path.
case "$compose_dir" in
  "$repo_root/files/services/compose/"*)
    echo "Agent Compose project must not live under files/services/compose/" >&2
    exit 1
    ;;
esac

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
mkdir -p "$tmp_dir/secrets/ssh" "$tmp_dir/data/hermes" "$tmp_dir/data/postgres" "$tmp_dir/data/models"

printf '%s\n' POSTGRES_PASSWORD=fixture-only >"$tmp_dir/secrets/memory-db.env"
cat >"$tmp_dir/secrets/hermes.env" <<'EOF'
DISCORD_BOT_TOKEN=fixture-only
DISCORD_ALLOWED_USERS=0
DISCORD_HOME_CHANNEL=0
EOF

# SSH identities only have to exist for the bind mounts; contents are never read.
: >"$tmp_dir/secrets/ssh/id_ed25519"
: >"$tmp_dir/secrets/ssh/cdp_tunnel_ed25519"
: >"$tmp_dir/secrets/ssh/known_hosts"

cat >"$tmp_dir/compose.env" <<EOF
SECRETS_DIR=$tmp_dir/secrets
AGENT_SSH_KEY_DIR=$tmp_dir/secrets/ssh
HERMES_DATA_DIR=$tmp_dir/data/hermes
POSTGRES_DATA_DIR=$tmp_dir/data/postgres
MODELS_DIR=$tmp_dir/data/models
APPS_VM_LAN_IP=192.168.10.101
SEARXNG_FQDN=searxng.example.invalid
MCP_SEARXNG_FQDN=mcp-searxng.example.invalid
TEI_EMBEDDING_MODEL=/data/models--cl-nagoya--ruri-v3-310m/snapshots/0000000000000000000000000000000000000000
TEI_EMBEDDING_REVISION=0000000000000000000000000000000000000000
TEI_RERANKER_MODEL=/data/models--cl-nagoya--ruri-v3-reranker-310m/snapshots/0000000000000000000000000000000000000000
TEI_RERANKER_REVISION=0000000000000000000000000000000000000000
TEI_RERANKER_CPUS=6
TEI_RERANKER_THREADS=6
TEI_RERANKER_TOKENIZATION_WORKERS=6
TEI_RERANKER_MAX_BATCH_REQUESTS=1
HINDSIGHT_EMBEDDINGS_QUERY_PREFIX="検索クエリ: "
HINDSIGHT_EMBEDDINGS_PASSAGE_PREFIX="検索文書: "
HINDSIGHT_EMBEDDINGS_MAX_INPUT_TOKENS=4096
HINDSIGHT_RERANKER_MAX_CANDIDATES_LOW=8
HINDSIGHT_RERANKER_MAX_CANDIDATES_MID=20
HINDSIGHT_RERANKER_MAX_CANDIDATES_HIGH=30
HINDSIGHT_LLM_BASE_URL=http://192.168.10.51:8000/v1
HINDSIGHT_LLM_MODEL=glm-5.3-flash
HINDSIGHT_LLM_MAX_CONCURRENT=1
HINDSIGHT_LLM_REASONING_EFFORT=low
HINDSIGHT_LLM_STRICT_SCHEMA=true
AGENT_TIMEZONE=Asia/Tokyo
CDP_TUNNEL_PORT=9222
CDP_RUNNER_TARGET=hermes-cdp@192.168.10.105
EOF

echo "checking agent"
docker compose \
  --project-name "lint-agent" \
  --env-file "$tmp_dir/compose.env" \
  --env-file "$tmp_dir/secrets/memory-db.env" \
  --file "$compose_file" \
  config --quiet

# Every service image must be pinned to a 64-hex digest. This mirrors the Apps
# VM helper gate and the repo-wide digest convention.
pins=$(grep -E '^[[:space:]]*image:' "$compose_file" || true)
test -n "$pins" || {
  echo "no image lines found in $compose_file" >&2
  exit 1
}
bad=$(printf '%s\n' "$pins" | grep -vE '@sha256:[0-9a-f]{64}[[:space:]]*$' || true)
if [ -n "$bad" ]; then
  echo "Agent Compose images are not digest-pinned:" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi

echo "agent compose config: ok"
