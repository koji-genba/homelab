# Homelab 


自宅ラボ環境のKubernetesクラスタとインフラストラクチャのための、TerraformやKubespray、その他定義ファイル。

## システム構成

### ネットワークアーキテクチャ

```
Management VLAN 10 (192.168.10.0/24)
├── Proxmox VE Host: 192.168.10.11
├── k8s-master01: 192.168.10.21
├── k8s-worker01: 192.168.10.22
├── k8s-worker02: 192.168.10.23
└── tailscale-gateway: 192.168.10.30

Service VLAN 11 (192.168.11.0/24)
├── k8s-master01: 192.168.11.21
├── k8s-worker01: 192.168.11.22
├── k8s-worker02: 192.168.11.23
└── MetalLB LoadBalancer Pool: 192.168.11.100-200
    ├── Samba: 192.168.11.103 (TCP 445)
    └── その他サービス用予約IPアドレス

Kubernetes Internal Networks
├── Pod Network (Flannel): 10.0.0.0/16
└── Service Network: 10.1.0.0/16
```

### Kubernetesサービスフロー

```
外部アクセス
    ↓
Tailscale VPN Gateway (192.168.10.30)
    ↓
MetalLB LoadBalancer (192.168.11.100-200)
    ↓
Nginx Ingress Controller (SSL終端)
    ↓
Kubernetes Services
    ├── OpenLDAP (ldap://openldap.openldap.svc:389)
    ├── Samba (smb://192.168.11.103:445)
    ├── External DNS (dns://192.168.11.101:53)
    └── その他アプリケーション
```

### ストレージ構成

```
NFS Server (192.168.10.11)
├── /tank-gen2/data/k8s-volumes # 動的PV (NFS Provisioner)
├── /tank-gen2/data/shared  # Samba共有ストレージ (4TB)
└── /tank-gen1/data/archive # Sambaアーカイブストレージ (6TB)
```

## 技術スタック

### Infrastructure Layer

| コンポーネント | バージョン | 用途 |
|---------------|-----------|------|
| **Proxmox VE** | 8.x | ホスト仮想化プラットフォーム |
| **Terraform** | >= 1.0 | Infrastructure as Code ([設定](files/infrastructure/terraform/k8s-cluster/providers.tf)) |
| **Proxmox Provider** | ~> 0.81 | Proxmox API連携 |
| **Kubespray** | Latest | Kubernetes自動構築（Ansible） |
  
### Kubernetes Platform

| コンポーネント | バージョン | 用途 |
|---------------|-----------|------|
| **Kubernetes** | 1.31.x | コンテナオーケストレーション ([詳細設定](files/kubernetes/kubespray/inventory/mycluster/group_vars/k8s-cluster/k8s-cluster.yml)) |
| **containerd** | 1.7.x | コンテナランタイム |
| **Flannel** | Latest | Pod間ネットワーキング（CNI） |
| **IPVS** | - | Kubernetesプロキシモード |

### Infrastructure Services

| サービス | Namespace | 用途 |
|---------|-----------|------|
| **MetalLB** | metallb-system | ベアメタルLoadBalancer（Layer 2） |
| **Nginx Ingress** | ingress-nginx | HTTP/HTTPSルーティング |
| **cert-manager** | cert-manager | Let's Encrypt証明書自動発行（Cloudflare DNS-01） ([マニフェスト](files/kubernetes/manifests/infrastructure/cert-manager/)) |
| **External DNS** | external-dns | Unbound DNSサーバー + Hageziブロックリスト |
| **NFS Provisioner** | default | 動的ストレージプロビジョニング |

### Application Services

| サービス | Namespace | 用途 | LoadBalancer IP |
|---------|-----------|------|-----------------|
| **OpenLDAP** | openldap | ディレクトリサービス（認証・認可） | LoadBalancer (LDAPS:636) |
| **phpLDAPadmin** | openldap | LDAP管理WebUI | (ingress) |
| **Samba** | samba | SMB3ファイル共有（LDAP統合） | 192.168.11.103 |

### External Services

| サービス | 用途 |
|---------|------|
| **Tailscale Gateway** | 外部ネットワークアクセス（サブネットルーター） |
| **Cloudflare DNS** | DNS-01 Challenge用（cert-manager） |

## ディレクトリ構造

