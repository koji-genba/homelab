#!/bin/bash
set -euo pipefail

if [ -n "${DEBUG_ENTRYPOINT:-}" ]; then
    set -x
fi

SMBD_CONFIG="/etc/samba/smb.conf"
USER_CONFIG="/etc/samba/users/users.json"
SECRET_DIR="/run/samba-secrets"

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARNING] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

require_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        log_error "Required file not found: $path"
        exit 1
    fi
}

ensure_group() {
    local name="$1"
    local gid="$2"
    local existing

    existing="$(getent group "$name" || true)"
    if [ -n "$existing" ]; then
        if [ "$(echo "$existing" | cut -d: -f3)" != "$gid" ]; then
            log_error "Group $name exists with unexpected GID: $existing"
            exit 1
        fi
        return
    fi

    existing="$(getent group "$gid" || true)"
    if [ -n "$existing" ]; then
        log_error "GID $gid is already used by another group: $existing"
        exit 1
    fi

    groupadd --gid "$gid" "$name"
}

ensure_user() {
    local name="$1"
    local uid="$2"
    local gid="$3"
    local groups="$4"
    local home="$5"
    local shell="$6"
    local existing

    existing="$(getent passwd "$name" || true)"
    if [ -n "$existing" ]; then
        if [ "$(echo "$existing" | cut -d: -f3)" != "$uid" ] ||
           [ "$(echo "$existing" | cut -d: -f4)" != "$gid" ]; then
            log_error "User $name exists with unexpected UID/GID: $existing"
            exit 1
        fi
    else
        existing="$(getent passwd "$uid" || true)"
        if [ -n "$existing" ]; then
            log_error "UID $uid is already used by another user: $existing"
            exit 1
        fi
        useradd --uid "$uid" --gid "$gid" --no-create-home --home-dir "$home" --shell "$shell" "$name"
    fi

    if [ -n "$groups" ]; then
        usermod --append --groups "$groups" "$name"
    fi
}

configure_samba_account() {
    local name="$1"
    local secret_key="$2"
    local rid="$3"
    local password_file="$SECRET_DIR/$secret_key"
    local password
    local xtrace_was_on=0

    require_file "$password_file"

    case "$-" in
        *x*)
            xtrace_was_on=1
            set +x
            ;;
    esac

    password="$(cat "$password_file")"
    if [ -z "$password" ]; then
        log_error "Password secret is empty: $secret_key"
        exit 1
    fi

    printf '%s\n%s\n' "$password" "$password" | smbpasswd -a -s "$name" >/dev/null
    if [ -n "$rid" ]; then
        pdbedit --modify --user "$name" -U "$rid" >/dev/null
    fi
    smbpasswd -e "$name" >/dev/null

    if [ "$xtrace_was_on" -eq 1 ]; then
        set -x
    fi
}

log_info "Starting Samba configuration..."

require_file "$SMBD_CONFIG"
require_file "$USER_CONFIG"

if ! jq empty "$USER_CONFIG" >/dev/null; then
    log_error "Invalid Samba user configuration: $USER_CONFIG"
    exit 1
fi

log_info "Ensuring local groups..."
while IFS= read -r group_json; do
    group_name="$(jq -r '.name' <<<"$group_json")"
    group_gid="$(jq -r '.gid' <<<"$group_json")"
    ensure_group "$group_name" "$group_gid"
done < <(jq -c '.groups[]' "$USER_CONFIG")

log_info "Ensuring local users..."
while IFS= read -r user_json; do
    user_name="$(jq -r '.name' <<<"$user_json")"
    user_uid="$(jq -r '.uid' <<<"$user_json")"
    user_gid="$(jq -r '.gid' <<<"$user_json")"
    user_groups="$(jq -r '(.groups // []) | join(",")' <<<"$user_json")"
    user_home="$(jq -r '.home // "/nonexistent"' <<<"$user_json")"
    user_shell="$(jq -r '.shell // "/usr/sbin/nologin"' <<<"$user_json")"
    ensure_user "$user_name" "$user_uid" "$user_gid" "$user_groups" "$user_home" "$user_shell"
done < <(jq -c '.users[]' "$USER_CONFIG")

log_info "Preparing Samba runtime directories..."
mkdir -p /var/lib/samba/private /var/cache/samba /var/run/samba /var/log/samba
chmod 755 /var/lib/samba /var/cache/samba /var/run/samba /var/log/samba
chmod 700 /var/lib/samba/private

log_info "Resetting generated Samba state..."
rm -f /var/lib/samba/private/passdb.tdb
rm -f /var/lib/samba/private/secrets.tdb
rm -f /var/lib/samba/group_mapping.tdb
rm -f /var/lib/samba/*.tdb
rm -f /var/cache/samba/*.tdb
rm -f /var/run/samba/*.pid 2>/dev/null || true

local_sid="$(jq -r '.localSid // empty' "$USER_CONFIG")"
if [ -n "$local_sid" ]; then
    log_info "Setting Samba local SID..."
    net setlocalsid "$local_sid" >/dev/null
    net getlocalsid
else
    log_warn "No localSid configured; Samba will generate one"
fi

log_info "Configuring Samba accounts..."
while IFS= read -r user_json; do
    user_name="$(jq -r '.name' <<<"$user_json")"
    secret_key="$(jq -r '.passwordSecretKey // empty' <<<"$user_json")"
    user_rid="$(jq -r '.rid // empty' <<<"$user_json")"
    if [ -z "$secret_key" ]; then
        log_warn "Skipping Samba account for $user_name because passwordSecretKey is not set"
        continue
    fi
    configure_samba_account "$user_name" "$secret_key" "$user_rid"
done < <(jq -c '.users[]' "$USER_CONFIG")

log_info "Ensuring share mount points exist..."
mkdir -p /mnt/shared /mnt/shared-hdd /mnt/archive

log_info "Validating smb.conf..."
testparm -s "$SMBD_CONFIG" >/dev/null

log_info "Samba accounts:"
pdbedit -L

log_info "Samba initialization complete"
log_info "Starting smbd daemon..."
exec /usr/sbin/smbd --foreground --no-process-group -d 3 -s "$SMBD_CONFIG" 2>&1
