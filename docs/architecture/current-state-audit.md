# 移行を支える現状監査

- 観測期間: 2026-08-13〜2026-08-30
- 目的: 目標状態の判断に用いた根拠を保存する
- 最新実測: [実機インベントリ（2026-08-30）](live-inventory-2026-08-30.md)
- 注意: 実機設定の変更は行っていない。切替直前にIP、ARP、DHCP、exportを再確認すること

## 物理障害ドメイン

Kubernetesはcontrol-plane/etcd VM 1台とworker VM 2台で構成されるが、3台とも同じ物理Proxmox
ホスト `pve1` 上で動作している。2026-08-30の実測では、VM 101は2 vCPU/8 GiB、VM 102と103は
各4 vCPU/16 GiBで、合計10 vCPU/40 GiB RAMだった。したがって、
ノードを分けても、最も重要な障害である `pve1` の停止やメンテナンスからは保護できない。

物理ホストはAMD Ryzen 9 5900X（12コア/24スレッド）、125 GiB RAMで、実測availableは約30 GiBだった。
ZFS ARCとほかのVMで共有している。`local`は空き約64 GiB、`local-lvm`は約794 GiB、`vmpool`は
約582 GiBだった。Kubernetes VMを初期構成の4 vCPU/12 GiB Apps VMへ置き換えることで、相当量の
メモリをZFSと残りのゲストへ戻せる。Proxmoxは9.2.3、kernelは`7.0.6-2-pve`で、クラスタは単一node
だった。Apps VM用のVMID `112`は未使用である。

## ワークロードに対する実行時の複雑さ

観測したクラスタには、基盤Podが約37個、利用者向けアプリケーションPodが5個あった。

| 利用者向けPod | レプリカ数 | 観測したワーキングセット |
| --- | ---: | ---: |
| Unbound | 1 | 2487 MiB |
| SillyTavern | 1 | 892 MiB |
| Samba | 1 | 553 MiB |
| stashPad staging | 1 | 66 MiB |
| stashPad prod | 1 | 56 MiB |

基盤の数には、Kubernetesの制御コンポーネント、MetalLB、ingress-nginx、cert-manager、Flux、
NFS provisionerを含む。アプリケーションワークロードはいずれも複数レプリカを使用していない。
これが[ADR-0001](../adr/0001-single-apps-vm-compose.md)の主な根拠である。

## デリバリーと構成ドリフト

FluxはstashPad prod/stagingとSillyTavernをreconcileするが、導入済みの基盤・アプリケーション
コンポーネントすべてを対象にはしていない。リポジトリにはTerraform、Kubespray、直接適用するmanifest、
スクリプト、手動インストール手順が混在している。そのため、Git上の定義だけでは実際に何が導入されて
いるかを一貫して証明できない。

ルートREADMEにはOpenLDAP/phpLDAPadminとLDAP連携Sambaの説明もあるが、現行Samba manifestは
スタンドアロンの `tdbsam` を使用し、実行中ワークロードの一覧にOpenLDAPは含まれていなかった。
このような古い説明が残るため、移行では2つの構成説明を併存させず、廃止した定義を削除する。

現行環境用のTerraform stateとsecretファイルはworktreeに存在するが、ignore対象である。2026-08-29に
パスを限定してGit履歴を確認した結果、これらのファイルを含むコミットは見つからなかった。

## ネットワークの観測結果

- VLAN 10は管理/Server、VLAN 11はアプリケーションサービス、VLAN 20/30/40はclient/IoT/Guestである。
- VLAN 10、11、20は相互に広く到達可能で、意図した10/11分離が弱まっている。
- VLAN 63は既定のuntaggedネットワークとして機能するが、長期的に独立した機能要件はない。
- VLAN 10と11のDHCPプールは`.100-.200`を使い、VLAN 11のMetalLBプールも`.100-.200`を使う。
- サービスアドレスはWeb ingressが`.11.100`、DNSが`.11.101`、Sambaが`.11.103`である。
- ProxmoxホストとNFSサーバーは`.10.11`、Tailscale gatewayは`.10.30`である。
- Tailscaleは現在exit node routeを含む`0.0.0.0/0`、`::/0`、VLAN 10と11のsubnetをadvertiseし、
  UnboundのアドレスをグローバルDNSとして使っている。
- 通常のLAN DHCP clientにはUnboundではなくpublic DNSが配布される。
- VLAN 10とVLAN 11のDHCP poolはいずれも`.100-.200`で、MetalLBの`.11.100/.101/.103`および
  最終Apps VMアドレス候補と重複する。
- Proxmox `vmbr0`は`nic0`をbridge portとし、VLAN-awareで`2-4094`を許可している。`vmbr0.10`は
  `192.168.10.11/24`だが、`vmbr0.11`は`192.18.11.11/24`だった。Kubernetes VM側は
  `192.168.11.21-.23`を使用しているため、VLAN 11のサブネットは未解決の要確認事項である。