```
homelab/
├── files/
│   ├── infrastructure/
│   │   ├── terraform/              # VMの定義
│   │   │   ├── k8s-cluster/        # Kubernetesクラスタ用VM構築
│   │   │   └── tailscale-gateway/  # VPN Gateway用VM構築
│   │   └── network/                # ネットワーク機器設定 (IX2215)
│   └── kubernetes/
│       ├── kubespray/              # Kubernetesクラスタ自動構築（Ansible）
│       │   ├── ansible.cfg
│       │   └── inventory/mycluster/
│       └── manifests/              # Kubernetes Manifests
│           ├── infrastructure/     # インフラ系
│           │   ├── metallb/        # LoadBalancer (Layer 2)
│           │   ├── ingress-nginx/  # Ingress Controller
│           │   ├── cert-manager/   # TLS証明書管理
│           │   ├── external-dns/   # イントラ向けDNSサーバー (Unbound)
│           │   └── ldap/           # 認証基盤 (OpenLDAP + phpLDAPadmin)
│           ├── storage/            # ストレージプロビジョニング
│           │   └── nfs-provisioner/
│           └── applications/       # アプリケーション
│               ├── samba/          # ファイル共有 (LDAP統合)
│               └── test-apps/      # テスト用アプリケーション
└── README.md
```

## 構築手順

### 前提条件

- Proxmox VE環境（192.168.10.11）
- NFSサーバー（192.168.10.11）
- Cloudflare DNSアカウント（cert-manager用）
- SSHキーペア（~/.ssh/k8s_ed25519）

### 1. インフラストラクチャ構築

#### 1.1 Kubernetes VM構築

TerraformでProxmox VE上にKubernetesクラスタ用のVMを構築します。

詳細は [Terraform k8s-cluster README](files/infrastructure/terraform/k8s-cluster/README.md) を参照してください。

**構築されるVM**:
- k8s-master01: 192.168.10.21, 192.168.11.21 (2 cores, 6GB RAM, 50GB disk)
- k8s-worker01: 192.168.10.22, 192.168.11.22 (2 cores, 4GB RAM, 40GB disk)
- k8s-worker02: 192.168.10.23, 192.168.11.23 (2 cores, 4GB RAM, 40GB disk)

#### 1.2 Tailscale Gateway構築（オプション）

外部からホームラボへのセキュアなアクセスを提供するVPN Gatewayを構築します。

詳細は [Terraform tailscale-gateway README](files/infrastructure/terraform/tailscale-gateway/README.md) を参照してください。

### 2. Kubernetesクラスタ構築

Kubespray（Ansible）でKubernetesクラスタを自動構築します。

詳細は [Kubespray README](files/kubernetes/kubespray/README.md) を参照してください。

**クラスタ構成**:
- Kubernetes 1.31.x
- containerd 1.7.x
- Flannel CNI (Pod CIDR: 10.0.0.0/16)
- IPVS proxy mode (MetalLB対応)

### 3. 基盤サービスデプロイ

#### 3.1 MetalLB（LoadBalancer）

ベアメタル環境でLoadBalancerタイプのServiceを使用可能にします。

詳細は [MetalLB README](files/kubernetes/manifests/infrastructure/metallb/README.md) を参照してください。

#### 3.2 Ingress NGINX

HTTP/HTTPSトラフィックのルーティングとSSL終端を提供します。

詳細は [Ingress NGINX README](files/kubernetes/manifests/infrastructure/ingress-nginx/README.md) を参照してください。

#### 3.3 cert-manager

Let's Encrypt証明書の自動発行・更新を行います。

詳細手順は [setup-instructions.md](files/kubernetes/manifests/infrastructure/cert-manager/setup-instructions.md) を参照してください。

#### 3.4 External DNS

イントラネット向けDNSサーバー（Unbound）とHageziブロックリストを提供します。

詳細は [External DNS README](files/kubernetes/manifests/infrastructure/external-dns/README.md) を参照してください。

**機能**:
- Unbound DNSサーバー
- Hageziブロックリスト
- カスタムDNSゾーン対応

### 4. ストレージ構成

NFSサーバーを使用した動的PersistentVolumeプロビジョニングを提供します。

詳細は [NFS Provisioner README](files/kubernetes/manifests/storage/nfs-provisioner/README.md) を参照してください。

**設定**:
- NFS Server: 192.168.10.11
- Export Path: /tank-gen2/data/k8s-volumes
- StorageClass: nfs-k8s-volumes (default)
- Reclaim Policy: Retain

### 5. アプリケーション

#### 5.1 OpenLDAP（Identity Management）

LDAP認証基盤を提供します。

詳細は [ldap/README.md](files/kubernetes/manifests/infrastructure/ldap/README.md) を参照してください。

#### 5.2 Samba

OpenLDAP統合のSMB3ファイル共有サービスを提供します。

詳細は [samba/README.md](files/kubernetes/manifests/applications/samba/README.md) を参照してください。

**共有設定**:
- [shared]: NFS: 192.168.10.11:/tank-gen2/data/shared
- [archive]: NFS: 192.168.10.11:/tank-gen1/data/archive
- 認証: OpenLDAP ldapsam backend
- アクセス: samba-users グループメンバー
