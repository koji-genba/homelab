# ADR-0003: ネットワークを4ゾーンへ整理する

- 状態: 実装済み（2026-09-13）。Port 4変更も実機反映済み（2026-09-19）
- 日付: 2026-08-29

## 背景

VLAN 10と11は管理用/アプリケーション用の分離を意図したが、管理端末と利用端末の集合がほぼ同じで、
10/11/20間も広く許可されている。VLAN 63も未指定port用の独立した機能ゾーンとして維持する
ほどの効果がない。

## 決定

最終構成を次の4ゾーンへ整理し、VLAN 11と63を廃止する。IPv6は無効化する。

| VLAN | サブネット | 用途 | DHCP |
| --- | --- | --- | --- |
| 10 | `192.168.10.0/24` | Server、Proxmox、Apps VM、network機器管理 | 原則static。`.250-.254`だけ初期設定用DHCP |
| 20 | `192.168.20.0/24` | Trusted client | `.100-.200` |
| 30 | `192.168.30.0/24` | IoT | `.100-.200` |
| 40 | `192.168.40.0/24` | Guest、空きaccess port | `.100-.200` |

各サブネットの`.1`をゲートウェイとする。Trusted/IoT/Guestでは`.2-.99`を予約/static、
`.100-.200`をDHCPに使用し、`.201-.254`は未割当とする。Serverでは`.2-.249`をstatic/予約、
`.250-.254`を新規物理機器の初期設定用DHCPに使用する。Apps VMは最終的に
`192.168.10.101`、Tailscale gatewayは`.102`、ElastiFlowは`.103`とする。

通信方針は次のとおり。

- TrustedからServerとIoTを許可する。
- ServerからTrusted/IoTは応答と明示許可だけにする。
- IoTからServerは既定拒否し、必要なDNS、NTP、controllerだけを許可する。
- IoTからTrustedを拒否する。
- Guestからプライベートネットワークを拒否し、無線ではclient isolationを有効にする。
- 各ゾーンからInternetは許可する。
- 必要性が確認できるまでmDNS reflectorは導入しない。
- Tailscale clientはTrusted相当とする。Tailscale gatewayの既存exit node機能は現行利用機能として維持し、
  最終的なLAN向けAdvertiseRoutesはServerサブネットだけとする。

SSIDはTrusted、IoT、Guestを各VLANへtag付けし、Server用SSIDは作らない。ECW5211の操作は
手動とするが、SSID/VLAN/port/管理IPという期待状態はGitで管理する。access portはuntaggedの1 VLAN、
trunk portは必要なtagged VLANだけを収容し、trunkのuntagged trafficは破棄する。

## 移行時の制約

アプリ移行とVLAN再設計を同時に行わない。まず現在のVLAN/IPでKubernetesをComposeへ移し、
安定後に別のメンテナンス時間帯で4ゾーン化する。

フェーズ1のApps VM管理IP候補は`192.168.10.42`とする。現在のVLAN 10 DHCPプール
`.100-.200`と最終IP `.101`が重なるためで、使用前にARP、DHCP lease、Proxmox inventoryを
確認する。サービス用`.11.100/.101/.103`は、旧MetalLBとVLAN 11 DHCPを停止し、ARP消失を
確認してから引き継ぐ。最終network移行時に単一`.10.101`へ集約する。

## 影響

- 実質的なtrust境界にVLAN数が一致し、ACLを説明しやすくなる。
- Apps VMは最終的に単一IPで80/443/53/445を提供できる。
- IX2215とECW5211の反映はconsole/OOB手段を確保した別のメンテナンス時間帯に手動実施する。

## 2026-09-06の詳細化

- Server DHCPを完全には廃止せず、新規物理機器の初期設定用に`.250-.254`だけを短期leaseで残す。
  現行の`.100-.200`はApps VMを`.101`へ移す前に縮小する。
- Tailscale gatewayは`.30`から`.102`へ、ElastiFlowは`.40`から`.103`へrenumberする。
  どちらも短時間の停止を許容できるため、Apps `.101`と連番にしてIPAMの一貫性を優先する。
- TrustedからServerとIoTへの新規接続を許可し、逆方向はstateful inspectionによる応答だけを許可する。
  ServerからTrusted/IoTへの明示的な新規接続例外と、IoTからServerへの例外は初期状態では0件とする。
- IoTにはpublic DNSを配布する。Server上のDNS/NTPを包括的な例外として許可しない。
- Tailscaleが広告するLAN routeは、移行完了後はServerの`192.168.10.0/24`だけとする。
  固定宅内clientはsubnet routeを受け入れず、roaming clientは必要時に手動で切り替える。
- IX2215のSSH/HTTP管理はServerとTrustedからだけ許可し、IoTとGuestからは拒否する。
- IX2215のACL再編は、InternetとCodex sessionを失っても完遂できるよう、実行・確認・rollback手順を
  事前にofflineで用意する。DHCP縮小やbridge-group変更のような局所的な変更は、consoleを開いた
  状態で行い、失敗時はreloadで戻す。

## 2026-09-12の追加決定

- untagged trafficは、明示用途を持つaccess port（GE2 port 2のTrusted、port 3のServer）を除き、
  無条件でGuest VLAN 40へ入れる。現行VLAN 63の役割をGuestで置き換え、Phase 4の対象に含める。
  ただしtrunk portへも適用する部分は、下記の2026-09-13改訂で撤回した。
- ECW5211はuplinkでtagged VLAN 10/20/30/40だけを受け、untaggedを使用しない。管理IP `.10.2`もtagged 10とする。

## 2026-09-13の実機検証による改訂

- GE2 port 1（PVE1）とport 8（ECW5211）はタグ専用trunkとし、untaggedをどのzoneにも収容しない。
- port 2はTrusted VLAN 20、port 3はServer VLAN 10、空きport 4～7はGuest VLAN 40のaccess portとする。
  access portに届いたtagged frameは別zoneへ転送しない。
- ECW uplinkでtagged VLAN 40とuntagged VLAN 40を同じbridge-groupへ入れると、taggedで受信したARPが
  同じ物理portへuntaggedで反射し、Guest clientがgatewayのARPを解決できなくなることを実機で確認した。
  したがって同一物理port上で同じzoneをtagged/untaggedの両方へ収容しない。
- PVE hostの`vmbr0.10`とTerraform管理VMの現用NICはいずれも物理uplink上でtagged VLAN 10を使用するため、
  port 1のuntagged廃止による影響はない。旧Kubernetes VMに残るVLAN 11 NICは廃止済みnetworkの履歴である。

## 2026-09-18の有線Server port追加

- GE2 port 4をGuest用VLAN groupからServer用VLAN groupへ移し、port 3と同じServer VLAN 10のaccess
  portとする。これにより、Server accessはport 3/4、空きGuest accessはport 5～7となる。
- access portでtagged frameを転送しない方針と、port 1/8をタグ専用trunkとする方針は変更しない。
- 2026-09-19にユーザーが実機反映済みと確認した。Port 4のVLAN 10 DHCP/疎通と`write memory`は未記録である。