- `192.168.10.42`にはVM定義がなく、pingにも応答しなかった。DHCP pool外である。
- `192.168.11.102`はKubernetes masterのARPが`FAILED`で、pingにも応答しなかった。
- TailscaleのTailnet hostnameは`home-gateway`（PVE VM名は`tailscale-gateway`）、versionは`1.98.3`。
  自動update checkは有効だがapplyは手動で、IPv4 forwardingは有効だった。AdvertiseRoutesは
  `0.0.0.0/0`、`::/0`、`192.168.10.0/24`、`192.168.11.0/24`で、exit nodeは現行機能として維持する。
- 個人ID、メールアドレス、peer情報、NodeIDは監査記録へ保存しない。

これらの観測結果に基づき、まず現在のVLANでアプリケーションを切り替え、その後、別のメンテナンス
時間帯に4ゾーンのネットワーク再設計を行う段階的な方式とする。

## ストレージの観測結果

関連するアプリケーション状態はすべてNFS上のstorageにある。実測したNFS親exportは次の4つで、
いずれも`192.168.10.0/24`に対して主要option
`sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash`だった。
`/mnt/shared`には`fsid=100`、`/mnt/tank-gen2/data/shared`には`fsid=101`が付いていた。

- `/mnt/tank-gen2/data/k8s-volumes`
- `/mnt/tank-gen1/data/archive`
- `/mnt/tank-gen2/data/shared`
- `/mnt/shared`

Apps VMが利用する7 pathはすべて存在したが、`.homelab-export` markerは7つとも未作成だった。
`shared-hdd`と`stashPadLib`はUID/GID `10002:10002`、mode `0755`、PVC 3つは`root:root`、
mode `0777`だった。各ZFS poolは`ONLINE`である。Kubernetes PersistentVolumeは
`Retain`を使用するため、claim削除後もディレクトリは残るが、バックアップではない。
PVCの実使用量はSillyTavern 148 MiB、stashPad prod 56 MiB、staging 57 MiBだった。
stashPad mediaは`du`が25秒でtimeoutしたため、使用量を確定していない。

したがって移行では、復旧済みNFS/ZFSを外部の前提条件として扱い、最初の切替では現在のopaque PVC pathを
再利用し、すべてのstateful Composeプロジェクトでマウント検証を必須依存関係とする。正確なパスと最終的な
`/32` export契約は[目標アーキテクチャ](target-state.md#storage-contract)に記録する。

## DNS、証明書、運用上の観測結果

- `prod.stashpad.kojigenba-srv.com`と`staging.stashpad.kojigenba-srv.com`はHTTP `200`を返した。
- `sillytavern.kojigenba-srv.com`はBasic Authによる`401`で、期待どおりの応答だった。
- `prod.kojigenba-srv.com`と`staging.kojigenba-srv.com`はIngressにTLS SANがなく、curlでは自己署名証明書エラーになった。
- 正式証明書は2026-10-02または2026-10-03まで有効で、短縮aliasのprod/stagingは自己署名だった。
- Unboundは旧Replica 1つが稼働中だが、新Replicaは不正な`hagezi-tif` RPZでCrashLoopしている。
- blocklist更新Jobは直近3回が失敗している。手動DNS record 10件はAdGuard Home templateに保持済みである。
- Kubernetes上にOpenLDAP、phpLDAPadmin、LDAPSのworkload/serviceは存在しなかった。

## 運用上の観測結果

- 物理ホスト障害をまたいだ可用性は目的としない。
- 唯一の利用者はメンテナンス停止を許容し、無停止移行を求めていない。
- サービスIPの維持より、既存FQDNの維持を重視する。
- 監視は小規模でよいが、Apps VM全体の停止をVM外部から検知できなければならない。
- `stashPadDev`は一時的な作業用VMであり、今回の移行対象外とする。
- Tailscale gatewayとElastiFlowの実行環境は維持し、TerraformにはTailscale管理設定だけを加える。

## 管理プレーンの観測結果

- PVEには`root@pam`だけが存在し、ACLはない。
- Terraform用API user/tokenは未作成である。
- SSHとkubectlによる確認は読み取り専用で行い、実機変更は行っていない。

## 再検証の要件

この監査は判断の根拠を説明するものだが、実行時の唯一の信頼できる情報源ではない。切替前にフェーズ0で、
実際のVM割り当て、ワークロードのイメージ、IP/MAC/ARP/DHCPの所有状況、NFS export、データの所有者と
サイズ、FQDN、証明書、Tailscale設定を切替直前に再収集する。`vmbr0.11`のサブネット、DHCP/VIP重複、
marker未作成は未解決事項として扱う。重要な差分があればADRを改訂するか、新しいADRを作成する。
