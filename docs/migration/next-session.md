# 次セッションへの作業指示

- 作成日: 2026-09-05
- 対象リポジトリ: `/home/s-sato/homelab`
- 現在地: フェーズ1のApps VM apply、Ansible bootstrap、再起動後の受入確認まで完了。Composeのwriter/cutoverは未実施

この文書は、会話履歴がない次セッションでも安全に作業を再開するための引継ぎである。
最初に[実装状況](implementation-status.md)、[実機インベントリ](../architecture/live-inventory-2026-08-30.md)、
[移行手順](k8s-to-compose.md)を読むこと。設計や運用文書は引き続き日本語で記述する。

## ユーザーの目的と確定済み方針

- Kubernetesを、Debian 13の単一Apps VMとDocker Composeへ段階的に置き換える。
- 現在提供しているアプリケーションと機能は減らさない。学習目的でKubernetesは維持しない。
- Proxmoxインストール済みの状態から、Git、Terraform、Ansible、Compose、SOPS/ageで再構築できるようにする。
- NFS上のデータを保護する。ZFS/NFSサーバー自体の復旧は今回の対象外だが、export設定は文書に残す。
- stagingは自動更新、productionは明示的に昇格する。
- 監視はGatus、systemd probe、Discord、Healthchecks.ioのdead-manに限定する。
- 最終ネットワークはVLAN 10 Server、20 Trusted、30 IoT、40 Guest。VLAN 11/63は後で廃止する。
- `stashPadDev`（VMID 111）は作業用VMなので今回の対象外とする。
- Apps VMの削除・IaC再構築試験に合格してから14日間は、旧Kubernetes VMを削除しない。

## 現在の実装

- Apps VM Terraform: VMID 112、4 vCPU、12 GiB RAM、40 GiB disk、暫定`192.168.10.42/24`。
- Apps VMにはVLAN 10の管理NICと、フェーズ2までアドレスを持たないVLAN 11 NICを作る。
- Caddy、AdGuard Home、Samba、stashPad prod/staging、SillyTavern、Gatusを7つのCompose projectとして実装済み。
- NFS source、filesystem type、read-only/read-write、固有markerを検証してから起動する。
- service IP、NFS write、image digest、rollback、Terraform state backupはfail closedにしてある。
- Tailscale Terraformはimport-firstで、既存ACLをexportしない限り管理を有効化できない。
- Tailscale deviceは`home-gateway`。既存exit node、IPv4/IPv6 default route、VLAN 10/11 route、無tag状態を保持する。
- AdGuard HomeはCloudflare DoHをprimary、Quad9 DoHをfallbackとし、現行相当のHaGeZi 6 feedを使う。
- 7 projectすべてのimageはdigest固定済み。Caddy custom imageもGHCRへ公開済みである。

## 2026-09-05のフェーズ1実機反映

- TerraformでVMID `112`をapply済み。実機は4 vCPU、12 GiB RAM、40 GiB disk、VLAN 10の`.10.42/24`、
  アドレスを持たないVLAN 11 NICである。Terraform state backup branchのremote先頭は
  `a209ba9f9b3cddf57de48deb9b9f9168fbd21188`。
- PVE roleには`Sys.AccessNetwork`と、`vmbr0/10`および`vmbr0/11`のSDN child ACLを追加してapplyを通した。
  他の権限を広げない。PVE上のvCPU、memory、disk、bridge、VLAN設定を再確認済み。
- VMのED25519 host keyは、信頼済みPVE access経由のQEMU guest agentから取得したfingerprintと、network上の
  `ssh-keyscan`で独立に観測したfingerprint `SHA256:crmNjtlEWlIzTu4VKVR6/ArBqsAZV6qUW95uyOvFLUw`を照合し、
  一致後に`known_hosts`へ追加した。未検証のkeyscan結果を信頼してはならない。
- 初回Ansibleは`ok=61 changed=29 failed=0`、再実行は`ok=58 changed=0 failed=0`で完了した。
  Ansibleは`apps` hostname、Docker/NFS/firewall/systemd設定を収束させた。
- 再起動後、hostnameは`apps`、systemd failed unitは0。7つのNFS mountはすべて`nfs4` read-onlyで、
  marker内容が一致し、mount guardはenabled/activeである。`homelab-apps`、reconcile、Healthchecks、
  legacy-address unitはdisabled/inactive、containerは0個で、IPv4は`.10.42`とDocker bridgeだけである。
