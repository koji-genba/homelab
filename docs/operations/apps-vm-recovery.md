# Apps VM復旧手順

- 開始条件: Proxmoxが導入済みで、NFS/ZFSデータが外部手順で復旧済み
- 目標: Git管理の定義から全アプリケーション機能を復旧する
- アーキテクチャ: [目標アーキテクチャ](../architecture/target-state.md)

## 必要な復旧情報

- homelab Git repositoryと`state-backup` branchへのアクセス
- age復旧鍵を含むKeePassXC entry
- 文書化された最小権限を持つProxmox API credential
- Tailscale管理状態を復元する場合のTailscale OAuth credential
- cloud-initで投入するSSH private key、または差し替え用public key
- Cloudflare DNS token、application credential、Discord webhook、Healthchecks ping URL
- 復旧済みNFS exportとapplication data

Exportのclient scope、option、markerは[NFS export契約](nfs-export.md)に従う。

age private keyはApps VMへコピーしない。secretの復号は管理端末で行う。

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
- 次の7 ACL path。`/vms/112`と`/nodes/pve1`はVM操作、`/storage/local`と`/storage/vmpool`はimage/disk
  配置、`/sdn/zones/localnetwork`とその子2件はNIC割当に必要。
  - `/vms/112`
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
pveum acl modify /vms/112 --user terraform@pve --role HomelabTerraform
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

1. repositoryをcloneし、復旧対象のcommitをcheckoutする。
2. KeePassXCからage keyを文書化されたlocal pathへ復元し、mode `0600`にする。
3. version固定のmanagement toolboxをbuildまたはpullする。
4. Proxmox consoleまたは別の信頼できるout-of-band channelからApps VMのSSH host-key fingerprintを確認する。
   VMが提示するkeyと照合してから、管理端末の`known_hosts`へ追加する。単独の`ssh-keyscan`結果を
   自動的に信頼してはならない。toolboxのhost-key検証は有効なままにする。
5. `state-backup`をfetchし、`AGE_IDENTITY_FILE=/path/to/identity make state-restore`で暗号化Terraform
   stateを復元する。helperはbranchをcheckoutせず`origin/state-backup`を読み、
   `terraform-state/files/infrastructure/terraform/**/terraform.tfstate.age`だけを受け付ける。
   全復号stateを検証してからファイルを配置し、atomic renameでmode `0600`にする。既存の平文stateは
   上書きしない。plan前に復元結果をreviewする。
6. stateがない場合はresourceの存在を調べる。
   - Proxmox VMが存在しない場合: 空stateから作成する。
   - Proxmox/Tailscale resourceが存在する場合: 文書化されたimport targetに従う。
   - plan reviewなしに、既存resourceへ空stateをapplyしてはならない。
7. secretと平文stateのpreflight checkを実行する。
8. 初回Terraform apply前に`make state-backup-preflight`を実行する。age roundtrip、SSH agent/socket、
   SSH pushurl、平文state checkが合格する必要がある。
9. Terraform planを実行し、mode `0600`のignore対象plan fileへ保存する。意図したresourceだけが変更される
   ことを確認する。保存planにはsensitive valueが含まれる場合があるため、state fileと同様に保護する。
10. review済みの保存planだけを`make terraform-apply`でapplyする。targetはplanの欠落、symlink、緩すぎる
    modeを拒否し、`-auto-approve`を使用しない。apply後に暗号化state recovery copyを作成する。
11. Ansible bootstrapとservice deploymentを実行する。
12. containerを起動する前に、全NFS mountとmarkerを検証する。
13. Compose projectをdeployし、移行runbookの受入試験を実行する。
14. 必要な場合だけ、別Terraform rootを使ってTailscale DNS/route/grantを復元する。
15. Gatus、Discord、Healthchecks.ioの動作を確認する。
16. 復旧commit SHA、image digest、state backup revision、試験結果を記録する。

## 失敗時の規則

- NFS mountまたはmarkerの失敗: 停止し、Dockerが空のbind sourceを作ることを許可しない。
- 予期しないTerraform destroy/replace: 停止し、state/import対応を調査する。
- IPが応答する、またはARP/DHCP inventoryに現れる: 停止し、そのIPを取得しない。
- 証明書発行の失敗: HTTP backendをprivateのままにし、production ACMEを再試行する前にDNS-01/configを解決する。
- application schema/versionの不一致: 新writerを停止し、直前に固定したimage digestへ戻す。

## 復旧の検証

移行runbookの受入試験一覧をすべて使う。VM boot成功やcontainerがhealthyになっただけでは復旧完了とは
みなさない。applicationのread/write、DNS動作、SMB identity、TLS、通知、fail-closed mountがすべて合格する
必要がある。
