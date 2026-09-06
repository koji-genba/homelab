# IX2215 Router Configuration

## 機器情報

- **機種**: NEC IX2215
- **ホスト名**: IX2215-HOME
- **バージョン**: 10.11.6

## ネットワーク構成

### WAN接続

- **インターフェース**: GigaEthernet0.0
- **接続方式**: DHCP
- **NAPT**: 有効 (Hairpinning対応)
  - **最大エントリ数**: 16,384
- **タイムアウト設定**:
  - TCP: 3600秒
  - UDP: 1800秒
  - DNS: 30秒

### LAN側VLAN構成

| VLAN ID | ネットワーク | 用途 | Untaggedポート | DHCPプール | リース時間 |
|---------|-------------|------|---------------|-----------|----------|
| 10 | 192.168.10.0/24 | Server (Management) | - | .100-.200 | 24時間 |
| 11 | 192.168.11.0/24 | Server Application | - | 未割当（binding解除済み） | - |
| 20 | 192.168.20.0/24 | Main (Client) | Port 2 | .100-.200 | 24時間 |
| 30 | 192.168.30.0/24 | IoT | Port 3 | .100-.200 | 12時間 |
| 40 | 192.168.40.0/24 | Guest | Port 4 | .100-.200 | 1時間 |
| 63 | 192.168.63.0/24 | Default | Port 1, 5-8 | .100-.200 | 30分 |

**注**: 全ポート（Port 1-8）がすべてのタグVLAN（10, 11, 20, 30, 40）に対応しています。

### ポート割り当て (GigaEthernet2)

#### タグVLAN対応 (全ポート共通)

GigaEthernet2.1-2.5のサブインターフェース設定により、**全ポート（Port 1-8）**で以下のタグVLANが利用可能:

- VLAN 10 (Tagged) - GigaEthernet2.1 → bridge-group 10 → BVI10
- VLAN 11 (Tagged) - GigaEthernet2.2 → bridge-group 11 → BVI11
- VLAN 20 (Tagged) - GigaEthernet2.3 → bridge-group 20 → BVI20
- VLAN 30 (Tagged) - GigaEthernet2.4 → bridge-group 30 → BVI30
- VLAN 40 (Tagged) - GigaEthernet2.5 → bridge-group 40 → BVI40

#### Untaggedトラフィック処理 (vlan-groupによる制御)

| ポート | vlan-group | Untagged VLAN | 処理フロー |
|--------|-----------|---------------|----------|
| Port 1 | 6 | 63 (Default) | GigaEthernet2:6.0 → bridge-group 63 → BVI63 |
| Port 2 | 2 | 20 (Main) | GigaEthernet2:2.0 → bridge-group 20 → BVI20 |
| Port 3 | 3 | 30 (IoT) | GigaEthernet2:3.0 → bridge-group 30 → BVI30 |
| Port 4 | 4 | 40 (Guest) | GigaEthernet2:4.0 → bridge-group 40 → BVI40 |
| Port 5-7 | 6 | 63 (Default) | GigaEthernet2:6.0 → bridge-group 63 → BVI63 |
| Port 8 | (未割当) | 63 (Default) | GigaEthernet2.0 → bridge-group 63 → BVI63 |

## セキュリティポリシー

### VLAN間アクセス制御

各VLANからのアウトバウンドトラフィックに対してアクセスリストを適用:

#### Server VLAN (10) → 他VLAN
- **許可**: VLAN 11, VLAN 20, インターネット
- **拒否**: VLAN 30 (IoT), VLAN 40 (Guest), VLAN 63 (Default)

#### Server Application VLAN (11) → 他VLAN
- **許可**: VLAN 10, VLAN 20, インターネット
- **拒否**: VLAN 30 (IoT), VLAN 40 (Guest), VLAN 63 (Default)

#### Main VLAN (20) → 他VLAN
- **許可**: VLAN 10, VLAN 11, インターネット
- **拒否**: VLAN 30 (IoT), VLAN 40 (Guest), VLAN 63 (Default)

#### IoT VLAN (30) → 他VLAN
- **許可**: インターネットのみ
- **拒否**: すべての他VLAN (10, 11, 20, 40, 63)

#### Guest VLAN (40) → 他VLAN
- **許可**: インターネットのみ
- **拒否**: すべての他VLAN (10, 11, 20, 30, 63)

#### Default VLAN (63) → 他VLAN
- **許可**: インターネットのみ
- **拒否**: すべての他VLAN (10, 11, 20, 30, 40)

### セキュリティ機能

- **SSH**: 有効
- **HTTP管理**: 有効 (Digest認証)
- **UFSキャッシュ**: 有効 (最大20,000エントリ)
- **QoS**: VoIPトラフィック優先 (DSCP 48設定)

## DHCP設定

VLAN 11を除くすべてのVLANでDHCPサーバーが有効:

VLAN 11は2026-09-05のCompose移行に伴い`interface BVI11`の`ip dhcp binding server_app-dhcp`を
解除したため、DHCPを配布しない。`ip dhcp profile server_app-dhcp`の定義自体は残してある。

