# ADR-0003: ネットワークを4ゾーンへ整理する

- 状態: 承認済み
- 日付: 2026-08-29

## 背景

VLAN 10と11は管理用/アプリケーション用の分離を意図したが、管理端末と利用端末の集合がほぼ同じで、
10/11/20間も広く許可されている。VLAN 63も未指定port用の独立した機能ゾーンとして維持する
ほどの効果がない。

## 決定

最終構成を次の4ゾーンへ整理し、VLAN 11と63を廃止する。IPv6は無効化する。

| VLAN | サブネット | 用途 | DHCP |
| --- | --- | --- | --- |
| 10 | `192.168.10.0/24` | Server、Proxmox、Apps VM、network機器管理 | なし |
| 20 | `192.168.20.0/24` | Trusted client | `.100-.254` |
| 30 | `192.168.30.0/24` | IoT | `.100-.254` |
| 40 | `192.168.40.0/24` | Guest、未指定/untagged port | `.100-.254` |

各サブネットの`.1`をゲートウェイ、`.2-.99`を予約/staticとする。Serverでは`.2-.99`を物理/storage、
`.100-.199`をVM、`.200-.254`をswitch/AP等に使用する。Apps VMは最終的に
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
  AdvertiseRoutesの整理（Serverサブネット以外を削減するか）は利用実態を確認してから判断する。

SSIDはTrusted、IoT、Guestを各VLANへtag付けし、Server用SSIDは作らない。ECW5211の操作は
手動とするが、SSID/VLAN/port/管理IPという期待状態はGitで管理する。未指定物理portは
shutdownせず、untagged Guestとして利用可能にする。

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
