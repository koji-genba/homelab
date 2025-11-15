#!/bin/bash
set -e

echo "=== OpenLDAP Container Starting ==="
echo "Timestamp: $(date)"

# 環境変数必須チェック
: ${LDAP_ADMIN_SSHA_HASH:?ERROR: LDAP_ADMIN_SSHA_HASH environment variable is required}
: ${LDAP_CONFIG_SSHA_HASH:?ERROR: LDAP_CONFIG_SSHA_HASH environment variable is required}

# TLS証明書の待機
echo "Waiting for TLS certificates..."
TIMEOUT=60
ELAPSED=0
while [ ! -f /certs/tls.crt ] || [ ! -f /certs/tls.key ]; do
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: TLS certificates not found after ${TIMEOUT}s"
    echo "Expected files: /certs/tls.crt, /certs/tls.key"
    exit 1
  fi
  echo "  Waiting... ($ELAPSED/${TIMEOUT}s)"
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
echo "✓ TLS certificates found"

# slapd.confの環境変数置換
echo "Processing slapd.conf template..."
if [ ! -f /etc/ldap/slapd.conf.template ]; then
  echo "ERROR: /etc/ldap/slapd.conf.template not found"
  exit 1
fi

envsubst < /etc/ldap/slapd.conf.template > /etc/ldap/slapd.conf
echo "✓ slapd.conf generated"

# データディレクトリの初期化
echo "Checking data directory..."
if [ ! -d /var/lib/ldap ]; then
  echo "Creating /var/lib/ldap..."
  mkdir -p /var/lib/ldap
fi

chown -R openldap:openldap /var/lib/ldap
chmod 700 /var/lib/ldap

# データディレクトリが空の場合の初期化
if [ -z "$(ls -A /var/lib/ldap)" ]; then
  echo "Data directory is empty - will be initialized by bootstrap-job"
else
  echo "✓ Data directory contains existing data"
fi

# 設定ファイルの検証
echo "Validating slapd.conf..."
slaptest -f /etc/ldap/slapd.conf -u || {
  echo "ERROR: slapd.conf validation failed"
  cat /etc/ldap/slapd.conf
  exit 1
}
echo "✓ slapd.conf validation passed"

# スキーマファイルの確認
echo "Checking schema files..."
for schema in core cosine inetorgperson nis samba; do
  if [ ! -f "/etc/ldap/schema/${schema}.schema" ]; then
    echo "ERROR: /etc/ldap/schema/${schema}.schema not found"
    exit 1
  fi
done
echo "✓ All schema files present"

# DHパラメータの確認
if [ ! -f /etc/ldap/dhparam.pem ]; then
  echo "WARNING: /etc/ldap/dhparam.pem not found (DH parameters missing)"
else
  echo "✓ DH parameters present"
fi

echo ""
echo "=== Starting slapd ==="
echo "Listening on: ldap:/// ldaps:///"
echo "Log level: 481 (detailed - change to 256 after initial setup)"
echo ""

# slapd起動（フォアグラウンド）
# -d 481: 詳細ログ（初期構築用）
# -h: リスニングURL
# -f: 設定ファイル
# -u/-g: 実行ユーザ/グループ
exec slapd -d 481 -h "ldap:/// ldaps:///" -f /etc/ldap/slapd.conf -u openldap -g openldap
