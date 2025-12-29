# Tailscale Gateway構築

TerraformでProxmox VE上にTailscale VPN Gateway用のVMを構築します。

## 構築されるVM

- **tailscale-gateway**: 192.168.10.30 (サブネットルーター)

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
4. アドバタイズされたルート（192.168.10.0/24, 192.168.11.0/24）を承認

### 5. 動作確認

```bash
# VM起動確認
ssh ubuntu@192.168.10.30

# Tailscale状態確認
tailscale status

# ルーティング確認
ip route
```

## 使用方法

### 外部からのアクセス

Tailscaleクライアントをインストールしたデバイスから、ホームラボのサービスにアクセスできます。

```bash
# Sambaアクセス例（macOS/Linux）
open smb://192.168.11.103

# SSH接続例
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.21
```

## トラブルシューティング

### サブネットルートが有効にならない

```bash
# VM内でTailscale設定確認
sudo tailscale up --advertise-routes=192.168.10.0/24,192.168.11.0/24 --accept-routes

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