- cloud-init snippet driftは、PR #16（main commit `1171e5cbc178a9db3920ed55fa5c5058daec71f7`、validation run
  `33952996065`）のlifecycle guardによりVM replacementなしで解消した。saved plan hashは
  `217241ca872aaec0de7d40bd9ce45fca070369e9d3c0f5a241ea87e64d98cc47`で、machine checkは
  `proxmox_virtual_environment_file.cloud_config`の`[delete,create]`だけ（1 add/0 change/1 destroy、VM 112差分なし）
  だった。apply後にplanは削除し、state-backup remote先頭は`39ee06b5028ae318676c736dfb432f73404a95ca`になった。
- live PVE snippetのschemaは`hostname: apps`、deploy userの`lock_passwd: true`、top-level `lock_passwd`なしを確認した。
  VMは同じboot time `16:15:42`のまま稼働し、MAC/disk/config、SSH trusted keyを維持した。cloud-init clean/reinitは実行していない。
- Kubernetesを唯一のwriterとして維持しており、legacy service IP、NFS write、Tailscale、VLAN、network
  cutoverは変更していない。Phase 2は別maintenance windowの対象で、archiveと`k8s-volumes`のsnapshotを
  取得してから開始する。

## 実機で確認済みの重要事項

- Proxmoxへは`ssh root@192.168.10.11`で接続できる。node名は`pve1`、PVEは9.2.3。
- `vmbr0`は`nic0`接続のVLAN-aware bridgeで、`vmpool`には約582 GiBの空きがある。
- VMID 112はTerraformで作成済み。`.10.42`はVLAN 10のDHCP pool（`.100-.200`）外で、現在このApps VMが使用する。
- `vmbr0.11`には`192.18.11.11/24`が設定されている。Kubernetes側のVLAN 11は
  `192.168.11.0/24`であり不整合だが、VLAN 11は廃止予定なので現時点では変更しない。
- 現行VIPはIngress `.11.100`、Unbound `.11.101`、Samba `.11.103`。VLAN 11のDHCP
  `.100-.200`と重複しているため、フェーズ2でDHCP停止または除外が必須である。
- NFSの4親exportとApps VMが使う7 pathは存在し、marker 7つを2026-09-05に作成済み。
  Kubernetes worker 2台からNFS越しに全markerの内容を検証済み。
- PVEには`terraform@pve`、`HomelabTerraform` role、`apps-vm` API tokenを作成済み。ACLは
  VMID 112、`local`、`vmpool`、`pve1`、local networkに限定し、token期限は2026-12-04 23:59 JST。
- 管理端末の`id_ed25519.pub`をPVE登録鍵とfingerprint照合済み。SSH agent経由で接続でき、Gitは
  fetchをHTTPS、pushをSSHに設定済み。agent socketはsession固有なので再開時に起動し直す。
- age identity/recipientとProxmox tokenはKeePassXCへ保存済み。実値の`runtime.sops.yaml`を作成し、
  SOPS復号と`state-backup-preflight`に成功済み。
- Discord webhookとHealthchecks.io `homelab-apps` check/Discord integrationは作成済み。実通知は未検証。
- Kubernetes 3 nodeはReady。現行アプリFQDNは稼働している。
- Unboundは旧Replica 1つで提供中。新Replicaは不正なTIF RPZでCrashLoopし、blocklist Jobも直近3回失敗している。
- Tailscaleのlive ACL/DNS設定はAPIから未export・未import。ユーザー申告ではUnboundをglobal DNSとして使っている。

## ワークツリーに関する注意

- 移行実装はPR #7、Caddy digest固定はPR #9でmainへmerge済み。Terraform applyとAnsible applyは完了し、
  Tailscale import/applyとapplication cutoverは未実施。
- 今回の初回接続で、toolboxの任意UIDに対するOpenSSH passwd lookup、Debian 13の不足drop-in directory、
  cloud-initのtop-level `lock_passwd` schema、localhost hostname、Debian 13で削除された`apt_repository`/
  `apt-key`を検出して修正した。現在のVMはAnsibleでhostnameを収束済みであり、cloud-init clean/reinitは
  host keyを壊すため実行しない。
