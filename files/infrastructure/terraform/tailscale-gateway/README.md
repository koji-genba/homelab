# Tailscale Gateway構築

TerraformでProxmox VE上にTailscale VPN Gateway用のVMを構築します。

## 構築されるVM

- **tailscale-gateway**: 192.168.10.102（サブネットルーター、VMID 102）
- CPU: 2 cores / メモリ: 4096 MB / ディスク: 20 GB（`vmpool`）
- Template: `template_vm_id`（default: 9000）からfull clone

PVE上のVM名とguest hostnameは`tailscale-gateway`です。tailnet hostnameは手動登録時に指定する
`home-gateway`で、両者を区別します。数値は[main.tf](main.tf) / [variables.tf](variables.tf)の定義です。

IPは`ip_address`変数で管理する。2026-09-12に`.30`から`.102`へ変更した。PVEのcloud-init設定を変えると
instance-idが変わるため、`reboot_after_update = true`による再起動後にcloud-initがnetplanを描き直し、
guestの実IPが切り替わる。再起動でSSH host鍵が作り直される点に注意する。

## 前提条件

- Proxmox VE環境（192.168.10.11）
- Tailscaleアカウント
- SSHキーペア
- Cloud-init対応のVMテンプレート（VMID 9000、現存は別途確認）

## 構築手順

以下はTerraformの定義と`outputs.tf`の案内に基づく手順です。

### 1. 設定ファイル作成

```bash
cd files/infrastructure/terraform/tailscale-gateway/

# 設定ファイルをテンプレートからコピー
cp terraform.tfvars.example terraform.tfvars

# Proxmox接続情報とSSH公開鍵を設定
vim terraform.tfvars
```

`proxmox_endpoint` / `proxmox_username` / `proxmox_password`でProxmoxへ接続し、`ssh_public_key`を
guestへ配置します。[provider](providers.tf)はAPIとProxmox SSHにpasswordを使います。
このルートにはTailscale認証キーの変数はなく、TerraformはTailscaleのinstallと`tailscaled`の起動までを行います。

### 2. Terraform実行

```bash
terraform init
terraform plan
terraform apply
```

### 3. guest内でTailscale登録

[outputs.tf](outputs.tf)が案内する次のコマンドをguest内で実行し、認証を完了します。

```bash
ssh ubuntu@192.168.10.102
sudo tailscale up --advertise-exit-node --advertise-routes=192.168.10.0/24 --accept-dns=false --hostname=home-gateway
tailscale status
```

### 4. device確認とルート承認

登録後にTailscale Admin Consoleでdeviceを確認し、サブネットルートとexit nodeを承認します。

1. [Tailscale Admin Console](https://login.tailscale.com/admin/machines)にアクセス
2. tailnet hostname `home-gateway`のdeviceが作成したVMに対応することを確認して選択
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

## Terraform state

active stateはこのルートのlocal `terraform.tfstate`で、Git ignore対象です。
このルートはraw `terraform apply`で実行し、state backupを呼ばないため、成功後にrepository rootで
このルートのstateも収集する`make state-backup`を実行します。
backup / restoreの仕組みと前提は[ADR-0005](../../../../docs/adr/0005-secrets-and-terraform-state.md)と
[state-backup.sh](../../../../scripts/state-backup.sh) / [state-restore.sh](../../../../scripts/state-restore.sh)を参照してください。

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

ElastiFlow UIは例外として `https://elastiflow.kojigenba-srv.com` からApps VMのCaddy経由でも利用でき、
gateway exit nodeに依存しない（[ADR-0009](../../../../docs/adr/0009-elastiflow-caddy-fqdn.md)）。
ElastiFlow VMへのSSHや直IPのLANアクセスには従来の経路を使う。

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

# UFWを別途導入している場合だけ確認（Terraformは導入しない）
sudo ufw status
```

## 関連ドキュメント

- [Tailscale Subnet Routers](https://tailscale.com/kb/1019/subnets/)
- [tailnet側のTerraform管理](../tailscale/README.md)
- [プロジェクトルートREADME](../../../../README.md)
