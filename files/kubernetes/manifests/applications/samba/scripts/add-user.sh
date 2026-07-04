#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMBA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
USERS_FILE="${SAMBA_USERS_FILE:-${SAMBA_DIR}/config/users.json}"
SECRETS_TEMPLATE="${SAMBA_SECRETS_TEMPLATE:-${SAMBA_DIR}/config/secrets.json.template}"

usage() {
    cat <<'EOF'
Usage:
  scripts/add-user.sh USERNAME UID [options]

Options:
  --gid GID             Primary GID (default: 10002)
  --groups LIST         Supplementary groups, comma-separated (default: samba-users)
  --rid RID             Samba RID (default: UID - 9000 for UID 10001-10999)
  --password-key KEY    Secret key name (default: USERNAME-password)
  --home PATH           Home directory (default: /nonexistent)
  --shell PATH          Login shell (default: /usr/sbin/nologin)

Environment:
  SAMBA_USERS_FILE          Override users.json path
  SAMBA_SECRETS_TEMPLATE   Override secrets.json.template path
EOF
}

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi

username="$1"
uid="$2"
shift 2

gid="10002"
groups="samba-users"
rid=""
password_key="${username}-password"
home="/nonexistent"
shell="/usr/sbin/nologin"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --gid)
            gid="$2"
            shift 2
            ;;
        --groups)
            groups="$2"
            shift 2
            ;;
        --rid)
            rid="$2"
            shift 2
            ;;
        --password-key)
            password_key="$2"
            shift 2
            ;;
        --home)
            home="$2"
            shift 2
            ;;
        --shell)
            shell="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    echo "ERROR: Invalid username: $username" >&2
    exit 1
fi

if [[ ! "$uid" =~ ^[0-9]+$ ]] || [ "$uid" -lt 1000 ]; then
    echo "ERROR: UID must be a number >= 1000" >&2
    exit 1
fi

if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
    echo "ERROR: GID must be a number" >&2
    exit 1
fi

if [ -z "$rid" ]; then
    if [ "$uid" -lt 10001 ] || [ "$uid" -gt 10999 ]; then
        echo "ERROR: UID ${uid} is outside the default RID range. Use --rid to set a stable RID." >&2
        exit 1
    fi
    rid=$((uid - 9000))
fi

if [[ ! "$rid" =~ ^[0-9]+$ ]] || [ "$rid" -lt 1000 ]; then
    echo "ERROR: Calculated RID is ${rid}. Use --rid to set a stable RID >= 1000." >&2
    exit 1
fi

if [[ ! "$password_key" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: Invalid password key: $password_key" >&2
    exit 1
fi

if [ ! -f "$USERS_FILE" ]; then
    echo "ERROR: users file not found: $USERS_FILE" >&2
    exit 1
fi

jq empty "$USERS_FILE" >/dev/null

groups_json="$(printf '%s' "$groups" | jq -R 'split(",") | map(select(length > 0))')"

if jq -e --arg name "$username" '.users[]? | select(.name == $name)' "$USERS_FILE" >/dev/null; then
    echo "ERROR: User already exists: $username" >&2
    exit 1
fi

if jq -e --argjson uid "$uid" '.users[]? | select(.uid == $uid)' "$USERS_FILE" >/dev/null; then
    echo "ERROR: UID already exists: $uid" >&2
    exit 1
fi

if jq -e --argjson rid "$rid" '.users[]? | select((.rid // (.uid - 9000)) == $rid)' "$USERS_FILE" >/dev/null; then
    echo "ERROR: RID already exists: $rid" >&2
    exit 1
fi

if ! jq -e --argjson gid "$gid" '.groups[]? | select(.gid == $gid)' "$USERS_FILE" >/dev/null; then
    echo "ERROR: Primary GID is not declared in users.json: $gid" >&2
    exit 1
fi

while IFS= read -r group; do
    if ! jq -e --arg group "$group" '.groups[]? | select(.name == $group)' "$USERS_FILE" >/dev/null; then
        echo "ERROR: Supplementary group is not declared in users.json: $group" >&2
        exit 1
    fi
done < <(jq -r '.[]' <<<"$groups_json")

tmp_users="$(mktemp)"
jq \
    --arg name "$username" \
    --argjson uid "$uid" \
    --argjson gid "$gid" \
    --argjson rid "$rid" \
    --argjson groups "$groups_json" \
    --arg home "$home" \
    --arg shell "$shell" \
    --arg password_key "$password_key" \
    '.users += [{
        name: $name,
        uid: $uid,
        gid: $gid,
        rid: $rid,
        groups: $groups,
        home: $home,
        shell: $shell,
        passwordSecretKey: $password_key
    }]' "$USERS_FILE" > "$tmp_users"
mv "$tmp_users" "$USERS_FILE"

if [ -f "$SECRETS_TEMPLATE" ]; then
    tmp_secrets="$(mktemp)"
    jq --arg key "$password_key" 'if has($key) then . else . + {($key): "CHANGE_ME"} end' \
        "$SECRETS_TEMPLATE" > "$tmp_secrets"
    mv "$tmp_secrets" "$SECRETS_TEMPLATE"
fi

echo "Added Samba user:"
echo "  name: $username"
echo "  uid:  $uid"
echo "  gid:  $gid"
echo "  rid:  $rid"
echo "  sid:  $(jq -r '.localSid' "$USERS_FILE")-${rid}"
echo "  passwordSecretKey: $password_key"
