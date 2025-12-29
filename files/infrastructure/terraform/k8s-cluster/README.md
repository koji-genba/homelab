# Kubernetes Cluster VM構築

TerraformでProxmox VE上にKubernetesクラスタ用のVMを構築します。

## 構築されるVM

- **k8s-master01**: 192.168.10.21, 192.168.11.21 (2 cores, 6GB RAM, 50GB disk)
- **k8s-worker01**: 192.168.10.22, 192.168.11.22 (2 cores, 4GB RAM, 40GB disk)
- **k8s-worker02**: 192.168.10.23, 192.168.11.23 (2 cores, 4GB RAM, 40GB disk)

## 前提条件

- Proxmox VE環境（192.168.10.11）
- SSHキーペア（~/.ssh/k8s_ed25519）
- Proxmox APIアクセス権限

## 構築手順

### 1. 設定ファイル作成

```bash
cd files/infrastructure/terraform/k8s-cluster/

# 設定ファイルをテンプレートからコピー
cp terraform.tfvars.example terraform.tfvars

# Proxmox認証情報とSSH公開鍵を設定
vim terraform.tfvars
```

### 2. Terraform実行

#### 対話型セットアップスクリプト

```bash
./setup.sh
```

#### 手動実行

```bash
terraform init
terraform plan
terraform apply
```

### 3. 動作確認

```bash
# VM一覧確認（Proxmox Web UIまたはCLI）
pvesh get /cluster/resources --type vm

# SSH接続テスト
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.21
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.22
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.23
```

## トラブルシューティング

### VM作成が失敗する

```bash
# Terraformログ確認
terraform apply -debug

# Proxmoxタスクログ確認（Proxmox Web UI）
# Datacenter > Tasks
```

### SSH接続できない

```bash
# VM起動確認
pvesh get /nodes/proxmox/qemu/<vmid>/status/current

# ネットワーク確認
ping 192.168.10.21

# SSH鍵権限確認
chmod 600 ~/.ssh/k8s_ed25519
```

## 関連ドキュメント

- [Terraform Proxmox Provider Documentation](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- [プロジェクトルートREADME](../../../../README.md)
