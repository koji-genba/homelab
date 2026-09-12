# 目標ネットワークゾーン

- 状態: 承認済みの設計、実機未適用（2026-09-06にPhase 4基本方針を合意）
- 日付: 2026-08-29
- 設計判断: [ADR-0003](../adr/0003-four-network-zones.md)
- 移行: [KubernetesからComposeへの移行、フェーズ4](../migration/k8s-to-compose.md#phase-4-network-migration)

この文書はIX2215、switch、ECW5211へ手動反映する際の期待状態を定義する。実際のport番号、
SSID名、機器MAC、現在のleaseはフェーズ0で収集し、反映用checklistへ追記する。

## ゾーンとアドレス計画

| VLAN | サブネット | ゾーン | ゲートウェイ | DHCP | 固定/予約 |
| ---: | --- | --- | --- | --- | --- |
| 10 | `192.168.10.0/24` | Server | `.1` | `.250-.254`（新規機器の初期設定専用、短期lease） | `.2-.249` static/予約 |
| 20 | `192.168.20.0/24` | Trusted | `.1` | `.100-.254` | `.2-.99` 予約 |
| 30 | `192.168.30.0/24` | IoT | `.1` | `.100-.254` | `.2-.99` 予約/controller |
| 40 | `192.168.40.0/24` | Guest | `.1` | `.100-.254` | `.2-.99` 予約 |

Serverの確定済みaddressは次のとおり。

| アドレス | 所有者 | 備考 |
| --- | --- | --- |
| `192.168.10.1` | IX2215 | ゲートウェイ |
| `192.168.10.11` | Proxmox | 既存、維持 |
| `192.168.10.101` | Apps VM | VLAN移行後。フェーズ1は`.10.42` |
| `192.168.10.102` | Tailscale gateway | 現行`.30`からPhase 4でrenumber |
| `192.168.10.103` | ElastiFlow | 現行`.40`からPhase 4でrenumber |

新規割当はIP inventory、ARP、DHCP lease、Proxmox inventoryを照合してから確定する。

## ポリシーマトリクス

`allow`はstateful firewallの新規接続を表す。応答trafficはすべてのzoneで許可する。
IX2215では動的フィルタで開始方向を追跡し、単に逆方向のstatic ACLをpermitして
双方向の新規接続を許可する構成にはしない。

| 接続元 | Server | Trusted | IoT | Guest | Internet |
| --- | --- | --- | --- | --- | --- |
| Server | 許可 | 拒否（新規接続の初期値） | 拒否（新規接続の初期値） | 拒否 | 許可 |
| Trusted | 許可 | 許可 | 許可 | 拒否 | 許可 |
| IoT | 拒否（初期値。具体的なcontroller要件が判明した場合だけ個別許可） | 拒否 | 許可 | 拒否 | 許可 |
| Guest | 拒否 | 拒否 | 拒否 | client isolation | 許可 |
| Tailscale | Trusted相当でServerへ許可 | routeしない | routeしない | routeしない | 既存exit nodeを維持 |

追加例外は、source、destination、port、用途、廃止条件をGitへ記録してから追加する。IoTにはpublic DNSを
DHCPで配布し、Server上のDNS/NTPを包括的な例外としては許可しない。mDNS reflectorは必要性が確認できるまで
導入しない。

IX2215自身のSSH/HTTP管理はServerとTrustedからだけ許可する。IoTとGuestからは、各zoneのgateway addressを
含めて管理planeへ接続できないようにする。Server VLAN内は同一trust boundaryとして扱い、必要な追加制限は
各hostのfirewallで行う。

Apps VM自身でも多層防御（defense in depth）として、Trusted CIDRとTailscaleからだけSSH、DNS、HTTP(S)、SMBを
受け付ける。Internetからのport forwardは作らない。

## DNSとTailscale

- 通常のDHCP clientにはpublic resolverを配布し、宅内全通信をAdGuardへ強制しない。
- TailscaleのグローバルネームサーバーとしてAdGuard Homeを設定する。
- フェーズ1のDNSサービスアドレスは`192.168.11.101`、最終アドレスは`192.168.10.101`とする。
- Tailscale gatewayの既存exit node機能は維持する。移行中は`192.168.10.0/24`と
  `192.168.11.0/24`を保持し、`.10.101`の宅外到達性を確認した後に`.11.0/24`だけを外す。
  VLAN 20/30/40は広告せず、最終的なLAN向けAdvertiseRoutesはServerの`192.168.10.0/24`だけとする。
- 固定宅内clientはsubnet routeを受け入れない。宅内外を移動するroaming clientは、宅外からServerへ
  接続するときだけ`Use Tailscale subnets`（`accept-routes`）を有効にする。自動切替はPhase 4の要件にしない。
- DNS切替はAdGuardの通常解決、内部record、block、allowlistを検証した後に手動applyする。

## 有線ポートと無線AP

- uplink/trunkは必要なVLANをtaggedで許可する。
- untagged trafficは、明示用途を持つaccess port（GE2 port 2のTrusted、port 3のServer）を除き、
  trunk portを含めて無条件でGuest VLAN 40へ入れる。現行のuntagged VLAN 63はGuestで置き換える。
- Proxmox接続portは現在どおりServer VLAN 10をtaggedで運び、PVE host/VMの接続を維持する。
  全VMのNICとPVE host（`vmbr0.10`）はtaggedであり、untaggedのGuest化の影響を受けない。
- ECW5211の管理interfaceはServer VLAN 10へtaggedで置く。ECW5211はuntaggedを使用せず、uplinkでは
  tagged VLAN 10/20/30/40だけを受ける。
- Trusted、IoT、GuestのSSIDをそれぞれVLAN 20、30、40へtag付けする。
- Server用SSIDは作らない。
- Guest SSIDではclient isolationを有効にする。

物理的に管理された宅内設置であることから、access portでのtagged VLAN制限はPhase 4では
行わない。必要性が生じた場合に独立したhardeningとして扱う。

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
| ECW5211バックアップ場所/hash | 2026-09-12、management VLANをtagged 10へ変更した後に取得。repo直下`tmp/ecw/config-backup.conf`（Git管理外、mode `0600`）、SHA-256 `a0253614dc7075e79675760af62add0643adb09167466ede3c11bd7624e13eb0`。management VLAN、SSID→VLAN、Wireless Station Isolationの変更をすべて反映した状態 |
| コンソール/OOB試験 | 2026-09-12、IX2215のconsole loginを確認 |
| ポート/VLANインベントリのcommit | 未実施 |
| 適用設定のcommit | 未実施 |
| allow/deny試験結果 | 未実施 |
| ロールバック結果/判断 | 未実施 |

## IX2215変更時の作業継続性

ACL再編では、管理端末のInternet接続とCodex sessionの双方が失われる可能性を前提とする。この段階へ
入る前に、投入コマンド、確認コマンド、rollbackコマンド、期待出力をローカル文書へ保存し、console
接続した操作者がCodexへ接続できなくてもrollbackまで完遂できる状態にする。

DHCP poolの縮小、`sflow collector`の変更、bridge-groupの付け替えのような局所的な変更は、consoleを
開いた状態で行い、疎通確認が済むまで`write memory`しない。失敗したらreloadでstartup-configへ戻す。
