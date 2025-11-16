#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$SCRIPT_DIR/../openldap/bootstrap"
USER_CONFIGS_DIR="$BOOTSTRAP_DIR/user-configs"
OUTPUT_DIR="$SCRIPT_DIR/../openldap"
OUTPUT_FILE="$OUTPUT_DIR/bootstrap-update-configmap.yaml"

echo "=== OpenLDAP Bootstrap Update ConfigMap Generator ==="
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

echo "Processing user configurations from: $USER_CONFIGS_DIR"
echo ""

# 既存グループのリスト（固定値）
declare -A VALID_GROUPS
VALID_GROUPS["system-admins"]=1
VALID_GROUPS["system-users"]=1
VALID_GROUPS["system-readonly"]=1
VALID_GROUPS["samba-users"]=1

# グループメンバーシップを構築
declare -A GROUP_MEMBERS

for user_file in "$USER_CONFIGS_DIR"/*.json; do
  if [ ! -f "$user_file" ]; then
    continue
  fi

  user_id=$(jq -r '.id' "$user_file")
  groups=$(jq -r '.groups[]' "$user_file" 2>/dev/null || echo "")

  for group in $groups; do
    if [ -n "$group" ] && [ -n "${VALID_GROUPS[$group]}" ]; then
      if [ -z "${GROUP_MEMBERS[$group]}" ]; then
        GROUP_MEMBERS[$group]="$user_id"
      else
        GROUP_MEMBERS[$group]="${GROUP_MEMBERS[$group]}
$user_id"
      fi
    fi
  done
done

# Update ConfigMap生成
cat > "$OUTPUT_FILE" <<'EOF_HEADER'
apiVersion: v1
kind: ConfigMap
metadata:
  name: openldap-bootstrap-update-config
  namespace: openldap
  labels:
    app.kubernetes.io/name: openldap
    app.kubernetes.io/component: authentication
data:
  # 既存エントリを更新するための LDIF
  # ldapmodify 形式で記述
  update.ldif: |
EOF_HEADER

# 各グループのmemberUidを更新
for group_name in "${!GROUP_MEMBERS[@]}"; do
  members="${GROUP_MEMBERS[$group_name]}"

  cat >> "$OUTPUT_FILE" <<EOF_GROUP
    # Group: $group_name - memberUid の更新
    dn: cn=$group_name,ou=groups,dc=kojigenba-srv,dc=com
    changetype: modify
    replace: memberUid
EOF_GROUP

  # メンバー追加
  while IFS= read -r member; do
    if [ -n "$member" ]; then
      echo "    memberUid: $member" >> "$OUTPUT_FILE"
    fi
  done <<< "$members"

  echo "    -" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"
done

echo "✓ Bootstrap Update ConfigMap generated successfully!"
echo ""
echo "Output: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. Apply ConfigMap: kubectl apply -f $OUTPUT_FILE"
echo "  2. Run bootstrap job to update LDAP group memberships"
echo ""
