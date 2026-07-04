# ElastiFlow構築

TerraformでProxmox VE上にElastiFlow（ネットワークフロー分析）用のLXCコンテナを構築します。

## 概要

- **ElastiFlow flow-collector**: sFlow/NetFlow/IPFIXを受信し、Elasticsearchに送信
- **Elasticsearch + Kibana**: フローデータの保存・可視化
- Docker は使わず、Debianのネイティブ.debパッケージで構築（unprivileged LXCでnesting不要）
- ElastiFlowはCommunityライセンス（無料、500 flows/sec上限、ライセンスキー登録不要）で利用

## 構築されるコンテナ

- **elastiflow**: 192.168.10.40（管理VLAN10、CTID 110）
  - CPU 2core / メモリ4GB / ディスク32GB（初期値、`variables.tf`で調整可）

## 前提条件

- Proxmox VE環境（192.168.10.11）
- SSHキーペア（~/.ssh/k8s_ed25519 等）
- Proxmoxホストに Debian 12 LXCテンプレートがダウンロード済みであること

```bash
# Proxmoxホスト側
pveam update
pveam available | grep debian-12
pveam download local debian-12-standard_12.7-1_amd64.tar.zst  # 実際のファイル名に置き換え
```

- Proxmoxホスト側で `vm.max_map_count` を設定済みであること（Elasticsearchの要件。カーネルパラメータのため名前空間分離されず、コンテナ内では設定できない）

```bash
# Proxmoxホスト側
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
sysctl -p
```

## 構築手順

### 1. 設定ファイル作成

```bash
cd files/infrastructure/terraform/elastiflow/
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

`variables.tf` の `container_template_file_id` は、実際にダウンロードしたテンプレートのファイル名に合わせて調整してください。

### 2. Terraform実行

```bash
terraform init
terraform plan
terraform apply
```

### 3. アプリケーションのセットアップ

コンテナ作成後、`install.sh` をコンテナ内で実行してElasticsearch/Kibana/flow-collectorをインストールします。

```bash
scp install.sh root@192.168.10.40:/root/
ssh root@192.168.10.40 bash /root/install.sh
```

スクリプトの内容:
- Elasticsearch/Kibana（Elastic 8.x apt repo）をインストールし、単一ノード構成・ヒープ1GBに設定
- ElastiFlow flow-collectorの.debをダウンロード・インストールし、Elasticsearch出力を有効化
- 受信ポートはデフォルトのまま（UDP 2055/4739/6343/9995 = NetFlow/IPFIX/sFlow/NetFlow(alt)）

`install.sh` 冒頭の `FLOWCOLL_VERSION` は最新版に随時更新してください（[Linux install docs](https://docs.elastiflow.com/flowcoll/installation/install_linux)参照）。

### 4. ルーター側（IX2215）でsFlowエクスポートを設定

[../../network/README.md](../../network/README.md) の「フローエクスポート（sFlow）設定案」を参照し、IX2215からこのコンテナ（192.168.10.40:6343）へsFlowを送信するよう設定します。

### 5. Kibanaダッシュボードのインポート

1. `http://192.168.10.40:5601` を開く
2. ElastiFlowのKibana用ダッシュボードファイルをダウンロード（[docs](https://docs.elastiflow.com/)のバージョンに合ったもの）
3. Stack Management → Saved Objects → Import からインポート

### 6. 動作確認

```bash
ssh root@192.168.10.40
systemctl status elasticsearch kibana flowcoll
curl -s http://127.0.0.1:9200/_cat/indices?v | grep elastiflow
```

IX2215側の設定反映後、`elastiflow-*` インデックスにデータが増え始めることを確認します。

## セキュリティ上の注意

- `install.sh` はホームラボの規模・用途に合わせ、Elasticsearchの `xpack.security.enabled` を無効化しています（認証なし）。管理VLAN(10)からはServer Application VLAN(11)・Main VLAN(20)への到達がACLで許可されているため、これらのVLAN上の端末からもKibana/Elasticsearchに認証なしでアクセスできる点に留意してください。気になる場合はElastic Stack付属のセキュリティ機能を有効化するか、IX2215側のACLでVLAN10宛のTCP 5601/9200を制限してください。

## 関連ドキュメント

- [Homelab Project Overview](../../../../README.md)
- [Network (IX2215) README](../../network/README.md)
- [ElastiFlow Documentation](https://docs.elastiflow.com/)
