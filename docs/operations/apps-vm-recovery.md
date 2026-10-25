# Apps VM復旧手順

ホストごと作り直す場合は[Proxmoxホスト復旧手順](proxmox-host-recovery.md)から始める。

- 開始条件: Proxmoxが導入済みで、NFS/ZFSデータが外部手順で復旧済み
- 目標: Git管理の定義から全アプリケーション機能を復旧する
- アーキテクチャ: [現行アーキテクチャと復旧目標](../architecture/target-state.md)

## 必要な復旧情報

- homelab Git repositoryと`state-backup` branchへのアクセス
- age復旧鍵を含むKeePassXC entry
- 文書化されたrole/ACLに対応するProxmox API credential（最小権限であることは未検証）
- Tailscale管理状態を復元する場合のTailscale OAuth credential
- cloud-initで投入するSSH private key、または差し替え用public key
- Cloudflare DNS token、application credential、Discord webhook、Healthchecks ping URL
- 復旧済みNFS exportとapplication data

Exportのclient scope、option、markerは[NFS export契約](nfs-export.md)に従う。

age private keyはApps VMへコピーしない。secretの復号は管理端末で行う。

`/etc/homelab/secrets/searxng.env`（SearXNGの`SEARXNG_SECRET`）はAnsibleが再生成するため、復元するものはない。

sparkDashのnamed volumeはNFS復旧に含まれない。2026-10-11時点では自動backupを構築せず、VM外の暗号化backupも
必須としない。volume喪失時は再deployでvolumeを再作成し、tokenとSSH鍵をSOPSから再配置して、UIで2台を
再登録する（約5分）。unit/settings/historyは元に戻らない。unit数・benchmark結果・保存secretが増えたら
backup方針を見直す。保存secretの暗号鍵はciphertextと同じvolumeに置かれる。
[sparkDash運用](sparkdash.md)のbackup・復旧手順を参照する。

現在のCompose定義は11 projects / 12 servicesで、Homepageも復旧対象に含む。
Homepageの設定はGitから復元し、認証はGatusと共用の`edge.env`をAnsibleで再配置する。
tmpfs上のlogs・生成ファイルは再作成され、NFSや追加secretの復元は不要である。
[Homepage運用](homepage.md)に従って起動と画面表示を確認する。

## VM内named volumeの復旧範囲

named volumeはNFSデータやTerraform stateからは復元されない。正となる一覧・container内のpathは
各`files/services/compose/<project>/compose.yaml`の`volumes:`で確認する。

