# 次セッションへの作業指示

- 更新日: 2026-09-05
- 対象リポジトリ: `/home/s-sato/homelab`
- 作業ブランチ: `k8s-decommission`
- 現在地: Phase 1完了。Apps VMはread-only/non-writer。Phase 2のapplication cutoverは未実施

この文書は、会話履歴がない次セッションが安全に作業を再開するための指示書である。
進捗の羅列ではなく、ここに記載した順序、ゲート、停止条件に従うこと。

## 目的とフェーズ境界

- KubernetesをDebian 13の単一Apps VMとDocker Composeへ段階的に置き換え、現在の機能を減らさない。
- Proxmoxインストール済みの状態からGit、Terraform、Ansible、Compose、SOPS/ageで再構築可能にする。
- NFS上の既存dataを最優先で保護し、新旧を同時writerにしない。
- Phase 2では現在のVLAN 11上でapplicationだけを切り替える。VLAN 10/20/30/40への再編は別windowで行う。
- Apps VMの削除・IaC再構築試験に合格した日から14日間は旧Kubernetes VMを保持する。
- `stashPadDev`（VMID 111）は作業用VMであり、この移行の対象外とする。

## セッション開始時に必ず行うこと

1. この文書を最後まで読み、次に以下を確認する。
   - [実装状況](implementation-status.md)
   - [KubernetesからComposeへの移行手順](k8s-to-compose.md)
   - [実機インベントリ](../architecture/live-inventory-2026-08-30.md)
   - [Apps VM復旧手順](../operations/apps-vm-recovery.md)
2. worktreeとbranchを読み取り専用で確認する。protectedなnetwork 2ファイルを触らない。

   ```sh
   git status --short --branch
   git log --oneline --decorate -10
   git diff --check -- . \
     ':(exclude)files/infrastructure/network/README.md' \
     ':(exclude)files/infrastructure/network/config.txt'
   ```

3. 外部状態を変更する前に、現在もKubernetesが唯一のwriterで、Apps VMがnon-writerであることを再確認する。
4. まずは後述の「Phase 2A: 読み取り専用の事前調査」だけを行う。調査結果をユーザーへ提示し、別途明示的な
   cutover許可を得るまでwriter停止、IP移譲、NFS read/write化、service起動へ進まない。

## 絶対に維持する安全条件

- Kubernetesを唯一のwriterとして維持する。Phase 2 cutoverが明示承認されるまで停止・変更しない。
- Apps VMへ`192.168.11.100`、`192.168.11.101`、`192.168.11.103`を付与せず、NFSはread-only、
  Compose containerは0個を維持する。
- 次のAnsible flagは明示承認まで、すべて`false`のままにする。
  - `legacy_service_addresses_enabled`
  - `legacy_service_cutover_confirmed`
  - `application_cutover_confirmed`
  - `network_migration_complete`
- Tailscaleはlive設定の完全なexport、review、importが終わるまで`manage_tailnet=false`を維持する。
- Apps VMのcloud-init warning履歴を消す目的で`cloud-init clean`やreinitを行わない。SSH host keyを変える危険がある。
- Terraform planにVMID 112のreplace、想定外resource、Apps VM以外の変更が出たらapplyしない。
- secret、API token、age秘密鍵、復号済み設定、Terraform stateの実値を会話、ログ、Git、tfvarsへ出力しない。

## 現在のシステム状態

### 本番サービス

- Kubernetes 3 nodeはReadyで、現在も本番サービスを提供している。
- 現行service IPはIngress `.11.100`、Unbound `.11.101`、Samba `.11.103`。
- VLAN 11のDHCP pool `.100-.200`とservice IPが重複している。Phase 2ではDHCP停止または確実な除外が必須。
- Unboundは旧Replica 1つで提供中。新Replicaは不正なTIF RPZでCrashLoopし、blocklist Jobも直近3回失敗している。
- Tailscale `home-gateway`はexit node、IPv4/IPv6 default route、VLAN 10/11 routeを提供している。
  live ACL/DNS/route/deviceはまだAPIからexport・Terraform importしていない。

### Apps VM

