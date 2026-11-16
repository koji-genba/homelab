#!/bin/sh
set -eu
umask 077
repo_root=${STATE_LOCK_REPO_ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
ref=refs/heads/state-lock
git_repo() { git -C "$repo_root" "$@"; }
status() {
  if listing=$(git_repo ls-remote --exit-code origin "$ref"); then
    sha=${listing%%[[:space:]]*}
  else
    code=$?
    test "$code" -eq 2 || { echo 'unable to read remote state-lock' >&2; return 1; }
    sha=
    echo 'state-lock: unlocked' >&2
    return 0
  fi
  git_repo fetch --no-tags origin "$sha" >/dev/null 2>&1 || return 1
  echo "WARNING: state-lock held: $sha (read-only plans may continue; state can change during planning)" >&2
  # Only the fixed, public metadata keys are displayed; never render arbitrary
  # commit messages from a remote writer as terminal control sequences.
  git_repo show -s --format=%B "$sha" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    if not isinstance(value, dict):
        raise ValueError("invalid metadata")
    print(json.dumps({k: value.get(k) for k in ("utc", "host", "operation", "token")}, ensure_ascii=True), file=sys.stderr)
except ValueError:
    print("unrecognized lock metadata", file=sys.stderr)
'
}
case ${1:-status} in
  acquire)
    operation=${2:-terraform}
    case "$operation" in *[!a-zA-Z0-9_-]*|'') echo 'invalid lock operation' >&2; exit 2 ;; esac
    tree=$(git_repo mktree </dev/null)
    metadata=$(python3 - "$operation" <<'PY'
import datetime, json, os, re, secrets, socket, sys
host = os.environ.get('STATE_LOCK_HOST', socket.gethostname().split('.')[0])
if not re.fullmatch(r'[A-Za-z0-9_.-]{1,63}', host):
    raise SystemExit('STATE_LOCK_HOST must be a public hostname alias (1-63 ASCII hostname characters)')
print(json.dumps({'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'host': host,
                  'operation': sys.argv[1], 'token': secrets.token_hex(16)}))
PY
)
    sha=$(printf '%s\n' "$metadata" |
      GIT_AUTHOR_NAME=homelab-state-lock GIT_AUTHOR_EMAIL=homelab-state-lock@localhost \
      GIT_COMMITTER_NAME=homelab-state-lock GIT_COMMITTER_EMAIL=homelab-state-lock@localhost \
      git_repo -c commit.gpgsign=false commit-tree "$tree")
    if ! git_repo push --force-with-lease="$ref:" origin "$sha:$ref" >&2; then
      echo 'state-lock acquisition failed; inspect the existing lock before retrying' >&2
      status || true
      exit 1
    fi
    printf '%s\n' "$sha"
    ;;
  release)
    sha=${2:-}
    case "$sha" in ''|*[!0-9a-f]*) echo 'full lock SHA required' >&2; exit 2 ;; esac
    test "${#sha}" -eq 40 || { echo 'full lock SHA required' >&2; exit 2; }
    git_repo push --force-with-lease="$ref:$sha" origin ":$ref"
    ;;
  unlock)
    status
    test -n "$sha" || exit 0
    confirm=${CONFIRM:-}
    if [ "${#confirm}" -lt 12 ] || [ "${#confirm}" -gt 40 ]; then
      echo 'refusing unlock; review lock and specify CONFIRM=<at least 12 SHA characters>' >&2; exit 1;
    fi
    case "$sha" in "$confirm"*) ;; *) echo 'CONFIRM does not match lock SHA' >&2; exit 1 ;; esac
    git_repo push --force-with-lease="$ref:$sha" origin ":$ref"
    ;;
  status) status ;;
  *) echo 'usage: state-lock.sh acquire OPERATION | release SHA | status | unlock' >&2; exit 2 ;;
esac