- **DNSサーバー**: 1.1.1.1, 8.8.8.8
- **ドメイン名**:
  - VLAN 10, 11: `kojigenba-srv.com`
  - VLAN 20: `client.kojigenba-srv.com`
  - VLAN 30: `iot.kojigenba-srv.com`
  - VLAN 40: `guest.kojigenba-srv.com`
  - VLAN 63: `default.kojigenba-srv.com`

## NTP設定

- **NTPサーバー**:
  - 210.173.160.27 (Priority 30)
  - 210.173.160.57 (Priority 20)
  - 210.173.160.87 (Priority 10)
- **送信元インターフェース**: GigaEthernet0.0
- **同期間隔**: 3600秒

## タイムゾーン

- **設定**: +09:00 (JST)

## フローエクスポート（sFlow）設定案 - ElastiFlow連携

ネットワークトラフィック可視化のため、[ElastiFlow](../terraform/elastiflow/README.md)（VLAN10上のLXCコンテナ、192.168.10.40）にsFlowをエクスポートする案。

**反映状況**: `config.txt`（実機のrunning-config控え）へ、LAN側 `GigaEthernet2` のsFlow送信設定を反映済み。NEC UNIVERGE IX2000/IX3000シリーズのコマンドリファレンスでは、agent/collectorはグローバルコンフィグモード、sampling-rate/polling-intervalはデバイスコンフィグモードのコマンドとして定義されているため、IXの構文に合わせて物理デバイス `GigaEthernet2` に設定している。IX2215はNetFlow/IPFIXの設定例が確認できなかったため、sFlow前提とする。

WAN側 `GigaEthernet0` でサンプリングすると、インターネット向け通信はNAPT後のGE0アドレス（例: 172.16.0.26）が送信元として見えやすい。宅内クライアント/サーバ単位で「どこへ通信しているか」を見る目的では、NAPT前のLAN側である `GigaEthernet2` をサンプリング対象にする。

```text
! グローバル設定
sflow agent ip 192.168.10.1        ! BVI10（管理VLANの自IP）をagentアドレスに
sflow collector ip 192.168.10.40   ! ElastiFlowコンテナ（デフォルトUDP 6343）

! デバイス単位でサンプリングを有効化（LAN側）
device GigaEthernet2
  sflow sampling-rate 512 in
  sflow sampling-rate 512 out
  sflow polling-interval 30
```

すでに `GigaEthernet0` 側のsFlow設定を実機へ反映済みの場合は、GE0側を無効化してからGE2側を有効化する。

```text
device GigaEthernet0
  no sflow sampling-rate 512 in
  no sflow sampling-rate 512 out
  no sflow polling-interval

device GigaEthernet2
  sflow sampling-rate 512 in
  sflow sampling-rate 512 out
  sflow polling-interval 30
```

- LAN側（デバイス: `GigaEthernet2`、配下にVLAN 10/11/20/30/40/63）をサンプリング対象にする。これにより、GE2配下の各クライアント/サーバから、GE2配下の別VLANまたはGE0先の外部宛てへの通信をNAPT前のアドレスで見やすくする。
- `GigaEthernet0` 側にもsFlowを残すと、同じインターネット向け通信がNAPT後のWANアドレスでも観測され、ElastiFlow上で送信元がGE0アドレスに見えるデータが混ざる。そのため、クライアント単位の可視化を優先する場合はGE0側のsFlow sampling設定は外す。
- sFlowはUDPの片方向送信（ルーター→コレクタ）のみで、既存の通信に影響しない設定変更。
- コレクタは管理VLAN10上の `192.168.10.40` で、agentアドレスにしているBVI10 (`192.168.10.1`) と同一セグメントのため、VLAN間ACLの追加は不要想定。
- 実機反映後は `show sflow information` でagent/collectorと対象デバイスを確認し、必要に応じて `clear sflow statistics` 後にElastiFlow側の受信状況を見る。

## UFSキャッシュタイムアウト

| VLAN | TCP | UDP |
|------|-----|-----|
| 10 (Server) | 300秒 | 1800秒 |
| 11 (Server App) | 300秒 | 1800秒 |
| 20 (Main) | 60秒 | 300秒 |
| 30 (IoT) | 300秒 | 300秒 |
| 40 (Guest) | 60秒 | 180秒 |
| 63 (Default) | 60秒 | 300秒 |

## 管理アクセス

- **管理者ユーザー**: `admin`
- **SSH**: 有効 (すべてのVLANからアクセス可能)
- **HTTP/HTTPS**: 有効 (Digest認証)

## ファイル

- [config.txt](config.txt) - IX2215のrunning-config (完全版)

## 関連ドキュメント

- [Homelab Project Overview](../../../README.md)
- [Terraform k8s-cluster](../terraform/k8s-cluster/README.md) - VLAN 10/11を使用するProxmox VM構成
