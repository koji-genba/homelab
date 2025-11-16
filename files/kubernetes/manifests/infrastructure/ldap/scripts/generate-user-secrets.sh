#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$SCRIPT_DIR/../openldap/bootstrap"
USER_CONFIGS_DIR="$BOOTSTRAP_DIR/user-configs"
OUTPUT_DIR="$SCRIPT_DIR/.."
OUTPUT_FILE="$OUTPUT_DIR/secret.yaml"

echo "=== OpenLDAP Secrets Generator ==="
echo ""
echo "This script generates Kubernetes Secret YAML for OpenLDAP."
echo "It includes LDAP admin passwords and all user passwords from JSON configs."
echo ""

# 依存ツールチェック
MISSING_TOOLS=()

if ! command -v jq >/dev/null 2>&1; then
  MISSING_TOOLS+=("jq (install: apt-get install jq)")
fi

if ! command -v slappasswd >/dev/null 2>&1; then
  MISSING_TOOLS+=("slappasswd (install: apt-get install ldap-utils)")
fi

if ! command -v openssl >/dev/null 2>&1; then
  MISSING_TOOLS+=("openssl")
fi

if ! command -v iconv >/dev/null 2>&1; then
  MISSING_TOOLS+=("iconv (install: apt-get install libc-bin or libc6)")
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

echo "Step 1: Enter LDAP admin passwords and phpLDAPadmin APP_KEY (interactive)"
echo ""

# LDAP管理パスワード入力
read -sp "Admin password (for cn=admin,dc=...): " ADMIN_PASSWORD
echo ""

read -sp "Config password (for rootpw): " CONFIG_PASSWORD
echo ""

echo ""

# パスワード確認
if [ -z "$ADMIN_PASSWORD" ] || [ -z "$CONFIG_PASSWORD" ]; then
  echo "ERROR: All admin passwords are required"
  exit 1
fi

# phpLDAPadmin APP_KEY入力
echo "phpLDAPadmin APP_KEY (Laravel encryption key):"
echo "  - If you have an existing APP_KEY, paste it here"
echo "  - Press Enter to auto-generate a new one using Docker"
echo ""
read -p "APP_KEY (or press Enter to auto-generate): " PHPADMIN_APP_KEY
echo ""

# APP_KEYが空の場合は自動生成
if [ -z "$PHPADMIN_APP_KEY" ]; then
  echo "Auto-generating phpLDAPadmin APP_KEY using Docker..."

  # Dockerが利用可能かチェック
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is required to generate APP_KEY automatically"
    echo "Please install Docker or manually provide an APP_KEY"
    exit 1
  fi

  # phpLDAPadminコンテナを使ってAPP_KEYを生成
  PHPADMIN_APP_KEY=$(docker run -it --rm ghcr.io/koji-genba/phpldapadmin:v1 ./artisan key:generate --show 2>/dev/null | tr -d '\r')

  if [ -z "$PHPADMIN_APP_KEY" ]; then
    echo "ERROR: Failed to generate APP_KEY using Docker"
    echo "Please manually provide an APP_KEY or check Docker setup"
    exit 1
  fi

  echo "Generated: $PHPADMIN_APP_KEY"
  echo ""
fi

# LDAP管理パスワードのハッシュ生成
echo "Generating LDAP admin password hashes..."
ADMIN_SSHA_HASH=$(slappasswd -s "$ADMIN_PASSWORD")
CONFIG_SSHA_HASH=$(slappasswd -s "$CONFIG_PASSWORD")

echo ""
echo "Step 2: Processing user configurations from JSON files"
echo "Source: $USER_CONFIGS_DIR"
echo ""

