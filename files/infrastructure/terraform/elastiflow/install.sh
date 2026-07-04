#!/bin/bash
# ElastiFlow VM内セットアップスクリプト
# TerraformでVMを作成した後、VM内でroot権限により実行する。
#   scp install.sh ubuntu@<VM_IP>:/tmp/
#   ssh ubuntu@<VM_IP> sudo bash /tmp/install.sh
set -euo pipefail

# 導入するflow-collectorのバージョン。最新版は下記で確認して更新すること:
# https://docs.elastiflow.com/flowcoll/installation/install_linux
FLOWCOLL_VERSION="7.26.2"
FLOWCOLL_DEB_URL="https://elastiflow-releases.s3.us-east-2.amazonaws.com/flow-collector/flow-collector_${FLOWCOLL_VERSION}_linux_amd64.deb"
ELASTICSEARCH_HEAP_SIZE="12g"
FLOWCOLL_PROCESSOR_POOL_SIZE="2"

remove_elasticsearch_setting_conflicts() {
  local config_file="/etc/elasticsearch/elasticsearch.yml"
  local tmp_file
  tmp_file=$(mktemp)

  # Elasticsearch 8.x .deb adds security/TLS bootstrap settings on install.
  # The YAML parser rejects duplicate keys, so remove generated/conflicting keys
  # before appending the homelab single-node settings below.
  awk '
    /^[[:space:]]*xpack\.security\.(http|transport)\.ssl:/ { skip_block = 1; next }
    skip_block && /^[[:space:]]/ { next }
    { skip_block = 0 }
    /^[[:space:]]*(discovery\.type|network\.host|http\.host|cluster\.initial_master_nodes|xpack\.security\.enabled|xpack\.security\.enrollment\.enabled):/ { next }
    { print }
  ' "$config_file" > "$tmp_file"

  cat "$tmp_file" > "$config_file"
  rm -f "$tmp_file"
}

remove_elasticsearch_keystore_conflicts() {
  local keystore_cmd="/usr/share/elasticsearch/bin/elasticsearch-keystore"
  local setting

  [ -x "$keystore_cmd" ] || return 0

  # Elasticsearch 8.x .deb auto-configuration may leave TLS secure settings in
  # the keystore. They must be removed too when disabling xpack.security.
  while IFS= read -r setting; do
    case "$setting" in
      xpack.security.http.ssl.keystore.secure_password|\
      xpack.security.http.ssl.keystore.secure_key_password|\
      xpack.security.http.ssl.truststore.secure_password|\
      xpack.security.transport.ssl.keystore.secure_password|\
      xpack.security.transport.ssl.keystore.secure_key_password|\
      xpack.security.transport.ssl.truststore.secure_password)
        "$keystore_cmd" remove "$setting" >/dev/null
        ;;
    esac
  done < <("$keystore_cmd" list)
}

remove_kibana_setting_conflicts() {
  local config_file="/etc/kibana/kibana.yml"
  local tmp_file
  tmp_file=$(mktemp)

  awk '
    /^[[:space:]]*(server\.host|elasticsearch\.hosts):/ { next }
    { print }
  ' "$config_file" > "$tmp_file"

  cat "$tmp_file" > "$config_file"
  rm -f "$tmp_file"
}

remove_flowcoll_setting_conflicts() {
  local config_file="/etc/elastiflow/flowcoll.yml"
  local tmp_file

  [ -f "$config_file" ] || return 0

  tmp_file=$(mktemp)
  awk '
    /^[[:space:]]*(EF_LICENSE_ACCEPTED|EF_PROCESSOR_POOL_SIZE|EF_OUTPUT_ELASTICSEARCH_ENABLE|EF_OUTPUT_ELASTICSEARCH_ADDRESSES|EF_OUTPUT_ELASTICSEARCH_TLS_ENABLE|EF_OUTPUT_ELASTICSEARCH_INDEX_TEMPLATE_SHARDS|EF_OUTPUT_ELASTICSEARCH_INDEX_TEMPLATE_REPLICAS):/ { next }
    { print }
  ' "$config_file" > "$tmp_file"

  cat "$tmp_file" > "$config_file"
  rm -f "$tmp_file"
}

