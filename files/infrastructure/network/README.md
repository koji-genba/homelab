# IX2215 Router Configuration

## 現在の基準

- 機種: NEC IX2215
- ホスト名: `IX2215-HOME`
- ソフトウェア: 10.11.6
- 実機保存確認: 2026-09-19（Port 4変更後）
- 管理構成更新: 2026-09-18（Port 4をVLAN 10 accessへ変更）、2026-09-19（Port 3/4の接続先をDGX Spark×2へ更新）
- 構成ファイル: [config.txt](config.txt)

`config.txt`は、実機の保存済み`startup-config`を基準にコメントを加えた管理用コピーである。
2026-09-18のPort 4変更は2026-09-19に実機へ反映し、疎通確認後に`write memory`で保存済みである。
認証情報の行は既存値を保持しているため、公開場所へ転載しないこと。

## WAN

`GigaEthernet0.0`がDHCPで上流へ接続し、default routeを受信する。NAPTとhairpinningを有効化し、
NAPT tableは最大16,384 entries、timeoutはTCP 3600秒、UDP 1800秒、DNS 30秒としている。

## VLANとDHCP

| VLAN | Zone | Subnet / gateway | DHCP pool | Lease |
|---:|---|---|---|---:|
| 10 | Server / Management | `192.168.10.0/24`, `.1` | `.250-.254` | 1時間 |
| 20 | Trusted | `192.168.20.0/24`, `.1` | `.100-.200` | 24時間 |
| 30 | IoT | `192.168.30.0/24`, `.1` | `.100-.200` | 12時間 |
| 40 | Guest | `192.168.40.0/24`, `.1` | `.100-.200` | 1時間 |

VLAN 11とVLAN 63は撤去済みである。VLAN 20/30/40の`.201-.254`は現在未割当。
DNSは全profileで`1.1.1.1`と`8.8.8.8`を配布する。

## 物理ポート

| Port | 接続先 / 用途 | Untagged | Tagged |
|---:|---|---|---|
| 1 | PVE1 | 収容しない | VLAN 10 |
| 2 | Windows desktop | VLAN 20 | 収容しない |
| 3 | DGX Spark（4TB機、`192.168.10.51`） | VLAN 10 | 収容しない |
| 4 | DGX Spark（1TB機、`192.168.10.52`） | VLAN 10 | 収容しない |
| 5-7 | 空き / default Guest access | VLAN 40 | 収容しない |
| 8 | ECW5211 AP trunk | 収容しない | VLAN 10, 20, 30, 40 |

Port 3/4はいずれもVLAN 10のaccess portであり、DGX Spark 2台を収容する。2026-09-18のPort 4
変更がこの2台目の席にあたるため、**`config.txt`側の変更は不要**である。この表の更新は接続先の記録
だけを変えている。Port 3にあったedgeXpertは現在この表の管理外であり、再接続する場合は空きGuest
access（Port 5-7）ではなくServer VLAN 10のportへ移す判断を別途記録する。

実装上、Port 2/3-4/5-7はそれぞれ`vlan-group 2/1/4`のbase interfaceをBVIへbridgeするaccess
portである。Port 1は`vlan-group 6`のtagged VLAN 10だけを`GigaEthernet2:6.1`へ収容する。
Port 8はbase側`GigaEthernet2.0`をどのbridgeにも入れず、`GigaEthernet2.1/.3/.4/.5`で4 VLANを
収容する。

`GigaEthernet2:3.0`は保存構成に残るが、`vlan-group 3`へ割り当てた物理portがないため転送には使われない。

### AP trunkの注意点

Port 8でtagged VLAN 40とuntagged側を同じ`bridge-group 40`へ入れると、APから届いたARP requestが
untagged側へ反射し、無線clientがgateway `192.168.40.1`をARP解決できなくなる現象を確認した。
このため、AP trunkのuntagged側`GigaEthernet2.0`にはbridge-groupを設定しない。

## VLAN間ポリシー

すべてのzoneからInternetへの通信を許可し、zone間は次の方針にする。

| 発信元 | Server 10 | Trusted 20 | IoT 30 | Guest 40 |
|---|---|---|---|---|
| Server 10 | — | 新規開始を拒否 | 拒否 | 拒否 |
| Trusted 20 | 許可 | — | 許可 | 拒否 |
| IoT 30 | 拒否 | 新規開始を拒否 | — | 拒否 |
| Guest 40 | 拒否 | 拒否 | 拒否 | — |

TrustedからServer/IoTへの通信は`trusted-trig`と`trusted-dyn`で動的に追跡し、応答方向だけを許可する。
Server/IoTからTrustedへの未要求通信は、BVI20のoutput filter `trusted-in`で拒否する。Guestは
`guest-out`で他の3 subnetを明示的に拒否する。

実機でInternet、Trusted→Server/IoT、各deny方向、SMB/HTTPS、tailnet route/exit nodeを確認済み。

## 管理アクセス

IX2215のSSHとHTTP管理は`mgmt-src`を適用し、VLAN 10とVLAN 20からだけ許可する。
HTTPはDigest認証を使用する。

## sFlow

- Agent: `192.168.10.1`
- Collector: `192.168.10.103:6343`
- Data source: `GigaEthernet2`
- Sampling: in/outとも1/512、counter interval 30秒

IX側ではsample出力を確認済み。現在はElastiFlowが停止している可能性があるため、collector側の受信確認は
別件として保留し、このネットワーク変更では触らない。

## UFS cache timeout

| VLAN | TCP | UDP |
|---:|---:|---:|
| 10 | 300秒 | 1800秒 |
| 20 | 60秒 | 300秒 |
| 30 | 300秒 | 300秒 |
| 40 | 60秒 | 180秒 |

global UFS cacheは最大20,000 entriesで有効化している。

## NTPとQoS

NTPは`210.173.160.27/.57/.87`を使い、sourceは`GigaEthernet0.0`、intervalは3600秒。
QoSでは対象UDP trafficをDSCP 48へ設定する`output-policy`をBVI10/20/40へinput/outputとも適用している。

## 関連文書

- [最終ゾーン設計](../../../docs/network/target-zones.md)
- [IX ACL stateful化runbook](../../../docs/network/ix-acl-stateful-runbook.md)
- [4ゾーン化ADR](../../../docs/adr/0003-four-network-zones.md)
- [移行状況](../../../docs/migration/implementation-status.md)
