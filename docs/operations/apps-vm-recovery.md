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
