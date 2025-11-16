#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$SCRIPT_DIR/../openldap/bootstrap"
USER_CONFIGS_DIR="$BOOTSTRAP_DIR/user-configs"
GROUP_CONFIGS_DIR="$BOOTSTRAP_DIR/group-configs"
OUTPUT_DIR="$SCRIPT_DIR/../openldap"
OUTPUT_FILE="$OUTPUT_DIR/bootstrap-configmap.yaml"

echo "=== OpenLDAP Bootstrap LDIF Generator ==="
echo ""

# 依存ツールチェック
MISSING_TOOLS=()

if ! command -v jq >/dev/null 2>&1; then
  MISSING_TOOLS+=("jq (install: apt-get install jq)")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  echo "ERROR: Missing required tools:"
  for tool in "${MISSING_TOOLS[@]}"; do
    echo "  - $tool"
  done
  exit 1
fi

# ディレクトリ確認
if [ ! -d "$USER_CONFIGS_DIR" ]; then
  echo "ERROR: User configs directory not found: $USER_CONFIGS_DIR"
  exit 1
fi

if [ ! -d "$GROUP_CONFIGS_DIR" ]; then
  echo "ERROR: Group configs directory not found: $GROUP_CONFIGS_DIR"
  exit 1
fi

echo "Reading configurations from:"
echo "  Users:  $USER_CONFIGS_DIR"
echo "  Groups: $GROUP_CONFIGS_DIR"
echo ""

# グループ情報を読み込んでマッピングを作成
declare -A GROUP_GID_MAP
declare -A GROUP_SID_MAP
declare -A GROUP_DESC_MAP

# 事前定義グループ（固定値）
GROUP_GID_MAP["system-admins"]=10001
GROUP_SID_MAP["system-admins"]="S-1-5-21-3623811015-3361044348-30300820-512"
GROUP_DESC_MAP["system-admins"]="System Administrators"

GROUP_GID_MAP["system-users"]=10002
GROUP_SID_MAP["system-users"]="S-1-5-21-3623811015-3361044348-30300820-513"
GROUP_DESC_MAP["system-users"]="Standard Users"

GROUP_GID_MAP["system-readonly"]=10003
GROUP_SID_MAP["system-readonly"]="S-1-5-21-3623811015-3361044348-30300820-514"
GROUP_DESC_MAP["system-readonly"]="Read-only Access"

GROUP_GID_MAP["samba-users"]=10004
GROUP_SID_MAP["samba-users"]="S-1-5-21-3623811015-3361044348-30300820-515"
GROUP_DESC_MAP["samba-users"]="Samba File Share Users"

# ユーザーファイルを読み込んでグループメンバーシップを構築
declare -A GROUP_MEMBERS
echo "Processing user configurations..."

NEXT_UID=10001
NEXT_SID=1001