- PR #14はmain commit `aba90039b121387f647efb96732087eb73a84ffb`としてmerge済み。main validation run
  `33952336848`とtoolbox publish run `33952336833`が成功し、GHCRの
  `ghcr.io/koji-genba/homelab-toolbox:1.0.1`はdigest
  `sha256:7607f2c74300504e045b2649ce4032920885c1902dd22c01b4c220fc7067dad0`で公開済み。
- cloud-init templateの`lock_passwd`/hostname修正は、PR #16のlifecycle guardを含むsaved planで反映済みである。
  初回VMに残っていたcloud-init warningの履歴を消すためのclean/reinitは行っていない。
- `files/infrastructure/network/README.md`と`files/infrastructure/network/config.txt`には、作業開始前からの
  ユーザー変更がある。明示的な依頼なしに編集、破棄、整形、stage、commitしない。
- Proxmoxには上記の認証設定、VMID 112、NFS marker 7つを追加した。既存Kubernetes、NFS export、NFS既存data、
  IX2215、ECW5211、Tailscaleには変更を加えていない。Discord/Healthchecks.ioは通知先とcheckだけを作成した。
- commitやpushはユーザーの許可を得てから行い、上記network 2ファイルを選択的stageから除外する。

## 次に行う作業

### 1. 差分と検証結果を再確認する

```sh
git status --short
git diff --check -- . \
  ':(exclude)files/infrastructure/network/README.md' \
  ':(exclude)files/infrastructure/network/config.txt'
make ansible-lint ansible-check compose-config adguard-config-check \
  shellcheck secrets-scan state-backup-test state-restore-test \
  state-backup-preflight-test tailscale-acl-path-test \
  terraform-fmt terraform-validate terraform-validate-tailscale
```

前回は全項目成功している。失敗した場合は実機作業へ進まず、差分または実行環境を直す。

### 2. Caddy imageを公開してdigest固定する（完了）

2026-09-05にPR #7をmainへmergeし、`.github/workflows/caddy-image.yml`で
`ghcr.io/koji-genba/caddy-cloudflare:2.11.4`をbuild/pushした。workflow成功後にmanifest digestを確認した。

```sh
docker buildx imagetools inspect ghcr.io/koji-genba/caddy-cloudflare:2.11.4
```

確認したdigestは`sha256:e2a92e76f07428763c253e005c016b3da0515f025a30762b2f68e9ea26a21d59`である。
`files/services/compose/edge/compose.yaml`のimageへ反映し、再検証済み。今後tagのままへ戻してはならない。

### 3. 認証・state復旧経路を準備する（完了）

ここからは外部状態を変更するので、作業前にユーザーへ確認する。

1. ProxmoxにTerraform用の最小権限user/role/API tokenを作る。
2. token値は画面やGitへ残さず、生成直後にユーザーがKeePassXCへ保存する。
3. 使用するSSH公開鍵を確定し、管理端末でSSH agentを起動して鍵を追加する。
4. `origin`のpush URLをSSHへ変更する。fetch URLをHTTPSのまま残す構成でもよい。
5. age identity/recipientをKeePassXCへ保存し、`runtime.yaml.example`から実値を作ってSOPS暗号化する。
6. `make state-backup-preflight`が成功するまでTerraform applyを行わない。

2026-09-05に上記を完了した。PVE 9.2.3には`VM.Monitor` privilegeが存在しないためroleへ含めず、
PVE上で利用可能なprivilegeだけを設定した。既存のGit非追跡Terraform state 7ファイルはmode `0644`から
`0600`へ修正した。SSH agentとtoken/identityの環境変数はshell sessionを越えて永続化しない。

API token、age秘密鍵、復号済みsecret、Tailscale credentialを会話、ログ、Terraform変数ファイル、
Gitへ出力しない。

### 4. NFS markerを作る（完了）

marker作成はデータ領域への書き込みなので、ユーザーの許可を得てから行う。事前に対象path、snapshot、
数値UID/GIDを再確認する。各markerの内容は次の値と完全一致させる。

