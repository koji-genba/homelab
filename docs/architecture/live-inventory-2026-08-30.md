# 実機インベントリ（2026-08-30）

- 観測日: 2026-08-30
- 対象: `pve1`、現行Kubernetesクラスタ、NFS/ZFS、DNS/ネットワーク
- 方法: ProxmoxホストへのSSHおよびKubernetes APIからの読み取り専用確認
- 変更: 実機設定の変更なし

この文書は、移行設計に使う実測値を日付付きで固定する。目標構成や移行手順の代わりではなく、
次回の差分確認に使う基準点である。値が変わった場合は、まずこの文書を更新してからTerraformや
Ansibleの変数を変更する。

## Proxmoxホスト

| 項目 | 実測値 |
| --- | --- |
| ホスト | `pve1` (`192.168.10.11`) |
| Proxmox VE | `9.2.3` |
| カーネル | `7.0.6-2-pve` |
| クラスタ | 単一node（`pve1`のみ） |
| CPU | AMD Ryzen 9 5900X、12コア/24スレッド |
| メモリ | 125 GiB、available約30 GiB |
| `local` | 空き約64 GiB |
| `local-lvm` | 空き約794 GiB |
| `vmpool` | 空き約582 GiB |
| Apps VM用VMID | `112`は未使用 |

### VM一覧

| VMID | 名称 | 用途/状態 | vCPU | RAM | アドレス |
| ---: | --- | --- | ---: | ---: | --- |
| 101 | `k8s-master01` | Kubernetes control-plane、稼働中 | 2 | 8 GiB | `192.168.10.21` |
| 102 | `k8s-worker01` | Kubernetes worker、稼働中 | 4 | 16 GiB | `192.168.10.22` |
| 103 | `k8s-worker02` | Kubernetes worker、稼働中 | 4 | 16 GiB | `192.168.10.23` |
| 105 | `tailscale-gateway` | Tailscale gateway、稼働中 | 2 | 4 GiB | `192.168.10.30` |
| 110 | `elastiflow` | ElastiFlow、稼働中 | 4 | 32 GiB | `192.168.10.40` |
| 111 | `stashPadDev` | 開発用、今回の移行対象外、稼働中 | 8 | 16 GiB | `192.168.10.41` |
| 9000 | `ubuntu-2404-cloudinit` | Ubuntu template、停止中 | 2 | 2 GiB | なし |

`192.168.10.42`にはVM定義がなく、pingにも応答しなかった。現在のDHCPプール
`.100-.200`の範囲外なので、フェーズ1の暫定Apps VMアドレス候補としての重複は観測されていない。
Terraform適用前にARP、DHCP lease、Proxmox inventoryを再確認する。

### Proxmoxネットワーク

`vmbr0`は`nic0`をbridge portとし、VLAN-awareでVLAN `2-4094`を許可している。
Proxmoxホストには次のVLAN interfaceがある。

| interface | 実測アドレス | 備考 |
| --- | --- | --- |
| `vmbr0.10` | `192.168.10.11/24` | 現行管理ネットワーク、gateway `192.168.10.1` |
| `vmbr0.11` | `192.18.11.11/24` | 想定の`192.168.11.0/24`と異なるため要確認 |

`vmbr0.11`の`192.18.11.11/24`は記載ミスまたは実機設定の不整合である可能性がある。
Kubernetes VM側は`192.168.11.21`〜`192.168.11.23`を使用しているため、移行前に原因と正しい
サブネットを確認する。ユーザー管理の`files/infrastructure/network/README.md`と`config.txt`は
この確認結果によって自動修正しない。

## Kubernetesクラスタ

クラスタはKubernetes `v1.36.1`の3 nodeで、全nodeが`Ready`だった。

| node | 役割 | 内部IP | 状態 |
| --- | --- | --- | --- |
| `k8s-master01` | control-plane | `192.168.10.21` | Ready |
| `k8s-worker01` | worker | `192.168.10.22` | Ready |
| `k8s-worker02` | worker | `192.168.10.23` | Ready |

現行LoadBalancerは次のアドレスを使用している。

| サービス | 外部IP | 用途 |
| --- | --- | --- |
| ingress-nginx | `192.168.11.100` | HTTP/HTTPS ingress |
| `external-unbound-dns` | `192.168.11.101` | DNS（TCP/UDP 53） |
| `samba-smb` | `192.168.11.103` | SMB（TCP 445） |

この3つはフェーズ2で旧writerを停止し、ARP消失とDHCP除外を確認してからApps VMへ引き継ぐ。

