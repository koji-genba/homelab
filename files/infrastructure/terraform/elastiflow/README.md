# ElastiFlow構築

TerraformでProxmox VE上にElastiFlow（ネットワークフロー分析）用のVMを構築します。

## 概要

- **ElastiFlow flow-collector**: sFlow/NetFlow/IPFIXを受信し、Elasticsearchに送信
- **Elasticsearch + Kibana**: フローデータの保存・可視化
- Docker は使わず、Debian/Ubuntuのネイティブ.debパッケージで構築
- ElastiFlowはCommunityライセンス（無料、500 flows/sec上限、ライセンスキー登録不要）で利用

## 構築されるVM

- **elastiflow**: 192.168.10.40（管理VLAN10、VMID 110）
  - CPU 4core / メモリ32GB / ディスク128GB（初期値、`variables.tf`で調整可）
  - root disk: Proxmox storage `vmpool` 上に作成（`variables.tf` の `datastore_id` / `disk_size_gb` で変更可）
  - VM template: `template_vm_id`（初期値 9000）から full clone

ElastiFlow公式のSingle "Lab" Server構成は、Elasticsearch/Kibana/NetObserv Flow同居で CPU 4 cores / メモリ32GB / SSD 2TB を目安としています。このTerraformの初期値は公式のメモリ目安に合わせつつ、ホームラボ向けにディスクを抑えた構成です。フロー量や保持期間を増やす場合は `disk_size_gb` を増やしてください。

## データ永続化

この構成では、ElastiFlowのフローデータはElasticsearchに保存されます。Elasticsearch / Kibana / flow-collector はすべてVMのroot disk上にインストールされ、追加の専用データディスクは作成しません。

主な永続化先:

- Elasticsearchデータ: `/var/lib/elasticsearch`
- Elasticsearch設定: `/etc/elasticsearch`
- Kibana設定: `/etc/kibana`
- Kibanaデータ: `/var/lib/kibana`
- ElastiFlow flow-collector設定: `/etc/elastiflow/flowcoll.yml`

Proxmoxホスト側では、これらはVMID 110のdisk内に保存されます。root diskの実体パスはProxmox storage `vmpool` の種類に依存します。ホスト上で確認する場合:

```bash
qm config 110
pvesm path <qm config 110 の scsi0 に表示された volume-id>
```

`vmpool` がZFS storageの場合は、`vm-110-disk-0` のようなZFS zvolとして管理されます。ディスクを削除するとElasticsearchの保存データも消えるため、長期保存したい場合は `disk_size_gb` の増量、Proxmox側のバックアップ、またはElasticsearchデータ用の専用ディスク追加を検討してください。

## 前提条件

- Proxmox VE環境（192.168.10.11）
- SSHキーペア（~/.ssh/k8s_ed25519 等）
- Proxmox APIアクセス権限
- Cloud-init対応のVMテンプレート（初期値: VMID 9000）

`template_vm_id` は、k8s-cluster / tailscale-gateway と同じ既存VMテンプレートを使う想定です。別のテンプレートIDを使う場合は `terraform.tfvars` または `variables.tf` で変更してください。

## 構築手順

### 1. 設定ファイル作成

```bash
cd files/infrastructure/terraform/elastiflow/
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

`terraform.tfvars` の `proxmox_password` は、Terraform が Proxmox API に接続するための認証情報です。サンプル値のままだと `terraform apply` 時に `HTTP 401 authentication failure` になります。実際に Proxmox Web UI へログインできる `root@pam` のパスワードに変更してください。

`ssh_public_key` は、作成されるVMの `ubuntu` ユーザーへ登録される公開鍵です。VMへSSH接続するときは、この公開鍵に対応する秘密鍵を使います。

### 2. Terraform実行

```bash
terraform init
terraform plan
terraform apply
```

### 3. アプリケーションのセットアップ

VM作成後、`install.sh` をVM内で実行してElasticsearch/Kibana/flow-collectorをインストールします。

```bash
scp install.sh ubuntu@192.168.10.40:/tmp/
ssh ubuntu@192.168.10.40 sudo bash /tmp/install.sh
```

SSH秘密鍵を明示する場合:

```bash
scp -i ~/.ssh/k8s_ed25519 install.sh ubuntu@192.168.10.40:/tmp/
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.40 sudo bash /tmp/install.sh
```

スクリプトの内容:
- Elasticsearch/Kibana（Elastic 8.x apt repo）をインストールし、単一ノード構成・ヒープ12GBに設定
- ElastiFlow flow-collectorの.debをダウンロード・インストールし、Elasticsearch出力を有効化（単一ノード向けに shards=1 / replicas=0）
- Elasticsearch向けに `vm.max_map_count=262144` をVM内で永続化
- 受信ポートはデフォルトのまま（UDP 2055/4739/6343/9995 = NetFlow/IPFIX/sFlow/NetFlow(alt)）

`install.sh` 冒頭の `FLOWCOLL_VERSION` は最新版に随時更新してください（[Linux install docs](https://docs.elastiflow.com/flowcoll/installation/install_linux)参照）。

### 4. ルーター側（IX2215）でsFlowエクスポートを設定

[../../network/README.md](../../network/README.md) の「フローエクスポート（sFlow）設定案」を参照し、IX2215からこのVM（192.168.10.40:6343）へsFlowを送信するよう設定します。

### 5. Kibanaダッシュボードのインポート

1. `http://192.168.10.40:5601` を開く
2. ElastiFlowのKibana用ダッシュボードファイルをダウンロード（[docs](https://docs.elastiflow.com/)のバージョンに合ったもの）
3. Stack Management → Saved Objects → Import からインポート

### 6. 動作確認

```bash
ssh ubuntu@192.168.10.40
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
