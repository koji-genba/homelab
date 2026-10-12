# ElastiFlow構築

TerraformでProxmox VE上にElastiFlow（ネットワークフロー分析）用のVMを構築します。

## 概要

- **ElastiFlow flow-collector**: sFlow/NetFlow/IPFIXを受信し、Elasticsearchに送信
- **Elasticsearch + Kibana**: フローデータの保存・可視化
- Docker は使わず、Debian/Ubuntuのネイティブ.debパッケージで構築
- ElastiFlowはCommunityライセンス（無料、500 flows/sec上限、ライセンスキー登録不要）で利用

## 構築されるVM

- **elastiflow**: 192.168.10.103（管理VLAN10、VMID 103）
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

Proxmoxホスト側では、これらはVMID 103のdisk内に保存されます。root diskの実体パスはProxmox storage `vmpool` の種類に依存します。ホスト上で確認する場合:

```bash
qm config 103
pvesm path <qm config 103 の scsi0 に表示された volume-id>
```

`vmpool` がZFS storageの場合は、`vm-103-disk-0` のようなZFS zvolとして管理されます。
過去のフローデータはVMのdiskにしか無く、diskを失うとrepoからは戻せません。Kibanaのdashboardへの変更も失われます。

## 再構築性とbackup

サービスはTerraformによるVM作成、`install.sh`の実行、dashboardの取り込みで作り直せますが、
scriptの実行とdashboardの取り込みには手作業が残り、dashboardの取得元も固定されていません。
template 9000の作成の固定と合わせて、再構築の穴は[#87](https://github.com/koji-genba/homelab/issues/87)で追跡しています。
過去のフローを残す必要があるかは運用者に確認中で、VM backupを取るかどうかは未決です。
VM全体の評価と方針は[現行アーキテクチャ](../../../../docs/architecture/target-state.md#再構築性とbackupの方針)を参照してください。

## 実機確認（2026-10-12）

運用者がVMで確認した記録では、`elasticsearch`・`kibana`・`flowcoll`は3つともactiveでした。
フローのindexは日次でrolloverし、2026-10-08〜10-11に作成されたindexにフローが入っていました。
Kibanaのdashboardは36個、root diskの使用量は123G中17Gでした。
[#34](https://github.com/koji-genba/homelab/issues/34)（取り込み停止）はopenのままですが、
この時点では取り込みを確認しています。いつ・何をして復旧したかは確認していません。

## 前提条件

- Proxmox VE環境（192.168.10.11）
- SSHキーペア（~/.ssh/k8s_ed25519 等）
- Proxmox APIアクセス権限
- Cloud-init対応のVMテンプレート（初期値: VMID 9000）

`template_vm_id`（初期値 9000）からfull cloneします。テンプレートの現存は別途確認してください。別のテンプレートIDを使う場合は `terraform.tfvars` または `variables.tf` で変更してください。

## 構築手順

### 1. 設定ファイル作成

```bash
cd files/infrastructure/terraform/elastiflow/
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

`terraform.tfvars` の `proxmox_password` は、Terraform が Proxmox API に接続するための認証情報です。サンプル値のままだと `terraform apply` 時に `HTTP 401 authentication failure` になります。実際に Proxmox Web UI へログインできる `root@pam` のパスワードに変更してください。

このルートの[provider](providers.tf)は`proxmox_username` / `proxmox_password`方式で、ProxmoxへのSSHも
passwordを使います。Apps VMルートのAPI token / SSH agent方式とは異なります。接続情報を入れた
`terraform.tfvars`はGit ignore対象です。

`ssh_public_key` は、作成されるVMの `ubuntu` ユーザーへ登録される公開鍵です。VMへSSH接続するときは、この公開鍵に対応する秘密鍵を使います。

### 2. Terraform実行

```bash
terraform init
terraform plan
terraform apply
```

[main.tf](main.tf)の`ignore_changes`は`initialization[0].user_data_file_id`、`clone[0].vm_id`、`tags`を
対象にします。snippet内容・template ID・tagsを変更しても、それだけでは既存VMのこれらの設定を更新しません。
guestへの追加設定は別途必要です。

### 3. アプリケーションのセットアップ

VM作成後、`install.sh` をVM内で実行してElasticsearch/Kibana/flow-collectorをインストールします。

```bash
scp install.sh ubuntu@192.168.10.103:/tmp/
ssh ubuntu@192.168.10.103 sudo bash /tmp/install.sh
```

SSH秘密鍵を明示する場合:

```bash
scp -i ~/.ssh/k8s_ed25519 install.sh ubuntu@192.168.10.103:/tmp/
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.103 sudo bash /tmp/install.sh
```

スクリプトの内容:
- Elasticsearch/Kibana（Elastic 8.x apt repo）をインストールし、単一ノード構成・ヒープ12GBに設定
- ElastiFlow flow-collectorの.debをダウンロード・インストールし、Elasticsearch出力を有効化（単一ノード向けに shards=1 / replicas=0）
- Elasticsearch向けに `vm.max_map_count=262144` をVM内で永続化
- 受信ポートはデフォルトのまま（UDP 2055/4739/6343/9995 = NetFlow/IPFIX/sFlow/NetFlow(alt)）

`install.sh` 冒頭の `FLOWCOLL_VERSION` は最新版に随時更新してください（[Linux install docs](https://docs.elastiflow.com/flowcoll/installation/install_linux)参照）。

### 4. ルーター側（IX2215）でsFlowエクスポートを設定

[Network READMEのsFlow節](../../network/README.md#sflow)を参照してください。repoの
[config.txt](../../network/config.txt)にはagent `192.168.10.1`、collector `192.168.10.103`が定義済みです。
実機への反映状態とcollector側の受信は別途確認してください。

### 5. Kibanaダッシュボードのインポート

1. `http://192.168.10.103:5601` を開く
2. ElastiFlowのKibana用ダッシュボードファイルをダウンロード（[docs](https://docs.elastiflow.com/)のバージョンに合ったもの）
3. Stack Management → Saved Objects → Import からインポート

### 6. 動作確認

```bash
ssh ubuntu@192.168.10.103
systemctl status elasticsearch kibana flowcoll
curl -s http://127.0.0.1:9200/_cat/indices?v | grep elastiflow
```

IX2215側の設定反映後、`elastiflow-*` インデックスにデータが増え始めることを確認します。

## セキュリティ上の注意

- `install.sh` はホームラボの規模・用途に合わせ、Elasticsearchの `xpack.security.enabled` を無効化しています（認証なし）。repoの`config.txt`では、Server VLAN(10)内に加え、Trusted VLAN(20)からServer VLAN(10)への通信が`main-out`と`trusted-dyn`で許可されます。ServerからTrustedへの未要求通信は`trusted-in`で拒否されます。この許可経路からKibana/Elasticsearchに認証なしで到達する構成です。気になる場合はElastic Stack付属のセキュリティ機能を有効化するか、IX2215側のACLでVLAN10宛のTCP 5601/9200を制限してください。

## Terraform state

active stateはこのルートのlocal `terraform.tfstate`で、Git ignore対象です。
このルートはraw `terraform apply`で実行し、state backupを呼ばないため、成功後にrepository rootで
このルートのstateも収集する`make state-backup`を実行します。
backup / restoreの仕組みと前提は[ADR-0005](../../../../docs/adr/0005-secrets-and-terraform-state.md)と
[state-backup.sh](../../../../scripts/state-backup.sh) / [state-restore.sh](../../../../scripts/state-restore.sh)を参照してください。

## 関連ドキュメント

- [Homelab Project Overview](../../../../README.md)
- [Network (IX2215) README](../../network/README.md)
- [ElastiFlow Documentation](https://docs.elastiflow.com/)