echo "==> vm.max_map_count を確認"
current_max_map_count=$(cat /proc/sys/vm/max_map_count)
if [ "$current_max_map_count" -lt 262144 ]; then
  echo "!! vm.max_map_count=${current_max_map_count} は Elasticsearch の要求値(262144)未満です。"
  echo "==> VM内で vm.max_map_count を永続化"
  echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-elastiflow.conf
  sysctl -p /etc/sysctl.d/99-elastiflow.conf
fi

echo "==> 前提パッケージをインストール"
apt-get update
apt-get install -y curl gnupg apt-transport-https ca-certificates libpcap-dev

echo "==> Elastic APT リポジトリを登録 (Elasticsearch/Kibana 8.x)"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --batch --yes --dearmor -o /usr/share/keyrings/elastic.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list
apt-get update

echo "==> Elasticsearch / Kibana をインストール"
apt-get install -y elasticsearch kibana

echo "==> Elasticsearch を単一ノード構成に設定（ホームラボ規模のため security は無効化）"
remove_elasticsearch_setting_conflicts
remove_elasticsearch_keystore_conflicts
cat >> /etc/elasticsearch/elasticsearch.yml <<'EOF'

# --- elastiflow install.sh により追加 ---
discovery.type: single-node
network.host: 0.0.0.0
xpack.security.enabled: false
indices.query.bool.max_clause_count: 8192
search.max_buckets: 250000
EOF

mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms${ELASTICSEARCH_HEAP_SIZE}
-Xmx${ELASTICSEARCH_HEAP_SIZE}
EOF

echo "==> Kibana を設定"
remove_kibana_setting_conflicts
cat >> /etc/kibana/kibana.yml <<'EOF'

# --- elastiflow install.sh により追加 ---
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://127.0.0.1:9200"]
EOF

echo "==> Elasticsearch を起動"
systemctl enable --now elasticsearch

echo "==> Elasticsearch の起動を待機"
for _ in $(seq 1 30); do
  if curl -fs http://127.0.0.1:9200 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "==> Kibana を起動"
systemctl enable --now kibana

echo "==> ElastiFlow flow-collector をダウンロード・インストール"
curl -fsSL -o /tmp/flow-collector.deb "$FLOWCOLL_DEB_URL"
apt-get install -y /tmp/flow-collector.deb
rm -f /tmp/flow-collector.deb

echo "==> flow-collector の出力先を設定（sFlow/NetFlow/IPFIX の受信ポートはデフォルトのまま: 2055,4739,6343,9995）"
remove_flowcoll_setting_conflicts
cat >> /etc/elastiflow/flowcoll.yml <<EOF

# --- elastiflow install.sh により追加 ---
EF_LICENSE_ACCEPTED: true
EF_PROCESSOR_POOL_SIZE: ${FLOWCOLL_PROCESSOR_POOL_SIZE}
EF_OUTPUT_ELASTICSEARCH_ENABLE: true
EF_OUTPUT_ELASTICSEARCH_ADDRESSES: "127.0.0.1:9200"
EF_OUTPUT_ELASTICSEARCH_TLS_ENABLE: false
EF_OUTPUT_ELASTICSEARCH_INDEX_TEMPLATE_SHARDS: 1
EF_OUTPUT_ELASTICSEARCH_INDEX_TEMPLATE_REPLICAS: 0
EOF

systemctl enable --now flowcoll

echo ""
echo "==> セットアップ完了"
echo "Kibana:        http://$(hostname -I | awk '{print $1}'):5601"
echo "flow-collector受信ポート: UDP 6343 (sFlow) ※IX2215側の設定は network/README.md を参照"
echo "サービス状態確認: systemctl status elasticsearch kibana flowcoll"