- Proxmox `pve1`上のVMID 112。Debian 13、hostname `apps`、4 vCPU、12 GiB RAM、40 GiB disk。
- VLAN 10の`192.168.10.42/24`と、アドレスを持たないVLAN 11 NICを持つ。
- ED25519 host keyはPVE/QEMU guest agent経由とnetwork経由で独立に照合済み。
  fingerprintは`SHA256:crmNjtlEWlIzTu4VKVR6/ArBqsAZV6qUW95uyOvFLUw`。
- 初回Ansibleは`ok=61 changed=29 failed=0`、再実行は`ok=58 changed=0 failed=0`。
- 再起動後はfailed unit 0。7 NFS mountはすべて`nfs4,ro`でmarker一致。
- `homelab-mount-guard.service`はenabled/active。
- Apps、reconcile、Healthchecks、legacy-address unitはdisabled/inactive。running containerは0個。
- service側IPv4は`.10.42`だけで、Docker bridge以外のlegacy service IPはない。

### Terraform、cloud-init、state

- Apps VMとcloud-init snippetはTerraformへ収束済み。
- PVEの`terraform@pve` user、`HomelabTerraform` role、`apps-vm` tokenは作成済み。ACLはVMID 112、
  `local`、`vmpool`、`pve1`、対象SDN networkへ限定し、token期限は2026-12-04 23:59 JST。
- cloud-init snippetは`hostname: apps`、deploy user配下の`lock_passwd: true`、top-level `lock_passwd`なし。
- creation-time snippet更新で既存VMをreplaceしないlifecycle guardを実装済み。
- snippet drift解消時のplanはVMID 112差分なしで、apply後もboot time、MAC、disk、config、host keyを維持した。
- saved planと一時token handoffは削除済み。
- 暗号化state backup branchの確認済み先頭は`39ee06b5028ae318676c736dfb432f73404a95ca`。
- local stateとbackupはmode `0600`。

### NFS/ZFS

- NFS親export 4つと利用path 7つは存在し、markerをKubernetes worker 2台とApps VMから確認済み。
- ZFS poolは全て`ONLINE`。対象pathは`noacl`で、確認時にxattrはなかった。
- `tank-gen2/data/shared`には2026-09-05時点で26 snapshotがある。
- `tank-gen1/data/archive`と`tank-gen2/data/k8s-volumes`にはsnapshotがない。
  cutover時はwriter停止と必要な最終syncの直後、Apps VMをwriterにする前にsnapshotを必ず取得する。

