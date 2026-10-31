# ElastiFlow構築

Terraform/cloud-initでProxmox VE上にVMを作成し、専用Ansible rootでElastiFlow（ネットワークフロー分析）を構成します。

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

サービスはTerraform/cloud-initによるVM作成後、[専用Ansible root](../../ansible/elastiflow/)で
版固定したpackage・設定・dashboard importを宣言します。
2026-10-25に運用者がVM 103を作り直し、空のVMからの構成・sFlow受信・再実行時の`changed=0`を実機で確認しました。
template 9000も同日にscriptで作り直しました（[ホスト復旧](../../../../docs/operations/proxmox-host-recovery.md#template-vm-9000)）。
2026-10-12に、運用者は過去のフローデータは不要と判断し、VM backupを取らないと決めました。
VMを失ったら作り直し、フローは空のindexから取り込み直します。
この決定は再構築の実証前に、失ってよいという判断で行ったものです。
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

`/etc/kibana/kibana.yml` はpackage既定のlogging・pid設定を残し、ElastiFlow専用Ansibleで
`server.host` と `elasticsearch.hosts` の2キーだけを重複除去＋lineinfileで管理します。
共有リンク等の絶対URL用の `server.publicBaseUrl` は現時点では宣言していません。
必要性は共有リンク・redirectの動作を確認して判断し、追加する場合はAnsibleの管理対象キーに加えて
`make ansible-apply-elastiflow` で反映します（handlerでKibanaを再起動）。

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

### 3. アプリケーションのセットアップ（専用Ansible）

2026-10-25に現物から採取した版・構成はUbuntu 24.04 amd64、Elasticsearch/Kibana **8.19.22**、
`flowcoll` **7.26.2**です。これを[専用rootのgroup_vars](../../ansible/elastiflow/group_vars/elastiflow.yml)に固定しました。
2026-10-25にVM 103の再作成後、この専用Ansibleによる構成と再実行時の`changed=0`を実機で確認しました。

cloud-init完了後、管理端末で既存のSSH-agentとホスト鍵確認を準備し、repository rootから実行します。
秘密鍵をinventoryへ書き込まず、対象がVMID 103の `192.168.10.103` であることを確認してください。

```bash
make ansible-lint-elastiflow
make ansible-check-elastiflow
# 本番操作。承認した作業枠で実行する。
make ansible-apply-elastiflow
# 再実行して changed=0 を確認する。
make ansible-apply-elastiflow
```

`ansible-check-elastiflow` はsyntax-checkのみです。`ELASTIFLOW_ANSIBLE_ARGS=--check` は既存VMの
変更予告に使えますが、空のVMでは未作成の設定・service等に依存するため、初回構築の代替検証にはなりません。
Appsのapply/reconcileやcloud-initにはアプリ構成を混ぜません。

宣言する内容:

- Elastic 8.x apt repoからElasticsearch/Kibanaを同じ **8.19.22** でinstallし、両方をapt hold。
  版更新時もgroup_varsを変更し、Ansibleがheld packageの版変更とholdを管理します。
- collectorは旧scriptと同じ[配布URL](https://elastiflow-releases.s3.us-east-2.amazonaws.com/flow-collector/flow-collector_7.26.2_linux_amd64.deb)から取得。
  期待SHA256は同URLの[.sha256](https://elastiflow-releases.s3.us-east-2.amazonaws.com/flow-collector/flow-collector_7.26.2_linux_amd64.deb.sha256)を2026-10-25に取得してgroup_varsへ記録しました。
- ESはsingle-node、`network.host: 0.0.0.0`、`xpack.security.enabled: false`、
  `indices.query.bool.max_clause_count: 8192`、`search.max_buckets: 250000`、heap 12g
  （`jvm.options.d/heap.options`）。生成されたsecurity/TLS設定は管理templateで置換し、
  旧scriptと同じ6つのTLS secure setting名だけkeystoreから除去します（値は読みません）。
- Kibanaは `server.host: 0.0.0.0`、`elasticsearch.hosts: ["http://127.0.0.1:9200"]`。
- `vm.max_map_count=262144` をVM内で永続化。flowcoll.ymlはpackage既定を残し、
  `EF_LICENSE_ACCEPTED=true`、`EF_PROCESSOR_POOL_SIZE=2`、`EF_OUTPUT_ELASTICSEARCH_ENABLE=true`、
  `EF_OUTPUT_ELASTICSEARCH_ADDRESSES="127.0.0.1:9200"`、`EF_OUTPUT_ELASTICSEARCH_TLS_ENABLE=false`、
  `EF_OUTPUT_ELASTICSEARCH_INDEX_TEMPLATE_SHARDS=1`、`EF_OUTPUT_ELASTICSEARCH_INDEX_TEMPLATE_REPLICAS=0` の7キーのみ管理。
  受信ポートはpackage既定（UDP 2055/4739/6343/9995）のままです。
- 設定変更はhandlerで再起動。ESのcluster health（yellow/green）、Kibanaのavailableを
  各60回・5秒間隔で待ち、時間切れは失敗にします。その後dashboardをimportします。

Community版ではlicense key / account IDは不要で、2026-10-25の現物にもありません。
将来秘密を入れる場合は専用SOPS入力からVMのroot限定ファイルへ `no_log` で配置し、Terraform/cloud-initへ渡しません。

### 4. ルーター側（IX2215）でsFlowエクスポートを設定

[Network READMEのsFlow節](../../network/README.md#sflow)を参照してください。repoの
[config.txt](../../network/config.txt)にはagent `192.168.10.1`、collector `192.168.10.103`が定義済みです。
実機への反映状態とcollector側の受信は別途確認してください。

### 5. Kibanaダッシュボードのインポート（Ansible内）

Kibana 8.14以降用のCODEX版 `kibana/flow/kibana-8.14.x-flow-codex.ndjson` を
upstream commit [`2c73f16bfd583fef65304013025d1dad048489e5`](https://github.com/elastiflow/elastiflow_for_elasticsearch/commit/2c73f16bfd583fef65304013025d1dad048489e5)
のraw URLとSHA256で固定しています。type別件数はdashboard 36、visualization 365、map 2、search 2、
index-pattern 3（計408、export-detailsを除く）で、2026-10-25の現物と一致しました。
件数の一致は個々のsaved objectの内容が同一であることまでは保証しません。

EULAの再配布制限に従いndjsonはrepoに置きません。VMで直接取得し、checksum検証後、
Kibana saved objects import APIでdefault Spaceに `overwrite=true` で取り込みます。
成功・408件・errorsなしを確認したときだけ `/var/lib/homelab-elastiflow/dashboard.sha256` にchecksumを記録し、
markerが無い場合、固定SHA256が変わった場合、またはdashboardが0件の場合だけimportします。
markerがあれば通常の再実行では上書きしません。部分的な削除から再importする場合は、
影響を確認してこのmarkerを削除し、専用applyを実行します。
版更新ではpackage版だけでなくdashboardの対応版・commit・checksum・期待件数も併せてレビューします。

### 6. 動作確認

```bash
ssh ubuntu@192.168.10.103
systemctl status elasticsearch kibana flowcoll
curl -s http://127.0.0.1:9200/_cat/indices?v | grep elastiflow
```

IX2215側の設定反映後、`elastiflow-*` インデックスにデータが増え始めることを確認します。
再構築の実証では、package版・apt hold・2回目のchanged=0・再起動後の自動起動・sFlow受信・
index件数の増加・dashboard表示・FQDN/共有リンク/許可外403も確認してください。

## VM 103 の作り直し

2026-10-25に運用者がこの手順でVM 103を作り直し、実機で確認しました。
停止・破棄を伴うため、承認した作業枠で行います。
Makeのコマンドはrepository rootで実行します。認証は上の手順どおり
`TF_VAR_proxmox_api_token` を管理端末の環境変数へ一時注入し、コマンドにtokenの値を書きません。

1. **作り直す前の確認**: 過去のフローデータとKibanaのdashboardへの変更が消えることを承知したうえで、
   [既存のstate手順](#terraform-state)どおりTerraform stateをbackupします。VM backupは取りません。
2. **VMだけをdestroy**: 保存されるplanがVM 103だけをdestroyする内容であることを確認してからapplyします。
   `-target` はcloud-init snippetのfile resourceを残すために使います。

   ```bash
   make terraform-plan TERRAFORM_ROOT=files/infrastructure/terraform/elastiflow TERRAFORM_PLAN_ARGS='-destroy -target=proxmox_virtual_environment_vm.elastiflow'
   # planを確認してから実行する。
   make terraform-apply TERRAFORM_ROOT=files/infrastructure/terraform/elastiflow
   ```

3. **VMのACLを付け直す**: ProxmoxはVMをdestroyすると `/vms/103` のACLエントリも削除するため、
   createの前にpve1のrootで次を実行します。
   [destroy時のACL削除の注意](../../../../docs/operations/apps-vm-recovery.md#罠-destroyはaclを道連れに削除する)には、
   2026-09-06に同じ原因でcreateが403になった記録があります。

   ```bash
   pveum acl modify /vms/103 --user terraform@pve --role HomelabTerraform --propagate 1
   ```

4. **別のtemplateを使う場合**: 例として検証用9001から作る場合は、pve1のrootでそのtemplateにも
   clone用ACLを付け、次のcreate planに `TERRAFORM_PLAN_ARGS='-var template_vm_id=9001'` を渡します。
   別のIDを使う場合も `/vms/<id>` と `template_vm_id=<id>` を合わせます。
   `clone.vm_id` は `ignore_changes` 対象なので、あとでtemplate 9000を作り直しても差分になりません。

   ```bash
   pveum acl modify /vms/9001 --user terraform@pve --role HomelabTerraformClone --propagate 0
   ```

5. **create**: 通常は次のplanを実行し、VMの `1 to add` を確認してからapplyします。
   別templateの場合はplanの末尾に上の `TERRAFORM_PLAN_ARGS='-var template_vm_id=9001'` を付けます。

   ```bash
   make terraform-plan TERRAFORM_ROOT=files/infrastructure/terraform/elastiflow
   # planの1 to addを確認してから実行する。
   make terraform-apply TERRAFORM_ROOT=files/infrastructure/terraform/elastiflow
   ```

6. **cloud-initとSSHの準備**: cloud-init完了を待ちます。SSHのhost keyが変わるため、
   pve1のroot consoleからguest agent経由で公開鍵を取得します。

   ```bash
   qm guest exec 103 -- cat /etc/ssh/ssh_host_ed25519_key.pub
   ```

   管理端末で `ssh-keyscan -t ed25519 192.168.10.103` の公開鍵の種類・本体を上の出力と照合します。
   一致を確認してから `known_hosts` の古い `192.168.10.103` の行を削除し、新しい鍵を登録します。
7. **専用Ansibleを2回実行**: 初回で構成し、2回目は `changed=0` を確認します。

   ```bash
   make ansible-apply-elastiflow
   make ansible-apply-elastiflow
   ```

8. **動作確認**: Elasticsearch/Kibana 8.19.22・flowcoll 7.26.2とElasticのapt hold、
   `elasticsearch`・`kibana`・`flowcoll` の3 serviceがactiveであることを確認します。
   sFlow受信後、indexの `docs.count` が時間とともに増えること、dashboardが36件あること、
   `https://elastiflow.kojigenba-srv.com` の表示を確認します。

### 再構築の実機確認（2026-10-25）

運用者がVMだけをdestroyし、`/vms/103`のACLを付け直して9001からcreateしました。
初回はtemplateのtagなしnet0が原因で`SDN.Use`のHTTP 403となり、`tag=10`に変更後44秒でcreateが成功しました。
SSH host keyはguest agentとssh-keyscanの出力を照合して登録し、cloud-initは`status: done`でした。
初回Ansibleはdashboard importのcontroller側ファイル参照で停止（`changed=21`, `failed=1`）しましたが、VM上のcurlへ修正済み（`ff202c7`）で、再実行は`changed=2`, `failed=0`、さらにもう1回は`changed=0`, `failed=0`でした。

- Elasticsearch / Kibana 8.19.22（両方apt hold）、flowcoll 7.26.2、3 serviceのactive / enabledを確認しました。
- Elasticsearchはgreen、Kibana 8.19.22はavailableでした。saved objectsはdashboard 36 / visualization 365 / map 2 / search 2 / index-pattern 3でした。
- flowの`docs.count`は120秒で895 → 1111に増え、sFlow受信を確認しました。管理端末から`https://elastiflow.kojigenba-srv.com/api/status`は200でした。
- destroy / create後にstate-backupをpushし、最後のplanは`-var`なし（既定の`template_vm_id=9000`）で`No changes`でした。`clone.vm_id`は`ignore_changes`対象です。

過去のフローデータとKibanaのdashboardへの変更は方針どおり失われました。
共有リンク / `server.publicBaseUrl`は未検証です。Homepage / GatusにElastiFlow監視はありません。

## セキュリティ上の注意

- 専用Ansibleはホームラボの規模・用途に合わせ、Elasticsearchの `xpack.security.enabled` を無効化しています（認証なし）。repoの`config.txt`では、Server VLAN(10)内に加え、Trusted VLAN(20)からServer VLAN(10)への通信が`main-out`と`trusted-dyn`で許可されます。ServerからTrustedへの未要求通信は`trusted-in`で拒否されます。この許可経路からKibana/Elasticsearchに認証なしで到達する構成です。気になる場合はElastic Stack付属のセキュリティ機能を有効化するか、IX2215側のACLでVLAN10宛のTCP 5601/9200を制限してください。

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


## UPS停止用のstartup設定

VMのstartupは[pve1 Ansible](../../ansible/pve1/README.md)の `guest_startup` roleで管理し、
このrootではstartupブロックを置かず `lifecycle.ignore_changes` に含める。
Terraform tokenには `/` の `Sys.Modify` がないため、権限を増やさずrootの `qm set --startup` で反映する。
VM作成・再作成後はpve1 Ansibleのcheck→applyが必要。値・順序・確認は
[UPS運用](../../../../docs/operations/ups-nut.md)に従う。startupの単独更新にVMの再起動は不要。
