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
2026-10-12に、運用者は過去のフローデータは不要と判断し、VM backupを取らないと決めました。
VMを失ったら作り直し、フローは空のindexから取り込み直します。
repoからの再構築性が完全だからではなく、失ってよいという判断によるものです。
VM全体の評価と方針は[現行アーキテクチャ](../../../../docs/architecture/target-state.md#再構築性とbackupの方針)を参照してください。

## 実機確認（2026-10-12）

運用者がVMで確認した記録では、`elasticsearch`・`kibana`・`flowcoll`は3つともactiveでした。
フローのindexは日次でrolloverし、2026-10-08〜10-11に作成されたindexにフローが入っていました。
Kibanaのdashboardは36個、root diskの使用量は123G中17Gでした。
[#34](https://github.com/koji-genba/homelab/issues/34)（取り込み停止）は、3サービスがactiveであること、
write aliasが最新のrollover indexを指していること、`elastiflow-flow-*`の件数が増えていることをVMで確認し、
2026-10-12にcloseしました。いつ・何をして復旧したかは確認していません。

## アクセス方法

通常はtailnet接続済みの管理端末から `https://elastiflow.kojigenba-srv.com` を開きます。
AdGuard rewriteは既存Webサービスと同じ `web_ip`（現行はApps VMのtailnet IP）を返し、
CaddyがHTTPSを終端して `http://192.168.10.103:5601` へ中継します。
Caddyの `admin_networks` で接続元を制限します。Kibana自体には認証がなく、
Caddy経由のアクセスを保護するのはこの接続元制限です。
LANからのフォールバックは `http://192.168.10.103:5601` です。直IP経由にはCaddyの制限がかかりません。
判断は[ADR-0009](../../../../docs/adr/0009-elastiflow-caddy-fqdn.md)を参照してください。

`/etc/kibana/kibana.yml` はAppsのAnsible管理外で、`install.sh`による手動導入後のVM設定です。
共有リンク等の絶対URL用に `server.publicBaseUrl: "https://elastiflow.kojigenba-srv.com"` を
設定する作業は任意の手動作業とし、必要性は反映後に共有リンク・redirectの動作を確認して判断します。
設定を変更する場合はKibanaの再起動が必要です。

### FQDN変更の反映と確認

1. mainへのマージ後、通常の15分reconcileでCaddyとHomepageの変更が反映されます。
2. DNS rewriteは管理端末から手動の `make ansible-apply` で反映します。
   AdGuard設定の変更を検出すると全Compose projectが再作成され、DNS/SMB等が短時間途切れます。
3. 反映後に管理端末で名前がApps VMのtailnet IPへ解決されること、HTTPS証明書、
   Homepageからの画面表示、dashboard・共有リンク・redirectの動作を確認します。
   Caddyへ到達できる許可外の接続元からは403となることも確認します。
   502の場合はApps VMからElastiFlow VMのTCP 5601への到達性とKibanaの稼働を確認します。

2026-10-22にPR #116をマージし、reconcileと `make ansible-apply` で反映しました。
名前解決（Apps VMのtailnet IP）、HTTPS証明書、`/app/home` の表示、dashboard 36個、
許可外の接続元からの403を確認しました。共有リンクと `server.publicBaseUrl` は未確認です。

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

このrootでは全6 Proxmox root共通のtoken `terraform@pve!terraform`を使います。
2026-10-25に共通tokenへ移行済み（[記録](../../../../docs/operations/apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)）。
実行前にKeePassXCから`TF_VAR_proxmox_api_token`を管理端末へ一時注入します。
Makeはこの環境変数をProxmox Terraform runnerへ名前で渡すため、値をMakeの出力へ展開しません。
tokenはrepository、tfvars、runtime SOPS bundle、VMへ保存しません。作業後は
`unset TF_VAR_proxmox_api_token`で管理端末の環境から削除します。

`terraform.tfvars.example`を同じdirectoryの`terraform.tfvars`へコピーし、`ssh_public_key`など
非秘密の値だけを設定します。既存ファイルは上書きしません。tfvarsはGit ignore対象です。
Proxmoxのuser / role / token / ACLの期待状態と既存環境からの移行は
[Proxmox側準備](../../../../docs/operations/apps-vm-recovery.md#terraform実行前のproxmox側準備)を正とします。

API認証とは別に、cloud-init snippetのアップロードにpve1の`root` SSHが必要です。
管理端末のssh-agentへ接続用の鍵を読み込み、`SSH_AUTH_SOCK`と`ssh-add -l`を確認します。
信頼できる経路でpve1のhost keyを照合して`known_hosts`へ登録します。Makeはagent socketと
`known_hosts`をtoolboxへmountします。`ssh_public_key`はguestへ配置する公開鍵で、providerのSSH認証とは別です。

`ssh_public_key` は、作成されるVMの `ubuntu` ユーザーへ登録される公開鍵です。VMへSSH接続するときは、この公開鍵に対応する秘密鍵を使います。

### 2. Terraform実行

2026-10-25のplanではリソース変更なし、`kibana_url` / `next_steps`のOutputs差分のみでした。
`b11bc12`以来applyしておらずstateのoutputsが古いためで、このPRとは無関係です。
この確認時点ではapplyすればoutputsだけ更新されます。このPRでは更新しません。

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

1. 管理端末のブラウザで `https://elastiflow.kojigenba-srv.com` を開く（Caddy/DNSの反映前やLANからのフォールバックは `http://192.168.10.103:5601`）
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
