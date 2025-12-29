# Kubernetesクラスタ構築（Kubespray）

KubesprayでKubernetesクラスタを自動構築します。

## クラスタ構成

- **Kubernetes**: 1.31.x
- **Container Runtime**: containerd 1.7.x
- **CNI**: Flannel (Pod CIDR: 10.0.0.0/16)
- **Proxy Mode**: IPVS (MetalLB対応)
- **Service Network**: 10.1.0.0/16

## 前提条件

- Terraform で VM が構築済み
- Python 3.x がインストール済み
- SSH 秘密鍵（~/.ssh/k8s_ed25519）
- NFSサーバー（192.168.10.11）が稼働中

## 構築手順

### 1. Kubespray リポジトリクローン

```bash
git clone https://github.com/kubernetes-sigs/kubespray.git /tmp/kubespray
cd /tmp/kubespray
```

### 2. Python 環境構築

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 3. インベントリコピー

```bash
# このリポジトリのインベントリを使用
cp -r /path/to/homelab/files/kubernetes/kubespray/inventory/mycluster inventory/
```

### 4. インベントリカスタマイズ（必要に応じて）

```bash
# ホスト設定確認
vim inventory/mycluster/hosts.yaml

# クラスタ設定確認
vim inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
# ネットワーク設定（kube_network_plugin, kube_service_addresses等）もこのファイルに含まれます
```

### 5. クラスタ構築実行

```bash
ansible-playbook -i inventory/mycluster/hosts.yaml cluster.yml \
  --become --private-key=~/.ssh/k8s_ed25519 --user=ubuntu
```

実行時間: 約15-30分（ネットワーク速度による）

### 6. kubectl 設定

```bash
# kubeconfig を取得
mkdir -p ~/.kube
scp -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.21:/etc/kubernetes/admin.conf ~/.kube/config

# パーミッション設定
chmod 600 ~/.kube/config
```

### 7. 動作確認

```bash
# ノード確認
kubectl get nodes -o wide

# 期待される出力:
# NAME            STATUS   ROLES           AGE   VERSION
# k8s-master01    Ready    control-plane   10m   v1.31.x
# k8s-worker01    Ready    <none>          10m   v1.31.x
# k8s-worker02    Ready    <none>          10m   v1.31.x

# Pod確認
kubectl get pods --all-namespaces

# クラスタ情報
kubectl cluster-info
```

## クラスタ設定のカスタマイズ

### 主要な設定ファイル

| ファイル | 説明 |
|---------|------|
| `inventory/mycluster/hosts.yaml` | ホストとロール定義 |
| `inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml` | クラスタ全体の設定（ネットワーク設定を含む） |

### パフォーマンス調整

現在の設定（[ansible.cfg](ansible.cfg)）:

```ini
[defaults]
forks = 20              # 並列実行数（高速化）
host_key_checking = False
```

## トラブルシューティング

### Ansible実行時のエラー

```bash
# SSH接続確認
ansible -i inventory/mycluster/hosts.yaml all -m ping \
  --private-key=~/.ssh/k8s_ed25519 --user=ubuntu

# 詳細ログで実行
ansible-playbook -i inventory/mycluster/hosts.yaml cluster.yml \
  --become --private-key=~/.ssh/k8s_ed25519 --user=ubuntu -vvv
```

### ノードが Ready にならない

```bash
# マスターノードで確認
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.21

# kubelet ログ確認
sudo journalctl -u kubelet -f

# containerd ログ確認
sudo journalctl -u containerd -f

# Pod ネットワーク確認
kubectl get pods -n kube-flannel
```

### kubeconfigが取得できない

```bash
# マスターノードで確認
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.21
ls -la /etc/kubernetes/admin.conf

# パーミッション確認（必要に応じて修正）
sudo chmod 644 /etc/kubernetes/admin.conf
```

### クラスタリセット（再構築時）

```bash
# 警告: クラスタ内の全データが削除されます
ansible-playbook -i inventory/mycluster/hosts.yaml reset.yml \
  --become --private-key=~/.ssh/k8s_ed25519 --user=ubuntu
```

## クラスタアップグレード

```bash
# group_vars でバージョン指定を更新
vim inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml
# kube_version: vX.XX.X  # 新しいバージョン

# アップグレード実行
ansible-playbook -i inventory/mycluster/hosts.yaml upgrade-cluster.yml \
  --become --private-key=~/.ssh/k8s_ed25519 --user=ubuntu
```

## 次のステップ

クラスタ構築後、以下のサービスをデプロイします:

1. [MetalLB（ロードバランサー）](../manifests/infrastructure/metallb/README.md)
2. [Ingress NGINX](../manifests/infrastructure/ingress-nginx/README.md)
3. [cert-manager](../manifests/infrastructure/cert-manager/setup-instructions.md)
4. [External DNS](../manifests/infrastructure/external-dns/README.md)
5. [NFS Provisioner](../manifests/storage/nfs-provisioner/README.md)

## 関連ドキュメント

- [Kubespray公式ドキュメント](https://kubespray.io/)
- [Kubernetes公式ドキュメント](https://kubernetes.io/docs/home/)
- [プロジェクトルートREADME](../../../README.md)