for user_file in "$USER_CONFIGS_DIR"/*.json; do
  if [ ! -f "$user_file" ]; then
    continue
  fi

  user_id=$(jq -r '.id' "$user_file")
  groups=$(jq -r '.groups[]' "$user_file" 2>/dev/null || echo "")

  echo "  - User: $user_id"

  for group in $groups; do
    if [ -n "$group" ] && [ -n "${GROUP_GID_MAP[$group]}" ]; then
      if [ -z "${GROUP_MEMBERS[$group]}" ]; then
        GROUP_MEMBERS[$group]="$user_id"
      else
        GROUP_MEMBERS[$group]="${GROUP_MEMBERS[$group]} $user_id"
      fi
    fi
  done
done

echo ""
echo "Generating LDIF..."

# LDIF生成開始
cat > "$OUTPUT_FILE" <<'EOF_HEADER'
apiVersion: v1
kind: ConfigMap
metadata:
  name: openldap-bootstrap-config
  namespace: openldap
  labels:
    app.kubernetes.io/name: openldap
    app.kubernetes.io/component: authentication
    app.kubernetes.io/part-of: authentication-infrastructure
data:
  bootstrap.ldif: |
    # Base DN and OUs
    dn: dc=kojigenba-srv,dc=com
    objectClass: dcObject
    objectClass: organization
    dc: kojigenba-srv
    o: KojiGenba Server

    # Samba Domain
    dn: sambaDomainName=K8S-SAMBA,dc=kojigenba-srv,dc=com
    objectClass: sambaDomain
    sambaDomainName: K8S-SAMBA
    sambaSID: S-1-5-21-3623811015-3361044348-30300820
    sambaAlgorithmicRidBase: 1000

    dn: ou=people,dc=kojigenba-srv,dc=com
    objectClass: organizationalUnit
    ou: people
    description: System users

    dn: ou=groups,dc=kojigenba-srv,dc=com
    objectClass: organizationalUnit
    ou: groups
    description: System groups

EOF_HEADER

# グループエントリ生成
for group_name in "${!GROUP_GID_MAP[@]}"; do
  gid="${GROUP_GID_MAP[$group_name]}"
  sid="${GROUP_SID_MAP[$group_name]}"
  desc="${GROUP_DESC_MAP[$group_name]}"
  members="${GROUP_MEMBERS[$group_name]}"

  cat >> "$OUTPUT_FILE" <<EOF_GROUP
    # Group: $group_name
    dn: cn=$group_name,ou=groups,dc=kojigenba-srv,dc=com
    objectClass: posixGroup
    objectClass: sambaGroupMapping
    cn: $group_name
    gidNumber: $gid
    description: $desc
EOF_GROUP

  # メンバー追加
  if [ -n "$members" ]; then
    for member in $members; do
      echo "    memberUid: $member" >> "$OUTPUT_FILE"
    done
  fi

  cat >> "$OUTPUT_FILE" <<EOF_GROUP_END
    sambaGroupType: 2
    sambaSID: $sid

EOF_GROUP_END
done

# ユーザーエントリ生成
for user_file in "$USER_CONFIGS_DIR"/*.json; do
  if [ ! -f "$user_file" ]; then
    continue
  fi

  # 基本情報の読み込み
  user_id=$(jq -r '.id' "$user_file")
  email=$(jq -r '.email' "$user_file")
  display_name=$(jq -r '.displayName' "$user_file")
  first_name=$(jq -r '.firstName' "$user_file")
  last_name=$(jq -r '.lastName' "$user_file")
  password=$(jq -r '.password' "$user_file")
  groups=$(jq -r '.groups[]' "$user_file" 2>/dev/null || echo "")

  # UID/GID/SID/homeDirectory/loginShellの読み込み（JSON指定を優先）
  uid_number=$(jq -r '.uid // empty' "$user_file")
  gid_number=$(jq -r '.gid // empty' "$user_file")
  samba_sid=$(jq -r '.sambaSID // empty' "$user_file")
  home_directory=$(jq -r '.homeDirectory // empty' "$user_file")
  login_shell=$(jq -r '.loginShell // empty' "$user_file")

  # 必須フィールドの検証
  if [ -z "$uid_number" ]; then
    echo "ERROR: Missing required field 'uid' in $user_file"
    echo "Please add: \"uid\": <number> (e.g., 10001)"
    exit 1
  fi

  if [ -z "$gid_number" ]; then
    echo "ERROR: Missing required field 'gid' in $user_file"
    echo "Please add: \"gid\": <number> (e.g., 10002 for system-users)"
    exit 1
  fi

  if [ -z "$samba_sid" ]; then
    echo "ERROR: Missing required field 'sambaSID' in $user_file"
    echo "Please add: \"sambaSID\": \"S-1-5-21-3623811015-3361044348-30300820-<RID>\""
    exit 1
  fi

  # デフォルト値の設定
  if [ -z "$home_directory" ]; then
    home_directory="/export/home/$user_id"
  fi

  if [ -z "$login_shell" ]; then
    login_shell="/bin/bash"
  fi

  # プライマリグループSIDを決定（gidNumberから逆引き）
  primary_sid=""
  for group_name in "${!GROUP_GID_MAP[@]}"; do
    if [ "${GROUP_GID_MAP[$group_name]}" = "$gid_number" ]; then
      primary_sid="${GROUP_SID_MAP[$group_name]}"
      break
    fi
  done

  # プライマリグループSIDが見つからない場合はエラー
  if [ -z "$primary_sid" ]; then
    echo "ERROR: GID $gid_number does not match any known group in $user_file"
    echo "Known GIDs: system-admins=10001, system-users=10002, system-readonly=10003, samba-users=10004"
    exit 1
  fi

  # 環境変数名用にハイフンをアンダースコアに変換
  user_id_env=$(echo "$user_id" | tr '-' '_')

  cat >> "$OUTPUT_FILE" <<EOF_USER
    # User: $user_id
    dn: cn=$user_id,ou=people,dc=kojigenba-srv,dc=com
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: sambaSamAccount
    cn: $user_id
    sn: $last_name
    givenName: $first_name
    mail: $email
    userPassword: \${${user_id_env}_SSHA_HASH}
    uid: $user_id
    uidNumber: $uid_number
    gidNumber: $gid_number
    homeDirectory: $home_directory
    loginShell: $login_shell
    sambaSID: $samba_sid
    sambaNTPassword: \${${user_id_env}_NT_HASH}
    sambaPrimaryGroupSID: $primary_sid
    sambaAcctFlags: [U]
    sambaPwdLastSet: 1763216334

EOF_USER
done

echo "✓ Bootstrap ConfigMap generated successfully!"
echo ""
echo "Output: $OUTPUT_FILE"
echo ""
echo "Generated entries:"
echo "  - Groups: ${#GROUP_GID_MAP[@]}"
echo "  - Users: $(ls -1 "$USER_CONFIGS_DIR"/*.json 2>/dev/null | wc -l)"
echo ""
echo "Next steps:"
echo "  1. Generate user password hashes using generate-user-secrets.sh"
echo "  2. Apply ConfigMap: kubectl apply -f $OUTPUT_FILE"
echo "  3. Run bootstrap job to populate LDAP"
echo ""