## NFS/ZFS

実測した親exportは次の4つで、client範囲は`192.168.10.0/24`、optionは
`rw,sync,no_subtree_check,no_root_squash`だった。

| 親export | client | 主要option（実測） | 固有option |
| --- | --- | --- | --- |
| `/mnt/tank-gen2/data/k8s-volumes` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen1/data/archive` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen2/data/shared` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=101` |
| `/mnt/shared` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=100` |

Apps VMが利用する7 pathはすべて存在した。各pathの`.homelab-export` markerはまだ作成されて
いないため、現在はCompose起動用のmarker契約を満たしていない。

| 利用path | 用途 | 所有者・mode（実測） |
| --- | --- | --- |
| `/mnt/shared` | Samba `shared` | `root:root`, `0755` |
| `/mnt/tank-gen2/data/shared` | Samba `shared-hdd` | `10002:10002`, `0755` |
| `/mnt/tank-gen1/data/archive` | Samba `archive` | `root:root`, `0755` |
| `/mnt/shared/koji-genba/stashPadLib` | stashPad media | `10002:10002`, `0755` |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa` | SillyTavern data | `root:root`, `0777` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b` | stashPad prod metadata | `root:root`, `0777` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b` | stashPad staging metadata | `root:root`, `0777` |

PVCの実使用量はSillyTavern 148 MiB、stashPad prod 56 MiB、staging 57 MiBだった。
stashPad mediaは`du`が25秒でtimeoutしたため、使用量を確定していない。

各ZFS poolは`ONLINE`だった。NFS server/ZFS自体の復旧はこのリポジトリの対象外である。

## DNS、DHCP、TLS

- VLAN 10とVLAN 11のDHCP poolはいずれも`.100-.200`で、MetalLBのVIPおよび最終Apps VMアドレス候補と重複する。
- `prod.stashpad.kojigenba-srv.com`と`staging.stashpad.kojigenba-srv.com`はHTTP確認で`200`だった。
- `sillytavern.kojigenba-srv.com`は`401`を返したが、Basic Auth前提の正常な応答である。
- 正式証明書の有効期限は確認対象により2026-10-02または2026-10-03までだった。
- 短縮aliasの`prod.kojigenba-srv.com`と`staging.kojigenba-srv.com`はIngressにTLS SANがなく、curlでは自己署名証明書エラーになった。
- Unboundは旧Replica 1つが稼働中。新Replicaは不正な`hagezi-tif` RPZによりCrashLoopしている。
- blocklist更新Jobは直近3回が失敗している。
- 現行DNSの手動recordは10件で、AdGuard Home templateに保持済みである。

Kubernetes上にはOpenLDAP、phpLDAPadmin、LDAPSのworkload/serviceは存在しなかった。`192.168.11.102`
はKubernetes masterのARPが`FAILED`で、pingにも応答しなかった。

### Tailscale

- Tailnet hostnameは`home-gateway`（PVE上のVM名は`tailscale-gateway`）。
- Tailscaleは`1.98.3`。自動update checkは有効だが、applyは手動である。
- IPv4 forwardingは有効で、AdvertiseRoutesは`0.0.0.0/0`、`::/0`、`192.168.10.0/24`、
  `192.168.11.0/24`だった。
- exit nodeは現行機能のため、移行後もTerraformで保持する方針とする。

個人ID、メールアドレス、peer情報、NodeIDはこの文書に記録しない。

## 管理プレーンと認証

PVEには`root@pam`だけが存在し、ACLはなく、Terraform用API user/tokenも未作成だった。
したがって、Proxmox Terraform rootの初回apply前に最小権限のAPI user/tokenを手動作成し、
権限と有効期限をレビューする必要がある。Tailscaleのlive ACL/DNS/route/device exportも
別途取得してからimportする。

## 次の確認事項

1. `vmbr0.11`の`192.18.11.11/24`が必要なアドレスか確認し、不要なら削除し、必要なら
   `192.168.11.11/24`へ訂正する判断をProxmoxとKubernetes VMの両側で行う。
2. VLAN 10/11のDHCP lease、ARP、MetalLB所有者を切替直前に再確認する。
3. 7利用pathへ一意なmarkerをNFS server側で作成し、所有者・ACL・xattr・snapshotを記録する。
4. Proxmox API user/token、SSH公開鍵、Tailscale live exportを管理端末へ安全に保存する。
5. blocklist Jobと新Unbound Replicaは、AdGuard Home移行前に廃止または原因を記録する。