| path | marker内容 |
| --- | --- |
| `/mnt/tank-gen2/data/shared/.homelab-export-shared`（`/mnt/shared`から参照） | `shared` |
| `/mnt/tank-gen2/data/shared/.homelab-export-shared-hdd` | `shared-hdd` |
| `/mnt/tank-gen1/data/archive/.homelab-export` | `archive` |
| `/mnt/shared/koji-genba/stashPadLib/.homelab-export` | `stashpad-media` |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa/.homelab-export` | `sillytavern-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b/.homelab-export` | `stashpad-prod-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b/.homelab-export` | `stashpad-staging-data` |

`shared`と`shared-hdd`は同じ`tank-gen2/data/shared` rootがmergerfs経由と直接export経由で見えるため、
意図的に固有marker名を使っている。共通`.homelab-export`へ戻さない。

## 認証情報と作業環境の復旧

- age identityはKeePassXCに保存済みで、管理端末の配置先は
  `/home/s-sato/.config/sops/age/keys.txt`。public recipientは
  `age1a8v97ung7t9g39vdxsdxgzta4fq4hz7hv7yezzlx6ac7xfgqgsws420x6u`。
- Proxmox API tokenはKeePassXCの`terraform@pve!apps-vm=...` entryに保存済み。値をファイルへ転記せず、
  Terraform作業が必要な時だけ`TF_VAR_proxmox_api_token`へ一時注入する。
- SSH agent socketはセッション固有であり、以前の`/tmp/homelab-migration-agent.sock`が残っていても
  生存確認なしに再利用しない。新しいagentを起動し、ユーザーが保存済み鍵を明示的に追加する。
- `runtime.sops.yaml`は作成済み。次を外部変更前に確認する。

  ```sh
  export AGE_IDENTITY_FILE=/home/s-sato/.config/sops/age/keys.txt
  make secrets-decrypt-check
  make state-backup-preflight
  ```

`state-backup-preflight`には生きたSSH agent/socketとSSH push経路が必要である。資格情報を復旧できない場合は
Terraform/Ansible applyを行わず、読み取り専用調査だけに留める。

## 次に行う作業 — Phase 2A: 読み取り専用の事前調査

このセクションが次セッションの最初の実作業である。設定変更を伴わない方法で現在値を取得し、日時、取得元、
コマンド、結果を記録する。既存文書との差分があれば、cutover前に解消方針をユーザーへ提示する。

1. Gitの基準を確定する。
   - remoteをfetchし、mainの最新cutover候補commitとCI結果を確認する。
   - 7 Compose projectのimageがすべてmanifest digest固定であることを確認する。
   - 未commit差分を確認し、protectedなnetwork 2ファイルをstageしない。
2. 現行writerとservice ownershipをinventoryする。
   - Kubernetes workload、Flux reconciliation、MetalLB address pool/advertisement、Ingress、Unbound、Sambaを記録する。
   - NFS server側でclientとopen writerを確認し、どのworkloadが各pathへ書くか対応表を作る。
   - `.11.100/.11.101/.11.103`の所有者をKubernetes、IX2215のARP/DHCP、同一VLAN上の観測で照合する。
3. networkの事前条件をinventoryする。
   - IX2215のrunning/startup config、VLAN 11 DHCP lease、`.100/.101/.103`の予約・除外可否を記録する。
   - ECW5211の接続port、management IP、SSID/VLAN mappingを記録する。
   - `vmbr0.11`の`192.18.11.11/24`とKubernetes側`192.168.11.0/24`の不整合は記録するが、ここでは修正しない。
4. Tailscaleをexportしてreviewする。
   - live ACL全体、DNS、route、device、tag、exit-node状態を取得する。
   - `home-gateway`のdefault route、VLAN 10/11 route、無tag状態が保持対象であることを確認する。
   - exportとTerraform宣言の差分を提示する。調査段階ではimport/apply、DNS変更を行わない。
5. cutover計画を完成させる。
   - writerごとの停止方法、停止確認、再開方法を表にする。
   - 必要なfinal syncのsource/destination、dry-run、検証方法を決める。最初から`rsync --delete`を使わない。
   - snapshot対象、snapshot名、取得コマンド、存在確認、rollback方法を事前に確定する。
   - DHCP除外、service IP移譲、NFS read/write化、Compose起動、受入試験、rollbackの実行順を確定する。
   - maintenance window、想定停止時間、操作者、OOB access、各段階の中止判断をユーザーと合意する。

Phase 2Aの完了報告には、少なくとも次を含める。

- 不明なwriterが0であること
- 3つのservice IPについて重複・DHCP競合がない切替方法
- snapshot 0件の2 datasetを含むsnapshot計画
- Tailscale live exportとTerraformの差分
- cutoverとrollbackの時系列手順
- 変更対象と、明示的に変更しない対象

ここまで終えても自動的にcutoverへ進まない。結果を提示し、ユーザーからPhase 2Bの明示許可を得る。

## Phase 2B: 明示承認後だけ行うcutover

次の順序は骨格である。Phase 2Aで実機に合わせて具体化し、maintenance window内で一段ずつgateを確認する。

1. cutover対象のmain commit、全image digest、rollback先commit、現在の設定backupを記録する。
2. IX2215で`.11.100/.11.101/.11.103`をDHCP対象外にするかVLAN 11 DHCPを停止する。
3. Flux reconciliationをsuspendする。
4. stashPad prod/staging、SillyTavern、Samba、Unboundを停止する。
5. Pod停止とNFSのopen writer消失を確認する。不明なwriterが1つでもあれば中止する。
6. 必要なfinal syncを実行・検証する。最初から`--delete`を使わない。
7. `archive`と`k8s-volumes`を含む対象ZFS snapshotを取得し、全snapshotの存在を確認する。
8. Ingress/MetalLBから`.11.100/.11.101/.11.103` ownershipを外し、router/client双方でARP消失を確認する。
9. review済み差分で`legacy_service_addresses_enabled=true`、`legacy_service_cutover_confirmed=true`、
   `application_cutover_confirmed=true`へ変更し、`network_migration_complete=false`のままAnsibleを適用する。
10. Caddy、AdGuard Home、Samba、applications、Gatusの順に起動し、
    [受入試験](k8s-to-compose.md#acceptance)を実施する。
11. 全項目合格後はKubernetes VMを停止してよいが、削除しない。再構築試験合格日から14日間保持する。

Tailscale Terraformのimport/applyとVLAN 10/20/30/40への再編は、このapplication cutoverへ混ぜない。
network migrationは別maintenance windowで行う。

## rollbackの最低条件

1. Apps VMの`homelab-apps.service`を停止し、全Compose projectがdownしたことを確認する。
2. Apps VMからservice IPを外し、ARP entry消失を確認する。
3. 新側で発生したwriteを記録し、旧側へ戻すdata/schemaの扱いを決める。
4. MetalLB、Ingress、service、Fluxを復元する。
5. Kubernetes側がwriterへ戻ったことと、現行FQDNから旧serviceが正常なことを確認する。

rollback時も新旧を同時writerにしない。snapshot restoreやreconcileはデータ差分を評価してから行う。

## 直ちに停止する条件

- VMID 112、`.10.42`、`.11.100/.11.101/.11.103`に想定外の所有者がいる。
- Terraform planがApps VM以外を変更する、VMID 112をreplaceする、または説明できない差分を含む。
- state backup preflight、SSH host key、NFS source/fstype/mode/markerのいずれかを検証できない。
- NFSの所有者、ACL/xattr、snapshot、open writerを説明できない。
- DHCPまたはMetalLBがservice IPを所有したまま、Apps VMへ同じIPを付けようとしている。
- imageがdigest固定されていない、または宣言digestと公開manifestが一致しない。
- Tailscale live ACL全体をexport・reviewせずに`manage_tailnet=true`へ変更しようとしている。
- rollback手順、OOB access、maintenance window、ユーザーの明示許可のいずれかがない。

## 作業対象外・worktree保護

- `files/infrastructure/network/README.md`
- `files/infrastructure/network/config.txt`

上記2ファイルには、この移行作業開始前からのユーザー変更がある。明示依頼なしに編集、破棄、整形、stage、commitしない。
選択的にstageし、commit前に`git diff --cached --name-only`で対象を確認する。

次も現時点では行わない。

- Kubernetes VM、PVC、NFS data、ZFS datasetの削除
- IX2215、ECW5211、VLAN、DHCPの変更（承認済みcutover windowを除く）
- `vmbr0.11`の修正・削除
- Tailscale DNS/ACL/routeのapply
- Apps VMの削除・再作成試験
- `stashPadDev`（VMID 111）の変更

コード変更が必要な作業は、ユーザーの希望により可能な限りLunaへ委譲する。ただし、この指示書の最終編集は
primary agentが実施した。設計・運用文書は日本語で記述する。

コードまたは構成を変更した場合は、対象に応じて次の既知のCI相当検証を実行する。失敗を残したまま実機変更へ進まない。

```sh
make ansible-lint ansible-check ansible-bootstrap-paths-test \
  toolbox-uid-test cloud-init-test terraform-apps-vm-lifecycle-test \
  compose-config adguard-config-check shellcheck secrets-scan \
  state-backup-test state-restore-test state-backup-preflight-test \
  tailscale-acl-path-test terraform-fmt terraform-validate \
  terraform-validate-tailscale
```

## 完了済みのGit delivery

- PR #7、#9、#14、#15、#16、#17はmainへmerge済みで、各CIは成功済み。
- toolbox `ghcr.io/koji-genba/homelab-toolbox:1.0.1`は公開済み。
  digestは`sha256:7607f2c74300504e045b2649ce4032920885c1902dd22c01b4c220fc7067dad0`。
- Caddy custom imageを含む7 projectのimageはdigest固定済み。
- Apps VM Terraform apply、Ansible bootstrap、再起動後gate、cloud-init snippet drift解消まで完了済み。

次セッションはPhase 2Aの読み取り専用inventoryから開始する。Phase 2Bへの移行は、調査結果、具体的なrollback、
maintenance windowを提示し、ユーザーから明示的なcutover許可を得た場合に限る。
