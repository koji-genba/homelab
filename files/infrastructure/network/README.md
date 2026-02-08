# IX2215 Router Configuration

## 機器情報

- **機種**: NEC IX2215
- **ホスト名**: IX2215-HOME
- **バージョン**: 10.7.18

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
| 11 | 192.168.11.0/25 | Server Application | - | .100-.200 | 24時間 |
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

すべてのVLANでDHCPサーバーが有効:

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
