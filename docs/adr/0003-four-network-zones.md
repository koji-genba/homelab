# ADR-0003: ネットワークを4ゾーンへ整理する

- 状態: 承認済み（2026-09-06詳細化）
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
| 20 | `192.168.20.0/24` | Trusted client | `.100-.254` |
| 30 | `192.168.30.0/24` | IoT | `.100-.254` |
| 40 | `192.168.40.0/24` | Guest、未指定/untagged port | `.100-.254` |

各サブネットの`.1`をゲートウェイとする。Trusted/IoT/Guestでは`.2-.99`を予約/static、
`.100-.254`をDHCPに使用する。Serverでは`.2-.249`をstatic/予約、`.250-.254`を新規物理機器の
初期設定用DHCPに使用する。Apps VMは最終的に
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
手動とするが、SSID/VLAN/port/管理IPという期待状態はGitで管理する。明示用途を持つaccess port以外の
untagged trafficは、trunk portを含めて無条件でGuest VLAN 40へ入れる。access portでのtag制限は
Phase 4へ含めず、必要なら独立したhardeningとして扱う。

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
- ECW5211はuplinkでtagged VLAN 10/20/30/40だけを受け、untaggedを使用しない。管理IP `.10.2`もtagged 10とする。
