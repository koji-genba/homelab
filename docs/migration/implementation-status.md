# 実装状況

- 状態: フェーズ0/1の基盤はローカル実装完了、フェーズ0の実機インベントリ確認済み、実機未適用
- 更新日: 2026-09-05
- 手順書: [KubernetesからComposeへの移行](k8s-to-compose.md)

この文書は設計、ローカル実装、実機反映を区別する。現在も旧Kubernetesが本番サービスを
提供しており、Apps VM、Tailscale、IX2215、ECW5211、Healthchecks.ioに変更は反映していない。

## Gitに実装済み

- Debian 13 Apps VMのTerraform root、固定cloud image/checksum、VMID 112、暫定`.10.42`、
  address-less VLAN 11 NIC
- Docker、NFS read-only bootstrap、marker guard、nftables、IPv6無効化、secret転送、
  systemd lifecycleのAnsible roles
- Ansibleのpre-task cutover flag fail-closed検証、既存Compose writer停止後のNFS read-only
  remount、NFS source/fstype/ro-rw検証、Compose reverse-order shutdown、Docker再起動時の
  `PartOf`復旧連携
- Caddy、AdGuard Home、Samba、stashPad prod/staging、SillyTavern、Gatusの7 Compose projects
- legacy service IPのwriter-fencing/ARP gate、cutover時のimage digest gate、手動rollback
- stagingだけのimage digest自動更新、prodの明示promotion、Dependabot、CI validation
- SOPS/ageのruntime secret境界と、`state-backup` branchへの暗号化Terraform state recovery copy、
  fresh cloneからのfail-closedなstate restore
- Tailscale Terraform rootの手動・import-first・global DNS only gate。live ACL exportがなければ
  `manage_tailnet=true`を拒否する
- NFS exportの実path、client scope、option、一意markerを記録した手動反映契約
- 2026-08-30に取得した実機インベントリ（[詳細](../architecture/live-inventory-2026-08-30.md)）

## ローカル検証済み

- Apps VM Terraform (`bpg/proxmox 0.111.1`) とTailscale Terraform (`tailscale 0.29.2`)の
  `fmt`, `init`, `validate`
- Ansible lint `production` profileとplaybook syntax check（warning 0）
- 7 Compose projectsの`docker compose config`
- ShellCheck、平文secret/state scan、state-backup/restore fixture（既存state、不正JSON、不正pathの拒否を含む）
- 公式AdGuard Home v0.107.79 binary/checksumによるschema 34 config check
- digest固定の公式Caddy 2.11.4からCloudflare module入りimageをbuildし、Caddyfileを実バイナリで検証
- Gatus v5.36.0実コンテナで設定と10 endpointを読み込み、DNS probeの送信先解釈を検証
- Samba設定を`testparm` で検証

これらはローカルの構文・fixture検証であり、実データのread/writeやFQDN、TLS、Discord通知を
検証したことを意味しない。

## 実機で確認済み

- Proxmox `pve1` 9.2.3、kernel `7.0.6-2-pve`、単一node、Ryzen 9 5900X 12コア/24スレッド、
  RAM 125 GiB（available約30 GiB）
- `local`空き約64 GiB、`local-lvm`空き約794 GiB、`vmpool`空き約582 GiB、VMID `112`は未使用
- VM 101/102/103はそれぞれ`192.168.10.21/.22/.23`、VM 105は`.30`、110は`.40`、111は`.41`、
  9000はUbuntu template。`.10.42`はVM定義がなくping無応答
- `vmbr0`は`nic0`接続、VLAN-aware `2-4094`。`vmbr0.11`の`192.18.11.11/24`とKubernetes側
  `192.168.11.21-.23`の不一致は要確認
- NFS親export 4つ、利用path 7つは存在、marker 7つは未作成、ZFS poolはすべて`ONLINE`
  （PVC実使用量はSillyTavern 148 MiB、stashPad prod 56 MiB、staging 57 MiB。mediaは`du` timeoutで未計測）
- Kubernetes `v1.36.1`の3 nodeはすべて`Ready`。LoadBalancerはingress `.11.100`、Unbound `.11.101`、
  Samba `.11.103`
- 正式stashPad FQDNは`200`かつ証明書正常、SillyTavernは想定どおり`401`。短縮aliasは自己署名で、
  `prod.kojigenba-srv.com`/`staging.kojigenba-srv.com`はIngress TLS SAN不足による自己署名証明書エラー
- Unbound旧Replicaは稼働中だが新Replicaは不正な`hagezi-tif` RPZでCrashLoop、blocklist Jobは直近3回失敗。
  手動DNS record 10件はAdGuard templateへ保持済み。OpenLDAP/phpLDAPadmin/LDAPS workload/serviceはなし
- Tailscale `home-gateway`（VM名`tailscale-gateway`）はversion `1.98.3`、IPv4 forwarding有効、
  routeは`0.0.0.0/0`、`::/0`、`192.168.10.0/24`、`192.168.11.0/24`。exit nodeは現行機能として保持する
- PVEは`root@pam`のみ、ACLなし、Terraform API user/tokenなし

## 初回apply前に必要な作業

- `vmbr0.11`のサブネット不一致の原因と、VMID 112、`.10.42`、NIC名、bridge/VLAN tag、storage IDを確定する
- IX2215のDHCP leaseとARP、旧`.11.100/.101/.103`所有者、ECW5211のport/SSID mappingを記録する
- NFS server側でexportと7つのmarkerを作成し、path、UID/GID、ACL/xattr、snapshotを確認する
- age identity/recipientをKeePassXCに格納し、`runtime.sops.yaml`を実値で暗号化する
- 初回apply前に`AGE_RECIPIENT`、age identity、SSH agent/socket、SSH pushurl、state追跡状態を
  `make state-backup-preflight`で検証する
- Proxmox API tokenとSSH公開鍵を管理端末から渡し、Terraform planをレビューする
- 7 projectすべてのimageを実機または公開manifestから`repo@sha256:<digest>`へ固定済み。
  Caddy custom imageは2026-09-05にGitHub ActionsでGHCRへ公開し、manifest digestを
  `edge/compose.yaml`へ固定した
- Tailscaleのlive ACL/DNS/route/deviceをexportし、Terraform import先と完全なpolicy差分を確認する
- Healthchecks.io check/Discord integrationとDiscord webhookを手動作成する

## 後続のゲート

フェーズ2で旧writerを停止した後にだけlegacy IPとread/write mountを有効化する。application flagを
falseへ戻す場合は、Ansible pre-taskが既存`homelab-apps.service`の停止とExecStop成功を確認し、
その後にNFSをread-onlyへremountする。受入試験後も
Kubernetes VMはすぐ削除せず、Apps VMをTerraform/Ansible/Gitから実際に削除・再構築する。
その試験に合格した日から14日間の安定稼働を確認してからKubernetesを廃止する。

VLAN 10/20/30/40への再編は別maintenance windowで実施する。現時点では期待状態と手順の
みがGit管理され、実機config、port inventory、Apps VMの最終`.10.101`への移行差分は
まだ確定していない。
