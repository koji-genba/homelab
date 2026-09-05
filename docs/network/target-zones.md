# 目標ネットワークゾーン

- 状態: 承認済みの設計、実機未適用
- 日付: 2026-08-29
- 設計判断: [ADR-0003](../adr/0003-four-network-zones.md)
- 移行: [KubernetesからComposeへの移行、フェーズ4](../migration/k8s-to-compose.md#phase-4-network-migration)

この文書はIX2215、switch、ECW5211へ手動反映する際の期待状態を定義する。実際のport番号、
SSID名、機器MAC、現在のleaseはフェーズ0で収集し、反映用checklistへ追記する。

## ゾーンとアドレス計画

| VLAN | サブネット | ゾーン | ゲートウェイ | DHCP | 固定/予約 |
| ---: | --- | --- | --- | --- | --- |
| 10 | `192.168.10.0/24` | Server | `.1` | なし | `.2-.99` 物理/storage、`.100-.199` VM、`.200-.254` network機器 |
| 20 | `192.168.20.0/24` | Trusted | `.1` | `.100-.254` | `.2-.99` 予約 |
| 30 | `192.168.30.0/24` | IoT | `.1` | `.100-.254` | `.2-.99` 予約/controller |
| 40 | `192.168.40.0/24` | Guest | `.1` | `.100-.254` | `.2-.99` 予約 |

Serverの確定済みaddressは次のとおり。

| アドレス | 所有者 | 備考 |
| --- | --- | --- |
| `192.168.10.1` | IX2215 | ゲートウェイ |
| `192.168.10.11` | Proxmox | 既存、維持 |
| `192.168.10.101` | Apps VM | VLAN移行後。フェーズ1は`.10.42` |
| `192.168.10.102` | Tailscale gateway | VLAN移行時に変更 |
| `192.168.10.103` | ElastiFlow | VLAN移行時に変更 |

新規割当はIP inventory、ARP、DHCP lease、Proxmox inventoryを照合してから確定する。

## ポリシーマトリクス

`allow`はstateful firewallの新規接続を表す。応答trafficはすべてのzoneで許可する。

| 接続元 | Server | Trusted | IoT | Guest | Internet |
| --- | --- | --- | --- | --- | --- |
| Server | 許可 | 明示許可のみ | 明示許可のみ | 拒否 | 許可 |
| Trusted | 許可 | 許可 | 許可 | 拒否 | 許可 |
| IoT | DNS/NTP/controllerのみ | 拒否 | 許可 | 拒否 | 許可 |
| Guest | 拒否 | 拒否 | 拒否 | client isolation | 許可 |
| Tailscale | Trusted相当でServerへ許可 | routeしない | routeしない | routeしない | 既存exit nodeを維持 |

追加例外は、source、destination、port、用途、廃止条件をGitへ記録してから追加する。mDNS reflectorは
必要性が確認できるまで導入しない。

Apps VM自身でも多層防御（defense in depth）として、Trusted CIDRとTailscaleからだけSSH、DNS、HTTP(S)、SMBを
受け付ける。Internetからのport forwardは作らない。

## DNSとTailscale

- 通常のDHCP clientにはpublic resolverを配布し、宅内全通信をAdGuardへ強制しない。
- TailscaleのグローバルネームサーバーとしてAdGuard Homeを設定する。
- フェーズ1のDNSサービスアドレスは`192.168.11.101`、最終アドレスは`192.168.10.101`とする。
- Tailscale gatewayの既存exit node機能と、現行の`0.0.0.0/0`、`::/0`、`192.168.10.0/24`、
  `192.168.11.0/24`のAdvertiseRoutesはTerraformで保持する。Server以外のrouteを削減するかは利用実態を
  確認してから別途判断する。
- DNS切替はAdGuardの通常解決、内部record、block、allowlistを検証した後に手動applyする。

## 有線ポートと無線AP

- uplink/trunkは必要なVLANだけをtaggedで許可する。
- Proxmox接続portはServerをnative/managementとし、VMに必要なVLANをtaggedで許可する。
- ECW5211の管理interfaceはServer VLAN 10へ置く。
- Trusted、IoT、GuestのSSIDをそれぞれVLAN 20、30、40へtag付けする。
- Server用SSIDは作らない。
- Guest SSIDではclient isolationを有効にする。
- 明示用途のないaccess portはshutdownせず、untagged Guest VLAN 40にする。

ECW5211に適切なprovider/APIがないため反映は手動とする。SSID名、暗号方式、credentialはGitへ
平文保存せず、期待するVLAN対応付けと操作結果だけを記録する。

## IPv6

routerのRA、DHCPv6、IPv6 forwardingを無効化し、各zoneのclientがグローバルIPv6経由でIPv4 ACLを
迂回しないことを確認する。Apps VMもIPv6 listenerを公開しない。将来IPv6を再導入する場合は、
IPv4と同等のゾーンポリシーを設計した新しいADRを先に作成する。

## 手動変更記録

反映時は以下を埋め、running/startup configの差分とともに保存する。

| 項目 | 値 |
| --- | --- |
| メンテナンス日/操作者 | 未実施 |
| IX2215バックアップ場所/hash | 未実施 |
| ECW5211バックアップ場所/hash | 未実施 |
| コンソール/OOB試験 | 未実施 |
| ポート/VLANインベントリのcommit | 未実施 |
| 適用設定のcommit | 未実施 |
| allow/deny試験結果 | 未実施 |
| ロールバック結果/判断 | 未実施 |
