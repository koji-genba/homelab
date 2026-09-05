# 目標アーキテクチャ

- 状態: 承認済みの設計
- 承認日: 2026-08-29
- 根拠: [現状監査](current-state-audit.md)
- 実機基準点: [実機インベントリ（2026-08-30）](live-inventory-2026-08-30.md)
- 移行手順: [KubernetesからComposeへの移行](../migration/k8s-to-compose.md)
- 復旧手順: [Apps VM復旧](../operations/apps-vm-recovery.md)
- 設計判断: [ADR一覧](../adr/README.md)
- ネットワーク仕様: [目標ネットワークゾーン](../network/target-zones.md)

## 目標

Proxmoxがインストール済みで、NFS/ZFS上のデータが復旧済みという状態から、リポジトリと
KeePassXC内の復旧情報（recovery material）を使って全アプリケーション機能を再構築できるようにする。

維持する機能は次のとおり。

- stashPad prod/staging、分離されたmetadata、共有media、staging自動更新、prod明示promotion
- SillyTavernのdata、認証、既存FQDN
- Sambaの3 shareと既存user
- 内部DNS record、広告block、allow/block list、TailscaleグローバルDNS
- LAN/Tailscaleからの既存FQDNとTLS
- service監視、Discord通知、外部dead-man監視

ZFSスナップショット、レプリケーション、NFSサーバー自体の復旧はこのプロジェクトの対象外とする。
ただし、必要なexport、mount、marker、permissionを契約として記録し、mountできない場合は
アプリケーションを起動しない。

## 実行環境の構成

```text
Proxmox pve1 192.168.10.11
├── ZFS/NFS                         今回の移行における復旧対象外
├── apps VM (Debian 13)
│   ├── Caddy                       80/443
│   ├── AdGuard Home                53/tcp, 53/udp
│   ├── Samba                       445/tcp
│   ├── stashPad prod/staging       内部Docker network
│   ├── SillyTavern                 内部Docker network
│   └── Gatus                       内部Docker network
├── Tailscale gateway               維持、管理設定はTerraformで管理
├── ElastiFlow                      維持
└── stashPadDev                     一時VM、対象外

Healthchecks.io                     外部dead-man監視
GitHub/GHCR                         ソース、CI、公開イメージ
```

Apps VMはフェーズ1で暫定管理IP `.10.42` とVLAN 11サービスIP `.11.100/.101/.103`を使い、
VLAN移行後は`.10.101`へ集約する。実値はinventory/preflight確認後に変数へ確定する。

## サービス経路

| FQDN/サービス | 転送先 | 認証 |
| --- | --- | --- |
| `prod.stashpad.kojigenba-srv.com` | Caddy -> stashpad-prod | ネットワーク境界/現行アプリの挙動 |
| `staging.stashpad.kojigenba-srv.com` | Caddy -> stashpad-staging | ネットワーク境界/現行アプリの挙動 |
| `sillytavern.kojigenba-srv.com` | Caddy -> SillyTavern | 既存Basic Auth |
| `dns.kojigenba-srv.com` | Caddy -> AdGuard Home UI | AdGuard内蔵ログイン |
| `status.kojigenba-srv.com` | Caddy -> Gatus | Caddy Basic Auth |
| DNS | Apps VM port 53 | Trusted/Tailscaleからの接続制限 |
| SMB | Apps VM port 445 | 既存Sambaローカルユーザー |

管理UI、SSH、SMB、DNSの到達元はnftablesとIX2215 ACLで制限する。Internetへ公開サービスを
公開しない。CloudflareはDNS-01 challengeだけに利用する。

<a id="storage-contract"></a>

## ストレージ契約

### 現在のアプリケーションデータ

| サービス | NFSサーバーパス |
| --- | --- |
| SillyTavern | `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa` |
| stashPad prod | `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b` |
| stashPad staging | `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b` |
| stashPad media | `/mnt/shared/koji-genba/stashPadLib` |
| Samba shared | `/mnt/shared` |
| Samba shared-hdd | `/mnt/tank-gen2/data/shared` |
| Samba archive | `/mnt/tank-gen1/data/archive` |

最初のcutoverではopaque PVC pathをそのままmountする。安定後、Kubernetes停止中に
`/mnt/tank-gen2/data/apps/{sillytavern,stashpad-prod,stashpad-staging}/`へcopy/検証してから
宣言を切り替える。`mv`は使わず、UID/GID、ACL、xattr、hardlinkを保持する。

### NFS exportメモ

最終exportのclientはApps VM `192.168.10.101/32`だけとし、基本optionは
`rw,sync,no_subtree_check,no_root_squash`とする。`no_root_squash`は初期互換性のためで、
UID/GID検証後に`root_squash`へ狭められるか再評価する。

移行中はKubernetes nodeもwriterであるため、既存exportを直ちに狭めない。Apps VMの暫定IP
`.10.42`からmountできることを確認し、Kubernetes停止後に`.10.42/32`、最終IP移行後に
`.10.101/32`へ変更する。NFS serverの`/etc/exports`はこのrepoから自動反映せず、変更内容と
`exportfs -v`結果をrunbookへ記録する。

VM側はNFSv4、`hard,_netdev`を使用する。systemd mount unit、`RequiresMountsFor=`、
`findmnt`でのfilesystem type確認、dataset固有markerのすべてを通過しなければCompose
プロジェクトを起動しない。

## ライフサイクルと更新

- 全imageをdigestで宣言する。
- Dependabotが週次でCompose、Dockerfile、GitHub Actionsの更新PRを作る。
- stashPad stagingは定期workflowが`edge`の新digestを検出し、staging定義だけを
  mainへcommitして自動反映する。branch protectionで直接pushを禁止する場合はPR方式へ変更する。
- prodは明示的にversion/digestをpromotionしてmainへmergeする。
- CaddyはCloudflare moduleをversion固定してCI buildし、public GHCRのdigestを使う。
- AdGuard Homeの完全な設定は管理者認証hashを含むため、Gitのallow/blockやlocal
  recordを変更したときもAnsibleを明示適用して再生成する。
- WatchtowerとCIからの直接deployは使わない。

## 復旧用アーティファクト

| アーティファクト | 保管場所 |
| --- | --- |
| 望ましい状態と手順 | Git main branch |
| 暗号化Terraform復旧state | Git `state-backup` branch |
| SOPS暗号化secret | Git main branch |
| age復旧鍵 | KeePassXC |
| ProxmoxとTailscaleのcredential | KeePassXC、デプロイ時に注入 |
| アプリケーションデータ | 外部で復旧したNFS/ZFS |