| project | named volume / container内path | 復旧時の扱い |
| --- | --- | --- |
| edge | `caddy-data` / `/data`、`caddy-config` / `/config` | Caddyのローカルstate。`/data`のACME証明書・accountを失えば、`Caddyfile`のCloudflare DNS-01設定とAnsibleで再配置するtokenを使って再取得する |
| dns | `adguard-work` / `/opt/adguardhome/work` | 統計・query logは戻らない。設定はsecrets roleが別のbind mount `/etc/homelab/adguard/AdGuardHome.yaml`へ再生成する。UIでの変更もAnsible適用で上書きされる設計であり、永続させる変更はtemplate / allowlist / blocklistに入れる（[設定の正と反映方法](../../files/services/compose/dns/filters/README.md)） |
| samba | `samba-state` / `/var/lib/samba`、`samba-logs` / `/var/log/samba` | ログは戻らない。identityの再生成は2026-10-12に[compose.yaml](../../files/services/compose/samba/compose.yaml)が固定するimageの`/usr/local/bin/docker-entrypoint.sh`を読んで確認済み。起動のたびに`/var/lib/samba`の`passdb.tdb`・`secrets.tdb`・`group_mapping.tdb`・`*.tdb`を削除し、Gitの`config/users.json`の`localSid`を`net setlocalsid`で設定する。group / userのuid・gid・ridと`/run/samba-secrets`のpasswordから同じidentityを再生成する。共有設定はGitの`config/smb.conf`、passwordはsecrets roleから再配置する |
| searxng | `searxng-cache` / `/var/cache/searxng` | 喪失を許容するcache（[SearXNG運用](searxng.md#構成)） |
| sparkdash | `sparkdash-config` / `/app/config` | unit/settings/history等。[backup・復旧方針](sparkdash.md#永続化backup復旧)に従う |
| monitoring | `gatus` / `/data` | 監視履歴・alert状態。backup対象外（[共通手順](application-lifecycle.md#通常のreconcile)） |

Samba imageを更新した場合は、上表の再生成動作を再確認する必要がある。
Homepageにはnamed volumeがない。2026-10-12にpve1で確認したところ、Proxmoxのbackup jobも既存の
VM backupも無かった。`/etc/pve/jobs.cfg`は存在せず、`/etc/pve/vzdump.cron`にjobの行は無く、
`pvesm list <storage> --content backup`は`local` / `local-lvm` / `vmpool`とも0件、
`/var/lib/vz/dump`は空だった。`storage.cfg`にPBS / NFS / CIFSのbackup先も無い。
Apps VMはrepoから機能を再構築できるため、VM backupを取らない。
diskとともに失うのはAdGuardの統計・query log、Sambaのログ、Gatusの履歴、sparkDashのunit登録などである。
[再構築性とbackupの方針](../architecture/target-state.md#再構築性とbackupの方針)に従い、
上表の再生成・再配置はvolumeの復元とは区別する。

## 管理端末の入力と接続前提

- `AGE_IDENTITY_FILE`は復元した読み取り可能なage identity、`AGE_RECIPIENT`は対応する暗号化先を指定する。
  `make state-backup-preflight`には両方が必要で、age roundtripを検査する。
- 生きたSSH agentへdeploy用・GitHub push用・pve1 root接続用の必要な鍵を読み込む。
  `SSH_AUTH_SOCK`がsocketを指し、`ssh-add -l`で鍵を確認できることを前提とする。
- `git remote get-url --push origin`がSSH URLを返し、GitHubの`state-backup`へpushできる権限を用意する。
  必要なSSH pushurlは管理端末側で設定する。preflightはSSH URL/socketの検査に加え、Makefile側で
  pushのdry-runを行う。
- 全Proxmox Terraform providerはAPI tokenに加えて、SSH agent経由のpve1への`root` SSHを使う
  （`files/infrastructure/terraform/apps-vm/providers.tf`）。API credentialだけでは足りない。
- GitHubとpve1、および接続対象のApps VMのhost keyを信頼できる経路で照合し、管理端末の
  `known_hosts`へ登録する。Apps VMを新規作成する場合の順序は[復旧フロー](#復旧フロー)に従う。
  単独の`ssh-keyscan`結果を自動的に信頼せず、toolboxのhost-key検証を有効なままにする。

## Terraform実行前のProxmox側準備

この節を全Proxmox rootのuser / role / API token / ACLの期待状態の正とする。
Proxmox identityはTerraformでは管理せず、管理者がpve1で手動設定する。
作成やACL付与自体に管理権限が必要なため、通常のTerraform用tokenへidentity管理権限は与えない。
不足すると`HTTP 403 Permission check failed`になる。

### 実機確認・認証移行の実施記録（2026-10-25）

2026-10-12にuser `terraform@pve`、role `HomelabTerraform`の20権限、token `apps-vm`の
`privsep=0`と期限（2026-12-04 23:59:59 JST）、Apps VM用ACL 6 pathを実機と照合した。
当時のACLは`/vms/101`のみpropagate 1、それ以外は0で、user commentは
`Terraform Apps VM (VMID 101)`だった。廃止済みVLAN 11用ACLは同日に削除した。
Agent / RunnerのREADMEには2026-10-18のVMID 104 / 105用ACL・専用token準備の記録がある。

2026-10-25に運用者がスクリプトで共通tokenへの移行を実施し、出力を確認した。
すべてprivsep 0で同じuser ACLを継承するためtokenを分けても権限は分離されず、
旧Apps VM tokenも期限に伴う再発行が必要になるため統一した。

- 実施前は`HomelabTerraform`が既存20権限、ACLが8 path（Apps用6 pathと`/vms/104`・`/vms/105`、
  `/vms/*`のみpropagate 1）。tokenは`apps-vm`（期限2026-12-04 23:59:59 JST）、
  `agent-vm`・`runner-vm`（ともに2027-04-30 23:59:59 JST）の3本で、すべてprivsep 0だった。
- `HomelabTerraformClone`（`VM.Audit,VM.Clone`）を追加し、`/vms/102`・`/vms/103`・`/vms/111`へ
  `HomelabTerraform`（propagate 1）、`/vms/9000`へ`HomelabTerraformClone`（propagate 0）を追加した。
  既存role・ACL・tokenはこの追加時点では変更せず、ACLは12 pathになった。
- 旧コードから本ブランチの1本目のcommit時点のコードへ切り替え、旧`terraform@pve!apps-vm`で
  legacy 3 rootをplanした。gateway・stashPadDevはNo changes、ElastiFlowは既知のOutputs差分のみで
  リソース変更は無かった。
- 共通token `terraform@pve!terraform`を下記の期限・privsep・commentで発行し、secretをKeePassXCへ保存した。
  新tokenで全6 rootのplanを実施し、Apps VM（101）・Agent（104）・Runner（105）・gateway（102）・
  stashPadDev（111）はNo changes、ElastiFlow（103）は同じOutputs差分のみでリソース変更なしを確認した。
  各VM・snippetと、Apps / Agent / Runnerのcloud image download fileのrefreshが通った。
- 旧token `apps-vm`・`agent-vm`・`runner-vm`を削除し、一覧は`terraform`の1本だけになった。
  下記の期待状態（ACL 12 path、token 1本）は2026-10-25に実機と照合済み。
  user commentも同日に`Terraform Proxmox VMs`へ変更した。
- ElastiFlowとgatewayのlocal tfvarsから`proxmox_password`を各1行削除した。
  `proxmox_username`の行は無く、modeは0600。stashPadDevにはlocal tfvarsが無かったため、
  従来借用していたElastiFlowのtfvarsから`ssh_public_key`の1行だけを写して作成した。
  init時の古いprovider symlinkの対処は[stashPadDev README](../../files/infrastructure/terraform/stashpad-dev/README.md#トラブルシューティング)を参照する。

今回の移行について未検証なのは、新tokenでtemplate 9000からVMを新規cloneする操作
（`HomelabTerraformClone`の実使用）、role・ACLの最小権限性、gateway / ElastiFlow / stashPadDevの
再構築の通し確認。planのrefresh成功はclone・再構築の確認には含めない。
ElastiFlowのOutputs差分は`b11bc12`以来applyしていないためで、このPRとは無関係。

### 用意が必要なもの

- user `terraform@pve`（有効、comment `Terraform Proxmox VMs`）。API用のPVE realm userで、SSHの`root`とは別。
- role `HomelabTerraform`（既存20権限、下記）とtemplate読取・clone専用role `HomelabTerraformClone`。
- user `terraform@pve`のAPI tokenは次の1本。`privsep=0`でuser ACLを継承する。
  tokenを分けても権限は同じで、違いは失効・有効期限だけである。

  | token ID | 使用するTerraform root | 有効期限 |
  | --- | --- | --- |
  | `terraform@pve!terraform` | `apps-vm` / `agent-vm` / `runner-vm` / `elastiflow` / `tailscale-gateway` / `stashpad-dev` | 2027-10-31 23:59:59 JST（UNIX time `1824994799`） |

  commentは`Terraform (all Proxmox roots)`とする。
  全rootでKeePassXCから共通tokenを`TF_VAR_proxmox_api_token`として管理端末へ一時注入し、
  Makeの`TOOLBOX_PROXMOX_ENV`経由でrunnerへ渡す。tokenをtfvarsやrepositoryへ保存しない。
  `privsep=1`へ変更する場合はtoken ACLも必要になり、この手順の対象外。
- pve1の`root`へ公開鍵認証できるssh-agentと、照合済みのhost key。
  全rootが`proxmox_virtual_environment_file`のsnippetsを使うため、API tokenだけでは足りない。
  [providerのSSH仕様](https://github.com/bpg/terraform-provider-proxmox/blob/v0.81.0/docs/resources/virtual_environment_file.md#snippets)
  に基づく。APIのACLはSSHのroot権限を制限しない。

| ACL path | role / propagate | 操作と必要なprivilege（resource定義からの洗い出し） |
| --- | --- | --- |
| `/vms/101`、`/vms/102`、`/vms/103`、`/vms/104`、`/vms/105`、`/vms/111` | `HomelabTerraform` / 1 | 対象VMの作成・読取・削除 `VM.Allocate`, `VM.Audit`、CPU / memory / disk / cloud-init / NIC / OS / serial / options設定 `VM.Config.*`（下記列挙）、起動・再起動 `VM.PowerMgmt`、guest情報読取 `VM.GuestAgent.Audit` |
| `/vms/9000` | `HomelabTerraformClone` / 0 | gateway / ElastiFlow / stashPadDevのfull clone元。`VM.Audit`, `VM.Clone`。templateの変更・削除権限は与えない |
| `/storage/local` | `HomelabTerraform` / 0 | image download / import、snippetのstorage確認 `Datastore.Audit`, `Datastore.AllocateTemplate`, `Datastore.AllocateSpace`。既存の`Datastore.Allocate`も維持。snippet実体の転送は別途root SSH |
| `/storage/vmpool` | `HomelabTerraform` / 0 | full clone、OS / data disk割当・resize、cloud-init drive `Datastore.Audit`, `Datastore.AllocateSpace`。既存の`Datastore.Allocate`, `Datastore.AllocateTemplate`も維持 |
| `/nodes/pve1` | `HomelabTerraform` / 0 | node / network / storage情報取得、image download / import関連 `Sys.Audit`, `Sys.AccessNetwork`, `Sys.Modify` |
| `/sdn/zones/localnetwork`、`/sdn/zones/localnetwork/vmbr0/10` | `HomelabTerraform` / 0 | 全VMのVLAN 10 NIC割当 `SDN.Use`。templateのNICもVLAN 10なので、cloneでもtagなしbridgeの権限は不要 |

cloneの権限判定は[Proxmox公式のAPI実装説明](https://lore.proxmox.com/all/1686149104.s7kd1zg63z.astroid%40yuna.none/t/)
（clone元`VM.Clone`、clone先`VM.Allocate`、storage `Datastore.AllocateSpace`、bridge `SDN.Use`）を参照。
既定以外のVMID / node / datastore / bridge / VLANへ変更するときは、このACL対応も見直す。

稼働中のサービスはtokenを使わず、期限切れでも停止しない。共通tokenの期限切れ・失効・漏えいは
全6 rootの次回Terraform実行へ影響する。2027-10-31 23:59:59 JSTの期限後は、次の実行前に
再発行または期限延長が必要となる。再発行後はKeePassXCを更新し、全rootで新tokenを環境へ
注入し直してplanを確認する。今後の再発行時も、使用する全6 rootでリソース変更なしを確認し、
Outputs差分があれば原因を切り分けてから旧tokenを削除する。

### role `HomelabTerraform`の権限一覧

既存20権限を維持する。template用roleは`VM.Audit,VM.Clone`の2権限だけを持つ。

```text
Datastore.Allocate, Datastore.AllocateSpace, Datastore.AllocateTemplate, Datastore.Audit,
SDN.Use, Sys.AccessNetwork, Sys.Audit, Sys.Modify,
VM.Allocate, VM.Audit, VM.Config.CDROM, VM.Config.CPU, VM.Config.Cloudinit,
VM.Config.Disk, VM.Config.HWType, VM.Config.Memory, VM.Config.Network,
VM.Config.Options, VM.GuestAgent.Audit, VM.PowerMgmt
```

### 投入コマンド例

以下は今後の再実施・新規復旧時に管理者がpve1のシェルで行う手順。
新規復旧時だけuser / 既存roleを作成する。既存環境ではrole一覧・ACLを照合し、不足分のみ追加する。
既存roleに追加の権限があれば削らず維持する。共通tokenは新規復旧時または下記の移行時に作成し、
既に存在する場合は期限・privsep・commentを照合して再作成しない。
新規復旧時は運用者が将来の期限を決め、例の`1824994799`を必要に応じて変更する。token作成時に一度だけ表示される
secretはKeePassXCへ保管し、ログやGitへ残さない。

```sh
# 新規復旧時のみ（既存環境では実行しない）
pveum user add terraform@pve --comment 'Terraform Proxmox VMs'
pveum role add HomelabTerraform --privs 'Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,SDN.Use,Sys.AccessNetwork,Sys.Audit,Sys.Modify,VM.Allocate,VM.Audit,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.GuestAgent.Audit,VM.PowerMgmt'
```

```sh
# 新規復旧時または認証移行時（共通tokenが未作成の場合のみ）
pveum user token add terraform@pve terraform --privsep 0 --expire 1824994799 --comment 'Terraform (all Proxmox roots)' --output-format json
```

```sh
# 既存環境にも追加。roleが既に存在する場合は権限を照合して再作成しない
pveum role add HomelabTerraformClone --privs 'VM.Audit,VM.Clone'
pveum user modify terraform@pve --comment 'Terraform Proxmox VMs'
for vmid in 101 102 103 104 105 111; do
  pveum acl modify "/vms/$vmid" --user terraform@pve --role HomelabTerraform --propagate 1
done
pveum acl modify /vms/9000 --user terraform@pve --role HomelabTerraformClone --propagate 0
pveum acl modify /storage/local --user terraform@pve --role HomelabTerraform --propagate 0
pveum acl modify /storage/vmpool --user terraform@pve --role HomelabTerraform --propagate 0
pveum acl modify /nodes/pve1 --user terraform@pve --role HomelabTerraform --propagate 0
pveum acl modify /sdn/zones/localnetwork --user terraform@pve --role HomelabTerraform --propagate 0
pveum acl modify /sdn/zones/localnetwork/vmbr0/10 --user terraform@pve --role HomelabTerraform --propagate 0
```

`legacy_service_nic=true`を使う場合だけ`/sdn/zones/localnetwork/vmbr0/11`へ同roleをpropagate 0で
付与する。既定の`false`では不要で、廃止済みVLAN 11のACLは復活させない。

### 既存環境からの認証移行

既存環境は[上記の実施記録](#実機確認認証移行の実施記録2026-10-25)のとおり移行済み。以下は今後の再実施用の手順である。
identityの変更をTerraform applyで行わない。

1. pve1の管理者権限で`pveum role list`、`pveum acl list`、`pveum user token list terraform@pve`を
   確認する。上記期待状態の不足role / ACLのみ追加し、済みの環境では既存設定を維持する。
2. 上記の`pveum user token add terraform@pve terraform`コマンドで共通tokenを発行する。
   `privsep=0`、期限2027-10-31 23:59:59 JST、commentを照合し、一度だけ表示されるsecretを
   KeePassXCへ保存する。旧token 3本（`apps-vm` / `agent-vm` / `runner-vm`）はまだ削除しない。
3. legacy 3 root（ElastiFlow / Tailscale gateway / stashPadDev）のlocal `terraform.tfvars`を
   安全なeditorで開き、旧Proxmox API passwordとusernameの行を削除する。
   `ssh_public_key`など他の非秘密の値は保持する。tokenや秘密鍵は書かない。tfvarsが無い場合だけ
   各rootのexampleから作り、既存ファイルを上書きしない。全6 rootでtfvarsにtokenを保存しない。
   rootパスワードが残っていないことも確認し、内容をログやレビューへ出力しない。
   tfvarsはGit ignore対象のままにする。
4. pve1 root用の鍵をssh-agentへ読み込み、`SSH_AUTH_SOCK`、`ssh-add -l`、照合済み`known_hosts`を確認する。
   新規agentを起動する例は`eval "$(ssh-agent -s)"`、鍵の追加は`ssh-add /path/to/pve1-key`。
5. KeePassXCから共通token `terraform@pve!terraform`を`TF_VAR_proxmox_api_token`へ一時注入する。
   値は`user@realm!token=secret`形式で渡し、shell履歴やコマンド出力にsecretを残さない。
   repository rootから全6 rootで次を実行し、全rootでリソース変更がないことを確認する。

   ```sh
   for root in apps-vm agent-vm runner-vm elastiflow tailscale-gateway stashpad-dev; do
     make terraform-plan TERRAFORM_ROOT="files/infrastructure/terraform/$root" || break
   done
   ```

   provider認証だけの変更なのでresource再作成は想定しない。差分・destroy / replaceや403があれば
   applyせず、既存drift・token / ACLを調査する。保存planはmode `0600`のまま、確認後に削除する。
   途中失敗・未確認のrootがあれば旧tokenは削除しない。
6. 全6 rootでリソース変更なしを確認し、Outputs差分があれば原因を切り分けてから、pve1の管理者権限で旧token 3本を削除する。

   ```sh
   pveum user token remove terraform@pve apps-vm
   pveum user token remove terraform@pve agent-vm
   pveum user token remove terraform@pve runner-vm
   pveum user token list terraform@pve
   ```

   一覧で旧3本が無く、共通token `terraform`の期限・privsep・commentが期待どおりであることを確認する。
   作業後は`unset TF_VAR_proxmox_api_token`で環境から削除する。

共通tokenはprivsep 0なのでuser ACLの拡張が全6 rootへ有効となる。SSHには別途root権限がある。
権限付与の誤りはTerraformの403、鍵やhost keyの不足はsnippet転送失敗になる。
古い保存planやstate / backupには過去の機微情報が残る可能性があるため従来どおり保護する。
認証移行の確認ではapplyを行わず、稼働VMの再作成・再起動を伴わせない。

### 罠: destroyはACLを道連れに削除する

**VMIDを`terraform destroy`で削除すると、Proxmoxは`/vms/<vmid>`のACLエントリをVMと一緒に自動削除する。**
2026-09-06のPhase 3再構築試験で実際にこの罠にかかり、`terraform destroy`でVMID 112を削除した直後の
`terraform apply`が上記の403で失敗した。image download（`proxmox_download_file`）とcloud-init snippet
作成（`proxmox_virtual_environment_file`）は成功しており、VM create（`VM.Allocate`が必要な操作）だけが
拒否された。role自体は`VM.Allocate`を保持していたが、それを与えるpath `/vms/112`が消えていたことが原因である。

したがって、destroyしてから同じVMIDへ再applyする手順では、**apply前に`/vms/<vmid>`のACLを
`pveum acl modify`で再付与する**工程を必ず挟む。

### 403 `Permission check failed`が出たときの診断手順

1. `pveum acl list`で対象pathへのACLエントリが存在するか確認する。
2. pve1上で`grep -E '^(acl|token):' /etc/pve/user.cfg`を実行し、user.cfgの生データからも
   ACLとtokenの存在を確認する。
3. 既定構成で必要なpath（legacy NICを有効にする場合はVLAN 11用も含む）のいずれかが欠けていれば、
   [投入コマンド例](#投入コマンド例)の該当コマンドで再付与する。
4. ACLが揃っているのに403が続く場合は、tokenの有効期限切れを疑う。`pveum user token list terraform@pve`で
   期限を確認し、切れていれば新しいtokenを発行して、KeePassXCの共通tokenを更新し、全6 rootで`terraform@pve!terraform`を環境変数へ注入し直す。

## 復旧フロー

再構築は[2026-09-06に当時の手順で実証された記録](../archive/implementation-status.md#phase-3-再構築性の証明2026-09-06全項目合格)がある。
2026-10-12にhost-key確認の順序などを実装に合わせて並べ替え、前提を補った。
以下は実装から導いた手順で、並べ替え後の順序は実機では未検証（この順序で通しでは実行していない）。
通常の復旧は現行mainの希望状態へ戻す。compose roleは`homelab_repo_branch: main`をVMへcloneし、
既存cloneは`update: false`で更新しない。管理端末で過去commitを選ぶだけではVMに同じcommitは配布されない。
過去commitでの復旧には管理端末、VM checkout、Ansible描画物、data/schemaの対応を別途確認する必要があり、
ここではその手順を定義しない。

1. repositoryをcloneし、管理端末を現行mainの定義に揃える。
2. KeePassXCからage keyを文書化されたlocal pathへ復元し、mode `0600`にする。
   [管理端末の入力と接続前提](#管理端末の入力と接続前提)とProxmox側準備を満たす。
3. Makefileでdigest固定したmanagement toolboxをbuildまたはpullする。
4. `AGE_IDENTITY_FILE=/path/to/identity make state-restore`で暗号化Terraform stateを復元する。
   helperは`origin/state-backup`をfetchし、branchをcheckoutせず、
   `terraform-state/files/infrastructure/terraform/**/terraform.tfstate.age`だけを受け付ける。
   全復号stateを検証してからatomic renameでmode `0600`のfileを配置し、既存平文stateは上書きしない。
   plan前に復元結果をreviewする。stateが無ければresourceの存在を調べる。

   backupにあるTerraform rootのdirectoryがcheckoutに無いと、`state-restore.sh`は全体を中止する。
   rootを撤去するときはローカルのstateも削除して`make state-backup`を取り直し、backupから外す。
   `state-backup.sh`はローカルに無くなったstateの暗号化copyを削除する。旧`k8s-cluster`は
   2026-10-12にローカルdirectoryとbackupから撤去済み（backup commit `aae3f05`）。

   - Proxmox VMが存在しない場合: 空stateから作成する。
   - Proxmox/Tailscale resourceが存在する場合: 文書化されたimport targetで対応する。
   - plan reviewなしに既存resourceへ空stateをapplyしない。
5. 次の入口でsecret、静的なIP/VMID整合、Ansible構文、backup前提を確認する。
   `preflight`は静的検査であり、IP/VMIDの空きや実機疎通は判定しない。
   `ansible-check`もsyntax-checkであり、実機適用の試験ではない。

   ```sh
   AGE_IDENTITY_FILE=/path/to/identity make secrets-decrypt-check
   make preflight
   make ansible-check
   AGE_RECIPIENT=<age-recipient> AGE_IDENTITY_FILE=/path/to/identity make state-backup-preflight
   ```

6. VMの有無に応じて進める。
   - 既存VMへ接続する場合: Proxmox console等でそのVMのhost-key fingerprintを確認し、
     提示keyと照合して`known_hosts`へ登録する。planで意図しないdestroy/replaceが無いことを確認する。
   - VMを新規作成する場合: VMID/IPが解放されていることを外部で確認し、下記のTerraform applyとbootの後、
     最初のAnsible接続前に新VMのhost keyを確認・登録する。旧VMのkeyをそのまま信頼しない。

   ```sh
   make terraform-plan
   AGE_RECIPIENT=<age-recipient> AGE_IDENTITY_FILE=/path/to/identity make terraform-apply
   ```

   planをapply前にreviewする。既定rootは`files/infrastructure/terraform/apps-vm`で、保存planは
   同rootの`terraform.tfplan`（mode `0600`、ignore対象）である。applyは欠落、symlink、緩すぎるmodeを
   拒否し、`-auto-approve`を使用しない。apply後に暗号化state recovery copyを作成してpushする。
   詳細は[Apps VM Terraform入口](../../files/infrastructure/terraform/apps-vm/README.md)を参照する。
7. `AGE_IDENTITY_FILE=/path/to/identity make ansible-apply`でbootstrapとdeploymentを行う。
   新規構築・復旧で`apps.yml.example`から入力を作る場合は、現行ネットワークの初期値
   （`network_migration_complete: true`、legacy系flagは`false`）を使い、
   `application_cutover_confirmed: false`でNFSをread-only、アプリ・reconcile・dead-manを停止して始める。
   新規VMはTailscale package/daemonの準備後、未登録の`not Running`で停止する。
   [tailnet再登録手順](apps-vm-tailnet.md#現在の手順apps-vmを再構築再登録するとき)に従い、旧deviceを削除し、
   手動登録・同じIPv4への固定・tags/expiry確認を済ませる。exampleの`apps_tailnet_ip`は例示値なので
   固定した実値に合わせ、DNSの`internal_records_use_tailnet_ip`を`true`にする。
   復旧したexport・markerと他writerの停止を確認してから`application_cutover_confirmed`も`true`にし、
   Ansibleを再実行する。これによりsecretを配置し、アプリとtimerを起動する。
   既存cloneの更新が必要な場合は[通常のreconcile](application-lifecycle.md#通常のreconcile)を確認する。
   全NFS mountとmarkerはcontainer起動前にstorage roleとmount guardが検証する。
8. 必要な場合だけ、[別Terraform rootの手順](../../files/infrastructure/terraform/tailscale/README.md)で
   Tailscale DNS/route/grantを復元する。現行と整合していればDNSのLAN IPから100.xへの差分を期待しない。
9. 各serviceの受入試験、Gatus、Discord、Healthchecks.ioを確認し、復旧commit SHA、image digest、
   state backup revision、試験結果を記録する。

## 保持する復旧資産とデータ

[2026-09-25の引き継ぎ記録](../archive/next-session.md#安全条件と既知の制約)では、`state-backup`を
削除せず保持し、Phase 5直前snapshot `tank-gen2/data/k8s-volumes@pre-phase5-retire-20260923`も保持中で、
削除は別途明示承認が必要とされていた。2026-10-12にpve1で
`zfs list -t snapshot | grep pre-phase5`を実行し、このsnapshotの現存を確認した。
復旧作業でこれらを削除しない。snapshot削除は復旧とは別の承認境界とする。

同記録で保護対象とされた`tank-gen2/data/k8s-volumes`とSillyTavern、stashPad prod/stagingの3 directoryに加え、
現在はOpen WebUIのdirectoryも保護する。正となるserver pathは
`files/infrastructure/ansible/apps/group_vars/apps.yml`の`nfs_mounts`にある
`sillytavern-data`、`stashpad-prod-data`、`stashpad-staging-data`、`open-webui-data`の`export`で確認する。
これらを利用中のdataset/dataとして扱い、旧構成名を理由に削除しない。他の現役NFS dataも保護する。

## 失敗時の規則

- NFS mountまたはmarkerの失敗: 停止し、Dockerが空のbind sourceを作ることを許可しない。
- 予期しないTerraform destroy/replace: 停止し、state/import対応を調査する。
- IPが応答する、またはARP/DHCP inventoryに現れる: 停止し、そのIPを取得しない。
- 証明書発行の失敗: HTTP backendをprivateのままにし、production ACMEを再試行する前にDNS-01/configを解決する。
- application schema/versionの不一致: 新writerを停止し、直前に固定したimage digestへ戻す。

## 復旧の検証

[移行時の受入試験一覧](../archive/k8s-to-compose.md)と各serviceの現行runbookを使う。VM boot成功やcontainerがhealthyになっただけでは復旧完了とは
みなさない。applicationのread/write、DNS動作、SMB identity、TLS、通知、fail-closed mountがすべて合格する
必要がある。

[2026-09-25の引き継ぎ記録](../archive/next-session.md#引き続き必要なこと)では、Trusted LAN・tailnetからの
アプリ操作、SMB read/write、通知など対話を要する受入再確認は未実施だった。
2026-10-12に管理端末から`curl --resolve`でLAN IP `192.168.10.101`へ接続し、
次の9 FQDNのHTTPS応答を確認した（いずれも`kojigenba-srv.com`配下）。

| FQDN | HTTP status |
| --- | --- |
| `dns.kojigenba-srv.com` | 302 |
| `status.kojigenba-srv.com` | 401 |
| `homepage.kojigenba-srv.com` | 401 |
| `sillytavern.kojigenba-srv.com` | 401 |
| `openwebui.kojigenba-srv.com` | 200 |
| `searxng.kojigenba-srv.com` | 200 |
| `sparkdash.kojigenba-srv.com` | 200 |
| `prod.stashpad.kojigenba-srv.com` | 200 |
| `staging.stashpad.kojigenba-srv.com` | 200 |

これはHTTPS到達確認だけである。同日の確認では、アプリの実操作、SMBのread/write、Discord通知・
dead-man、tailnet経由の確認は未実施のままである。復旧時に操作者が再確認し、日付と結果を記録する。
