#!/bin/bash
# ElastiFlow LXCコンテナ内セットアップスクリプト
# Terraformでコンテナを作成した後、コンテナ内(root)で実行する。
#   scp install.sh root@<CT_IP>:/root/
#   ssh root@<CT_IP> bash /root/install.sh
set -euo pipefail

# 導入するflow-collectorのバージョン。最新版は下記で確認して更新すること:
# https://docs.elastiflow.com/flowcoll/installation/install_linux
FLOWCOLL_VERSION="7.26.2"
FLOWCOLL_DEB_URL="https://elastiflow-releases.s3.us-east-2.amazonaws.com/flow-collector/flow-collector_${FLOWCOLL_VERSION}_linux_amd64.deb"

echo "==> vm.max_map_count を確認"
current_max_map_count=$(cat /proc/sys/vm/max_map_count)
if [ "$current_max_map_count" -lt 262144 ]; then
  echo "!! vm.max_map_count=${current_max_map_count} は Elasticsearch の要求値(262144)未満です。"
  echo "!! これは名前空間分離されないカーネルパラメータなので、コンテナ内ではなく"
  echo "!! Proxmoxホスト側で設定する必要があります。ホストで以下を実行してから再実行してください:"
  echo ""
  echo "     echo 'vm.max_map_count=262144' >> /etc/sysctl.conf && sysctl -p"
  echo ""
  exit 1
fi

echo "==> 前提パッケージをインストール"
apt-get update
apt-get install -y curl gnupg apt-transport-https ca-certificates libpcap-dev

echo "==> Elastic APT リポジトリを登録 (Elasticsearch/Kibana 8.x)"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list
apt-get update

echo "==> Elasticsearch / Kibana をインストール"
apt-get install -y elasticsearch kibana

echo "==> Elasticsearch を単一ノード構成に設定（ホームラボ規模のため security は無効化）"
cat >> /etc/elasticsearch/elasticsearch.yml <<'EOF'

# --- elastiflow install.sh により追加 ---
discovery.type: single-node
network.host: 0.0.0.0
xpack.security.enabled: false
EOF

mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options <<'EOF'
-Xms1g
-Xmx1g
EOF

echo "==> Kibana を設定"
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
cat >> /etc/elastiflow/flowcoll.yml <<'EOF'

# --- elastiflow install.sh により追加 ---
EF_LICENSE_ACCEPTED: true
EF_OUTPUT_ELASTICSEARCH_ENABLE: true
EF_OUTPUT_ELASTICSEARCH_ADDRESSES: "127.0.0.1:9200"
EF_OUTPUT_ELASTICSEARCH_TLS_ENABLE: false
EOF

systemctl enable --now flowcoll

echo ""
echo "==> セットアップ完了"
echo "Kibana:        http://$(hostname -I | awk '{print $1}'):5601"
echo "flow-collector受信ポート: UDP 6343 (sFlow) ※IX2215側の設定は network/README.md を参照"
echo "サービス状態確認: systemctl status elasticsearch kibana flowcoll"
