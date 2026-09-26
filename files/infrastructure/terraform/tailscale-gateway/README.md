# Tailscale Gateway構築

TerraformでProxmox VE上にTailscale VPN Gateway用のVMを構築します。

## 構築されるVM

- **tailscale-gateway**: 192.168.10.102（サブネットルーター）

IPは`ip_address`変数で管理する。2026-09-12に`.30`から`.102`へ変更した。PVEのcloud-init設定を変えると
instance-idが変わるため、`reboot_after_update = true`による再起動後にcloud-initがnetplanを描き直し、
guestの実IPが切り替わる。再起動でSSH host鍵が作り直される点に注意する。

## 前提条件

- Proxmox VE環境（192.168.10.11）
- Tailscaleアカウント
- Tailscale認証キー（Auth Key）
- SSHキーペア

## 構築手順

### 1. Tailscale認証キー取得

1. [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)にアクセス
2. 新しい認証キーを生成
3. オプション：
   - Reusable: 有効化（複数回使用可能）
   - Ephemeral: 無効化（永続的なデバイス）
   - Preauthorized: 有効化（自動承認）

### 2. 設定ファイル作成

```bash
cd files/infrastructure/terraform/tailscale-gateway/

# 設定ファイルをテンプレートからコピー
cp terraform.tfvars.example terraform.tfvars

# Proxmox認証情報とTailscale認証キーを設定
vim terraform.tfvars
```

### 3. Terraform実行

```bash
terraform init
terraform plan
terraform apply
```

### 4. サブネットルーター設定

VMが起動したら、Tailscale Admin Consoleでサブネットルーターを有効化します。

1. [Tailscale Admin Console](https://login.tailscale.com/admin/machines)にアクセス
2. tailscale-gatewayデバイスを選択
3. "Edit route settings"をクリック
4. アドバタイズされたルート（192.168.10.0/24）とexit nodeを承認

### 5. 動作確認

```bash
# VM起動確認
ssh ubuntu@192.168.10.102

# Tailscale状態確認
tailscale status

# ルーティング確認
ip route
```

## 使用方法

### 外部からのアクセス

Apps VMは自身がtailnet node（`tag:apps`、`100.86.147.127`）であり、内部名は100.xへ解決される。
Apps VMのserviceへはgatewayを経由せず、名前で接続する（[ADR-0007](../../../../docs/adr/0007-apps-vm-tailnet-dns.md)）。

```bash
# Sambaアクセス例（macOS/Linux）
open smb://samba.kojigenba-srv.com

# SSH接続例（MagicDNS名またはtailnet IP）
ssh deploy@apps
```

gatewayの役割はexit nodeと、exit node経由でApps VM以外のLAN機器（PVE、IX2215、ElastiFlow）へ
入ることである。宅外からこれらの管理画面を使うときはexit nodeを有効にする。

### `192.168.10.0/24`の広告を外さない

exit nodeは、自身が接続するLANをsubnet routeとして広告しない限り、そのLANへ転送しない
（Tailscaleの仕様。default routeを提供するnodeはlocal LANを"guest wifi"としてfilterする）。
2026-09-26に広告を外すと、exit node経由でPVE、IX2215、ElastiFlowへ届かなくなることを確認した。
AdvertiseRoutesは`0.0.0.0/0`、`::/0`、`192.168.10.0/24`を維持する
（`sudo tailscale set --advertise-exit-node --advertise-routes=192.168.10.0/24`）。
prefsの宣言的管理は[#29](https://github.com/koji-genba/homelab/issues/29)で扱う。

## トラブルシューティング

### サブネットルートが有効にならない

```bash
# VM内でTailscale設定確認
sudo tailscale up --advertise-exit-node --advertise-routes=192.168.10.0/24 --accept-dns=false --hostname=home-gateway

# Admin Consoleでルート承認状態確認
```

### 接続できない

```bash
# Tailscale接続状態確認
tailscale status

# IPフォワーディング確認
sysctl net.ipv4.ip_forward
# 出力が "net.ipv4.ip_forward = 1" であることを確認

# ファイアウォール確認
sudo ufw status
```

## 関連ドキュメント

- [Tailscale Subnet Routers](https://tailscale.com/kb/1019/subnets/)
- [プロジェクトルートREADME](../../../../README.md)