# NTハッシュ生成関数
generate_nt_hash() {
  local password="$1"
  local nt_hash=""

  if command -v perl >/dev/null 2>&1; then
    # Perl での MD4 ハッシュ生成（より確実）
    nt_hash=$(perl -e "
      use Digest::MD4 qw(md4_hex);
      my \$password = '$password';
      my \$utf16le = pack('v*', unpack('C*', \$password));
      print uc(md4_hex(\$utf16le));
    " 2>/dev/null || echo "")
  fi

  # Perl が失敗した場合は OpenSSL 3.0 レガシープロバイダを試す
  if [ -z "$nt_hash" ]; then
    nt_hash=$(printf "%s" "$password" | iconv -f UTF-8 -t UTF-16LE | openssl md4 -provider legacy -provider default 2>/dev/null | awk '{print $2}' | tr '[a-z]' '[A-Z]' || echo "")
  fi

  echo "$nt_hash"
}

# Secret YAMLヘッダー生成
cat > "$OUTPUT_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: openldap-secrets
  namespace: openldap
  labels:
    app.kubernetes.io/name: openldap
    app.kubernetes.io/component: authentication
type: Opaque
stringData:
  # LDAP Admin Passwords
  admin_password: "$ADMIN_PASSWORD"
  config_password: "$CONFIG_PASSWORD"

  # LDAP Admin Password Hashes
  admin_ssha_hash: "$ADMIN_SSHA_HASH"
  config_ssha_hash: "$CONFIG_SSHA_HASH"

  # phpLDAPadmin APP_KEY (Laravel encryption key)
  phpadmin_app_key: "$PHPADMIN_APP_KEY"

EOF

# ユーザーごとのパスワードハッシュを生成
echo "Generating password hashes for users..."
echo ""

for user_file in "$USER_CONFIGS_DIR"/*.json; do
  if [ ! -f "$user_file" ]; then
    continue
  fi

  user_id=$(jq -r '.id' "$user_file")
  password=$(jq -r '.password' "$user_file")

  # 環境変数名用にハイフンをアンダースコアに変換
  user_id_env=$(echo "$user_id" | tr '-' '_')

  echo "  Processing: $user_id (env: $user_id_env)"

  # SSHA ハッシュ生成
  ssha_hash=$(slappasswd -s "$password")

  # NT ハッシュ生成
  nt_hash=$(generate_nt_hash "$password")

  if [ -z "$nt_hash" ]; then
    echo "    WARNING: NT hash generation failed for $user_id"
    nt_hash=""
  fi

  # Secret に追加（環境変数名としてアンダースコア使用）
  cat >> "$OUTPUT_FILE" <<EOF
  # User: $user_id
  ${user_id_env}_password: "$password"
  ${user_id_env}_SSHA_HASH: "$ssha_hash"
  ${user_id_env}_NT_HASH: "$nt_hash"

EOF
done

echo ""
echo "✓ Secret YAML generated successfully!"
echo ""
echo "Output: $OUTPUT_FILE"
echo ""
echo "Generated secrets:"
echo "  - LDAP admin passwords (admin, config)"
echo "  - phpLDAPadmin APP_KEY"
echo "  - User passwords: $(ls -1 "$USER_CONFIGS_DIR"/*.json 2>/dev/null | wc -l) users"
echo ""
echo "⚠️  SECURITY WARNINGS:"
echo "  1. This file contains PLAINTEXT passwords and password hashes"
echo "  2. DO NOT commit this file to Git (protected by .gitignore)"
echo "  3. Verify .gitignore includes: **/secret.yaml"
echo "  4. Restrict file permissions (600 or 400):"
echo "     chmod 600 $OUTPUT_FILE"
echo "  5. Delete this file after applying to Kubernetes"
echo "  6. Consider using encrypted storage or sealed-secrets for production"
echo ""
echo "Next steps:"
echo "  1. Restrict permissions: chmod 600 $OUTPUT_FILE"
echo "  2. Apply to Kubernetes: kubectl apply -f $OUTPUT_FILE"
echo "  3. Verify: kubectl get secret openldap-secrets -n openldap"
echo "  4. Delete: rm $OUTPUT_FILE (after applying)"
echo ""
