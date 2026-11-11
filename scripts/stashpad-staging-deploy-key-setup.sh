#!/bin/bash
# Operator-only: provision what .github/workflows/stashpad-staging-image.yml
# needs to push the staging digest to main with a deploy key.
#
#   1. environment stashpad-staging-bot, limited to the main branch
#   2. Actions secret STASHPAD_STAGING_DEPLOY_KEY in that environment
#   3. a write-enabled deploy key titled stashpad-staging-bot
#
# Run it on the operator terminal with your own `gh` login. Never run it from
# Hermes/Runner and never give it an App or CI token. The private key is created
# in a private temporary directory, sent to GitHub through stdin, and removed
# as soon as it is stored; it is never printed. Procedure and incident handling:
# docs/operations/hermes-agent.md (homelab の GitHub Actions による main 更新).
set -euo pipefail

readonly default_repo=koji-genba/homelab
readonly env_name=stashpad-staging-bot
readonly key_title=stashpad-staging-bot
readonly secret_name=STASHPAD_STAGING_DEPLOY_KEY
readonly branch_name=main

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [owner/repo]

Creates (or updates) the main-only environment ${env_name}, stores a fresh
ed25519 private key as its Actions secret ${secret_name}, and registers the
public half as the write-enabled deploy key "${key_title}" of owner/repo
(default ${default_repo}).

  --dry-run   Read-only checks (login, admin access, duplicate deploy key,
              current environment) and a printed plan. Nothing is created,
              changed or generated.

Stops if a deploy key titled "${key_title}" already exists. To rotate, delete
that key first (gh repo deploy-key delete <id> --repo owner/repo), then rerun.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

dry_run=0
repo=$default_repo
repo_given=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $arg" ;;
    *)
      [[ $repo_given -eq 0 ]] || { usage >&2; die "only one owner/repo may be given"; }
      repo=$arg
      repo_given=1
      ;;
  esac
done
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must look like owner/repo: $repo"

gh_api() {
  gh api --hostname github.com -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

command -v gh > /dev/null || die "gh is required"
command -v ssh-keygen > /dev/null || die "ssh-keygen is required"
# Use the operator's stored login only: a token in the environment would be
# used instead of it and could belong to something other than the operator.
if [[ -n ${GH_TOKEN:-} || -n ${GITHUB_TOKEN:-} || -n ${GH_ENTERPRISE_TOKEN:-} ]]; then
  die "unset GH_TOKEN / GITHUB_TOKEN / GH_ENTERPRISE_TOKEN and use your own 'gh auth login'"
fi
gh auth status --hostname github.com > /dev/null 2>&1 || die "not logged in: run 'gh auth login' as the repository owner"

# Needs the 'repo' scope for every call below (deploy keys, environments,
# environment secrets). A 403/404 here usually means a missing scope or a
# login that is not the repository owner: use the web UI steps in the docs.
admin=$(gh_api "repos/$repo" --jq '.permissions.admin' 2> /dev/null) \
  || die "cannot read $repo with this login (missing 'repo' scope or no access)"
[[ $admin == true ]] || die "this login is not an admin/owner of $repo"
private=$(gh_api "repos/$repo" --jq '.private')
if [[ $private == true ]]; then
  echo "warning: $repo is private. GitHub Free ignores environment secrets and deployment" >&2
  echo "         branch limits on private repositories; confirm the plan before relying on them." >&2
fi

existing_titles=$(gh_api --paginate "repos/$repo/keys" --jq '.[].title') \
  || die "cannot list deploy keys of $repo"
if grep -Fxq -- "$key_title" <<< "$existing_titles"; then
  die "a deploy key titled '$key_title' already exists in $repo; delete it first (see --help)"
fi

env_exists=0
if gh_api "repos/$repo/environments/$env_name" > /dev/null 2>&1; then
  env_exists=1
fi

cat <<EOF
repository   : $repo
environment  : $env_name ($([[ $env_exists -eq 1 ]] && echo 'exists: will be updated' || echo 'will be created')), deployment branches limited to '$branch_name'
secret       : $secret_name (environment secret, replaced if present)
deploy key   : '$key_title', ed25519, write access, added after the secret is stored
EOF

if [[ $dry_run -eq 1 ]]; then
  echo "dry-run: no changes made"
  exit 0
fi

# --- environment: only runs on main may use it ------------------------------
# PUT also resets rules that are not sent (wait timer, reviewers). This
# environment is dedicated to the staging job, so none are expected.
printf '%s\n' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  | gh_api --method PUT "repos/$repo/environments/$env_name" --input - > /dev/null \
  || die "cannot create or update environment $env_name"

policy_path="repos/$repo/environments/$env_name/deployment-branch-policies"
policies=$(gh_api --paginate "$policy_path" --jq '.branch_policies[] | "\(.id)|\(.type // "branch")|\(.name)"') \
  || die "cannot list deployment branch policies of $env_name"
has_main=0
while IFS='|' read -r policy_id policy_type policy_name; do
  [[ -n $policy_id ]] || continue
  if [[ $policy_type == branch && $policy_name == "$branch_name" ]]; then
    has_main=1
  else
    echo "removing deployment policy: $policy_type $policy_name"
    gh_api --method DELETE "$policy_path/$policy_id" > /dev/null < /dev/null \
      || die "cannot remove deployment policy $policy_id"
  fi
done <<< "$policies"
if [[ $has_main -eq 0 ]]; then
  gh_api --method POST "$policy_path" -f "name=$branch_name" -f type=branch > /dev/null \
    || die "cannot add the '$branch_name' deployment branch policy"
fi

# --- key pair: private half lives only in a private temp dir ----------------
umask 077
base=/dev/shm
[[ -d $base && -w $base ]] || base=${TMPDIR:-/tmp}
workdir=$(mktemp -d "$base/stashpad-deploy-key.XXXXXX")
cleanup() {
  rm -rf -- "$workdir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ssh-keygen -q -t ed25519 -N '' -C "$key_title" -f "$workdir/key"

# Secret first: if a later step fails, the rerun starts clean instead of
# leaving a write-enabled deploy key whose private half was already discarded.
gh secret set "$secret_name" --env "$env_name" --repo "$repo" < "$workdir/key" > /dev/null \
  || die "cannot store the environment secret (private key discarded; rerun)"
rm -f -- "$workdir/key"

result=$(gh_api --method POST "repos/$repo/keys" \
  -f "title=$key_title" -f "key=$(< "$workdir/key.pub")" -F read_only=false \
  --jq '"\(.id) \(.read_only)"') \
  || die "cannot add the deploy key (secret is stored; rerun to replace both)"
read -r key_id key_read_only <<< "$result"
fingerprint=$(ssh-keygen -lf "$workdir/key.pub")

if [[ $key_read_only != false ]]; then
  die "deploy key $key_id was created read-only; delete it and rerun"
fi

echo "deploy key   : id $key_id, write access"
echo "fingerprint  : $fingerprint"
echo "secrets in $env_name:"
gh secret list --env "$env_name" --repo "$repo"
echo "deployment branch policies of $env_name:"
gh_api --paginate "$policy_path" --jq '.branch_policies[] | "  \(.type // "branch") \(.name)"'
echo "done. Next: run the workflow once by hand (docs/operations/hermes-agent.md)."
