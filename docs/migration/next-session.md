# 次セッションへの作業指示

- 作成日: 2026-09-05
- 対象リポジトリ: `/home/s-sato/homelab`
- 現在地: フェーズ0の実機確認とフェーズ1基盤のローカル実装が完了。実機への適用は未実施

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

## 実機で確認済みの重要事項

- Proxmoxへは`ssh root@192.168.10.11`で接続できる。node名は`pve1`、PVEは9.2.3。
- `vmbr0`は`nic0`接続のVLAN-aware bridgeで、`vmpool`には約582 GiBの空きがある。
- VMID 112は空き。`.10.42`はVM定義になく、2026-08-30時点でping応答もなかった。
- VLAN 10のDHCP poolは`.100-.200`なので`.10.42`は範囲外だが、適用直前に再確認する。
- `vmbr0.11`には`192.18.11.11/24`が設定されている。Kubernetes側のVLAN 11は
  `192.168.11.0/24`であり不整合だが、VLAN 11は廃止予定なので現時点では変更しない。
- 現行VIPはIngress `.11.100`、Unbound `.11.101`、Samba `.11.103`。VLAN 11のDHCP
  `.100-.200`と重複しているため、フェーズ2でDHCP停止または除外が必須である。
- NFSの4親exportとApps VMが使う7 pathは存在するが、`.homelab-export` markerは未作成。
- PVEには`root@pam`しかなく、Terraform用API user/tokenは未作成。ACLも未設定。
- 管理端末ではSSH agentが未起動で、Gitのpush URLはHTTPSのまま。
- Kubernetes 3 nodeはReady。現行アプリFQDNは稼働している。
- Unboundは旧Replica 1つで提供中。新Replicaは不正なTIF RPZでCrashLoopし、blocklist Jobも直近3回失敗している。
- Tailscaleのlive ACL/DNS設定はAPIから未export・未import。ユーザー申告ではUnboundをglobal DNSとして使っている。

## ワークツリーに関する注意

- この移行実装は未commit・未pushである。実機へのTerraform apply、Ansible apply、Tailscale import/applyも未実施。
- `files/infrastructure/network/README.md`と`files/infrastructure/network/config.txt`には、作業開始前からの
  ユーザー変更がある。明示的な依頼なしに編集、破棄、整形、stage、commitしない。
- 既存Kubernetes、Proxmox、NFS、IX2215、ECW5211、Tailscale、Healthchecks.ioには変更を加えていない。
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

### 3. 認証・state復旧経路を準備する

ここからは外部状態を変更するので、作業前にユーザーへ確認する。

1. ProxmoxにTerraform用の最小権限user/role/API tokenを作る。
2. token値は画面やGitへ残さず、生成直後にユーザーがKeePassXCへ保存する。
3. 使用するSSH公開鍵を確定し、管理端末でSSH agentを起動して鍵を追加する。
4. `origin`のpush URLをSSHへ変更する。fetch URLをHTTPSのまま残す構成でもよい。
5. age identity/recipientをKeePassXCへ保存し、`runtime.yaml.example`から実値を作ってSOPS暗号化する。
6. `make state-backup-preflight`が成功するまでTerraform applyを行わない。

API token、age秘密鍵、復号済みsecret、Tailscale credentialを会話、ログ、Terraform変数ファイル、
Gitへ出力しない。

### 4. NFS markerを作る

marker作成はデータ領域への書き込みなので、ユーザーの許可を得てから行う。事前に対象path、snapshot、
数値UID/GIDを再確認する。各`.homelab-export`の内容は次の値と完全一致させる。

| path | marker内容 |
| --- | --- |
| `/mnt/shared/.homelab-export` | `shared` |
| `/mnt/tank-gen2/data/shared/.homelab-export` | `shared-hdd` |
| `/mnt/tank-gen1/data/archive/.homelab-export` | `archive` |
| `/mnt/shared/koji-genba/stashPadLib/.homelab-export` | `stashpad-media` |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa/.homelab-export` | `sillytavern-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b/.homelab-export` | `stashpad-prod-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b/.homelab-export` | `stashpad-staging-data` |

export範囲の最終的な`/32`化はフェーズ2以降に行う。フェーズ1ではApps VM側をread-only mountにし、
Kubernetesを唯一のwriterとして維持する。

### 5. Apps VMのTerraform planを作る

資格情報を環境変数へ一時的に設定し、保存planを作る。値をshell historyへ直接書かない。

```sh
make state-backup-preflight
make terraform-plan
```

planでは、Debian image download、cloud-init snippet、VMID 112のApps VM以外が変更されないことを
確認する。VMID、`.10.42`、bridge、VLAN tag、storageに差分があれば停止する。`terraform-apply`は
ユーザーがplanを確認して明示的に許可するまで実行しない。

### 6. フェーズ1を適用する

明示的な許可後にだけ、保存planを`make terraform-apply`で適用する。その後、Proxmox consoleで
Apps VMのSSH host key fingerprintを確認してから`known_hosts`へ登録し、Ansibleを適用する。

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
