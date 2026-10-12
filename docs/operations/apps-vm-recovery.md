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
| edge | `caddy-data` / `/data`、`caddy-config` / `/config` | Caddyのローカルstate。喪失時はNFS復旧だけでは戻らない |
| dns | `adguard-work` / `/opt/adguardhome/work` | AdGuardのwork領域。設定は別のbind mountへAnsibleが配置する |
| samba | `samba-state` / `/var/lib/samba`、`samba-logs` / `/var/log/samba` | Sambaのローカルstate/log。設定・credentialの再配置とvolume復元は別である |
| searxng | `searxng-cache` / `/var/cache/searxng` | 喪失を許容するcache（[SearXNG運用](searxng.md#構成)） |
| sparkdash | `sparkdash-config` / `/app/config` | unit/settings/history等。[backup・復旧方針](sparkdash.md#永続化backup復旧)に従う |
| monitoring | `gatus` / `/data` | 監視履歴・alert状態。backup対象外（[共通手順](application-lifecycle.md#通常のreconcile)） |

Homepageにはnamed volumeがない。edge/dns/sambaのbackup有無・復元可否はrepoから確定できないため、
VM backup等の運用記録で確認する。

## 管理端末の入力と接続前提

- `AGE_IDENTITY_FILE`は復元した読み取り可能なage identity、`AGE_RECIPIENT`は対応する暗号化先を指定する。
  `make state-backup-preflight`には両方が必要で、age roundtripを検査する。
- 生きたSSH agentへdeploy用・GitHub push用・pve1 root接続用の必要な鍵を読み込む。
  `SSH_AUTH_SOCK`がsocketを指し、`ssh-add -l`で鍵を確認できることを前提とする。
- `git remote get-url --push origin`がSSH URLを返し、GitHubの`state-backup`へpushできる権限を用意する。
  必要なSSH pushurlは管理端末側で設定する。preflightはSSH URL/socketの検査に加え、Makefile側で
  pushのdry-runを行う。
- Apps VM Terraform providerはAPI tokenに加えて、SSH agent経由のpve1への`root` SSHを使う
  （`files/infrastructure/terraform/apps-vm/providers.tf`）。API credentialだけでは足りない。
- GitHubとpve1、および接続対象のApps VMのhost keyを信頼できる経路で照合し、管理端末の
  `known_hosts`へ登録する。Apps VMを新規作成する場合の順序は[復旧フロー](#復旧フロー)に従う。
  単独の`ssh-keyscan`結果を自動的に信頼せず、toolboxのhost-key検証を有効なままにする。

## Terraform実行前のProxmox側準備

Proxmoxのuser・role・API token・ACLはGitにもTerraformにも宣言されておらず、Proxmox側へ手動で
用意しておく必要がある。これらが揃っていない、または欠落した状態で`terraform apply`を実行すると
`error creating VM: received an HTTP 403 response - Reason: Permission check failed`で失敗する。

### 用意が必要なもの

- user `terraform@pve`
- role `HomelabTerraform`（権限は後述）
- API token `terraform@pve!apps-vm`（現在の有効期限は2026-12-04 23:59 JST。期限切れでも同様に403で失敗する）。
  現行tokenは`privsep=0`で作成されており、user `terraform@pve`のACLをそのまま継承する。`privsep=1`で
  作り直すとtoken自身へのACL付与が別途必要になるため、下記のACLだけでは足りなくなる。
- 次の7 ACL path。`/vms/101`と`/nodes/pve1`はVM操作、`/storage/local`と`/storage/vmpool`はimage/disk
  配置、`/sdn/zones/localnetwork`とその子2件はNIC割当に必要。
  - `/vms/101`
  - `/storage/local`
  - `/storage/vmpool`
  - `/nodes/pve1`
  - `/sdn/zones/localnetwork`
  - `/sdn/zones/localnetwork/vmbr0/10`
  - `/sdn/zones/localnetwork/vmbr0/11`

### role `HomelabTerraform`の権限一覧

2026-09-06時点で実機のroleが保持している権限は次の20件である。この一覧でVM作成まで到達できることは
確認済みだが、最小権限であることまでは検証していない。

```text
Datastore.Allocate, Datastore.AllocateSpace, Datastore.AllocateTemplate, Datastore.Audit,
SDN.Use, Sys.AccessNetwork, Sys.Audit, Sys.Modify,
VM.Allocate, VM.Audit, VM.Config.CDROM, VM.Config.CPU, VM.Config.Cloudinit,
VM.Config.Disk, VM.Config.HWType, VM.Config.Memory, VM.Config.Network,
VM.Config.Options, VM.GuestAgent.Audit, VM.PowerMgmt
```

### 投入コマンド例

pve1のシェルで次を実行する（値は例。tokenのsecretは作成時に一度しか表示されないため、
表示された値をKeePassXCなど安全な場所へ即座に保管する）。

```sh
pveum role add HomelabTerraform -privs "Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,SDN.Use,Sys.AccessNetwork,Sys.Audit,Sys.Modify,VM.Allocate,VM.Audit,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.GuestAgent.Audit,VM.PowerMgmt"
pveum user add terraform@pve
pveum user token add terraform@pve apps-vm --expire <unixtime> --output-format json
pveum acl modify /vms/101 --user terraform@pve --role HomelabTerraform
pveum acl modify /storage/local --user terraform@pve --role HomelabTerraform
pveum acl modify /storage/vmpool --user terraform@pve --role HomelabTerraform
pveum acl modify /nodes/pve1 --user terraform@pve --role HomelabTerraform
pveum acl modify /sdn/zones/localnetwork --user terraform@pve --role HomelabTerraform
pveum acl modify /sdn/zones/localnetwork/vmbr0/10 --user terraform@pve --role HomelabTerraform
pveum acl modify /sdn/zones/localnetwork/vmbr0/11 --user terraform@pve --role HomelabTerraform
```

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
3. 上記7 pathのいずれかが欠けていれば、該当pathへ`pveum acl modify <path> --user terraform@pve --role HomelabTerraform`
   で再付与する。
4. ACLが揃っているのに403が続く場合は、tokenの有効期限切れを疑う。`pveum user token list terraform@pve`で
   期限を確認し、切れていれば新しいtokenを発行してsecretを差し替える。

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
   新規VMはTailscale package/daemonの準備後、未登録の`not Running`で停止する。
   [tailnet再登録手順](apps-vm-tailnet.md#現在の手順apps-vmを再構築再登録するとき)に従い、旧deviceを削除し、
   手動登録・同じIPv4への固定・tags/expiry確認を済ませてAnsibleを再実行する。
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
