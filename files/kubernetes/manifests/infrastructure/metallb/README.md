# MetalLB（ロードバランサー）

ベアメタルKubernetes環境でLoadBalancerタイプのServiceを使用可能にするMetalLBのデプロイ手順です。

## 概要

- **モード**: Layer 2（ARP）
- **IPアドレスプール**: 192.168.11.100-200
- **Namespace**: metallb-system

## 前提条件

- Kubernetesクラスタが構築済み
- IPVS proxy modeが有効（Kubesprayで設定済み）
- Service VLAN 11（192.168.11.0/24）が利用可能

## デプロイ手順

### 1. Helm リポジトリ追加

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
```

### 2. MetalLB インストール

```bash
cd files/kubernetes/manifests/infrastructure/metallb/

helm install metallb metallb/metallb \
  -n metallb-system --create-namespace
```

### 3. IP アドレスプール設定

```bash
# IP Pool定義適用
kubectl apply -f ipaddresspool.yaml

# Layer 2 アドバタイズメント設定
kubectl apply -f l2advertisement.yaml
```

### 4. 動作確認

```bash
# MetalLB Pod確認
kubectl get pods -n metallb-system

# IP Pool確認
kubectl get ipaddresspool -n metallb-system

# L2Advertisement確認
kubectl get l2advertisement -n metallb-system

# 設定詳細確認
kubectl describe ipaddresspool homelab-pool -n metallb-system
```

## IP アドレス割り当て

### 現在の割り当て

| サービス | IP アドレス | 用途 |
|---------|------------|------|
| External DNS | 192.168.11.101 | DNS（Unbound + Hagezi ブロックリスト） |
| - | 192.168.11.102 | 予備 |
| Samba | 192.168.11.103 | SMB3 ファイル共有 |
| - | 192.168.11.104-200 | 予備（他のサービス用） |

注：上記以外のサービス（LDAP LDAPS、Ingress Nginx等）は自動割り当てを使用しています。

### 新規サービスへのIP割り当て

特定のIPアドレスを指定する場合、Serviceマニフェストで指定:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-namespace
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.11.104  # 固定IP指定
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: my-app
```

指定しない場合、192.168.11.100-200の範囲から自動割り当てされます。

## トラブルシューティング

### LoadBalancer IPが割り当てられない

```bash
# MetalLB Controller ログ確認
kubectl logs -n metallb-system -l component=controller

# Speaker ログ確認
kubectl logs -n metallb-system -l component=speaker

# Service状態確認
kubectl describe svc <service-name> -n <namespace>

# IPAddressPool状態確認
kubectl get ipaddresspool -n metallb-system -o yaml
```

### IP Poolが枯渇した場合

```bash
# 現在の割り当て確認
kubectl get svc --all-namespaces | grep LoadBalancer

# IPAddressPool範囲拡張（例: ~192.168.11.250まで）
kubectl edit ipaddresspool homelab-pool -n metallb-system
# addresses: 192.168.11.100-192.168.11.250 に変更
```

### ARP応答がない

Layer 2モードでは、MetalLB SpeakerがARP応答を行います。

```bash
# Speaker Pod確認（全ワーカーノードで起動）
kubectl get pods -n metallb-system -o wide

# ネットワーク確認（クライアントから）
ping 192.168.11.103

# ARP テーブル確認
arp -a | grep 192.168.11.103
```

## アンインストール

```bash
# IP Pool削除
kubectl delete -f ipaddresspool.yaml
kubectl delete -f l2advertisement.yaml

# MetalLB削除
helm uninstall metallb -n metallb-system

# Namespace削除（オプション）
kubectl delete namespace metallb-system
```

## 関連ドキュメント

- [MetalLB公式ドキュメント](https://metallb.universe.tf/)
- [Layer 2 Configuration](https://metallb.universe.tf/configuration/#layer-2-configuration)
- [プロジェクトルートREADME](../../../../../README.md)