| path | marker内容 |
| --- | --- |
| `/mnt/tank-gen2/data/shared/.homelab-export-shared`（`/mnt/shared`から参照） | `shared` |
| `/mnt/tank-gen2/data/shared/.homelab-export-shared-hdd` | `shared-hdd` |
| `/mnt/tank-gen1/data/archive/.homelab-export` | `archive` |
| `/mnt/shared/koji-genba/stashPadLib/.homelab-export` | `stashpad-media` |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa/.homelab-export` | `sillytavern-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b/.homelab-export` | `stashpad-prod-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b/.homelab-export` | `stashpad-staging-data` |

2026-09-05に実施した。事前確認では全poolが`ONLINE`、4親exportとoption、7 pathの数値UID/GIDと
modeは前回記録と一致し、ZFSは`noacl`、対象pathのxattrはなかった。現行NFS clientは
`k8s-worker01`と`k8s-worker02`であり、Kubernetesを唯一のwriterとして維持している。

当初の共通`.homelab-export`名では、mergerfs `/mnt/shared`と直接HDD exportが同じ
`tank-gen2/data/shared` rootを見せるため期待値が衝突することを検出した。Ansibleと契約を修正し、
`shared`と`shared-hdd`だけ固有marker名へ分離した。7 markerは`root:root`、`0644`で作成し、
Kubernetes workerからNFS越しに内容一致を確認した。

`tank-gen2/data/shared`には26 snapshotがあり、最新は`daily-2026-09-05`である。
`tank-gen1/data/archive`と`tank-gen2/data/k8s-volumes`にはsnapshotと自動snapshot設定がない。
フェーズ2のwriter停止後、切替前に両datasetを含む対象snapshotを必ず取得する。

export範囲の最終的な`/32`化はフェーズ2以降に行う。フェーズ1ではApps VM側をread-only mountにし、
Kubernetesを唯一のwriterとして維持する。

### 5. Apps VMのTerraform plan/apply（完了）

資格情報を環境変数へ一時的に設定し、保存planを作る。値をshell historyへ直接書かない。初回apply後の
cloud-init template修正は、VM replacementを防ぐlifecycle guardを先に実装してからsaved planで反映した。

```sh
make state-backup-preflight
make terraform-plan
```

cloud-init snippet修正以外にVMID 112のApps VM差分がないことを確認した。machine checkではsnippet fileの
delete/createだけが検出され、VM replacement差分がないことを確認してからapplyした。

2026-09-05にVMID 112のplanをreviewしてapplyした。PVE role ACLの不足は`Sys.AccessNetwork`と対象
SDN child ACLだけを追加して解消し、VMの構成を再確認した。snippet drift反映後のstate-backup remote先頭は
`39ee06b5028ae318676c736dfb432f73404a95ca`である。

Terraform codeへ後から入ったcloud-init template修正は、現在のVMへclean/reinitせず、snippet fileだけを
安全に置き換えて反映済みである。初回VMのcloud-init warningの履歴を消去したことを意味しない。

### 6. フェーズ1を適用する（完了）

明示的な許可後に保存planを`make terraform-apply`で適用し、Proxmox console/QEMU guest agentとOOBで
Apps VMのSSH host key fingerprintを確認してから`known_hosts`へ登録し、Ansibleを適用した。Ansible、
snippet drift反映、再起動後の確認は完了済みである。

フェーズ1では次のflagをすべて`false`のままにする。

- `legacy_service_addresses_enabled`
- `legacy_service_cutover_confirmed`
- `application_cutover_confirmed`
- `network_migration_complete`

NFSはread-onlyで検証し、`.11.100/.101/.103`を取得しない。既存dataを使うstateful containerを
writerとして起動しない。旧Kubernetesへ変更を加えない。

## 直ちに停止する条件

- `.10.42`またはVMID 112の新しい所有者が見つかった。
- Terraform planがApps VM以外を変更する。
- state backup preflight、SSH host key確認、NFS source/type/mode/marker検証のいずれかが失敗する。
- Caddyを含む全imageがdigest固定されていない状態でapplication cutoverへ進もうとしている。
- NFS dataの所有者、ACL、xattr、snapshot、writerの状態が説明できない。
- Tailscaleのlive ACL全体をexport・reviewせずに`manage_tailnet=true`を設定しようとしている。
- DHCPまたはMetalLBがservice IPを所有したままApps VMへ同じIPを付与しようとしている。

## 今回まだ行わないこと

- Kubernetes workload、Flux、MetalLB、Unboundの停止・修正
- Apps VMへのlegacy service IP付与またはNFS read/write化
- Tailscale DNS/ACL/routeのapply
- IX2215、ECW5211、VLAN、DHCPの変更
- `vmbr0.11`の修正または削除
- Kubernetes VM、PVC、NFSデータ、ZFS datasetの削除

フェーズ1の適用後は[移行手順](k8s-to-compose.md)のgateに戻り、フェーズ2以降を別maintenance windowで
進めること。
