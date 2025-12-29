# cert-manager

KubernetesでTLS証明書を自動管理するcert-managerのデプロイおよび設定手順です。

## 概要

- **Namespace**: cert-manager
- **証明書発行**: Let's Encrypt（ACME DNS-01チャレンジ）
- **DNSプロバイダー**: Cloudflare
- **対象ドメイン**: kojigenba-srv.com

## 前提条件

- Kubernetesクラスタが構築済み
- Cloudflare API Token（Zone:DNS:Edit権限）
- kubectl アクセス権限

## デプロイ手順

### 1. cert-manager インストール

```bash
cd files/kubernetes/manifests/infrastructure/cert-manager/

kubectl apply -k .
```

cert-managerのリソース（Deployment、CRD等）がインストールされます。

### 2. Cloudflare API Token Secret 作成

以下のいずれかの方法でSecretを作成します。

#### 方法1: テンプレートファイル使用

```bash
# テンプレートをコピー
cp cloudflare-secret.yaml.template cloudflare-secret.yaml

# API Tokenを設定（YOUR_CLOUDFLARE_API_TOKEN_HERE を実際の値に置換）
sed -i '' 's/YOUR_CLOUDFLARE_API_TOKEN_HERE/<your-actual-token>/' cloudflare-secret.yaml

# Secret作成
kubectl apply -f cloudflare-secret.yaml

# セキュリティのためファイル削除
rm cloudflare-secret.yaml
```

#### 方法2: kubectl コマンドで直接作成

```bash
export CLOUDFLARE_API_TOKEN="<your-token>"
kubectl create secret generic cloudflare-api-token-secret \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  -n cert-manager
unset CLOUDFLARE_API_TOKEN
```

### 3. ClusterIssuer 作成

```bash
kubectl apply -f cluster-issuer.yaml
```

以下の2つのClusterIssuerが作成されます:
- `letsencrypt-staging`: テスト用（レート制限緩和）
- `letsencrypt-prod`: 本番用

### 4. 動作確認

```bash
# cert-manager Pod確認
kubectl get pods -n cert-manager

# ClusterIssuer確認
kubectl get clusterissuer

# 期待される出力:
# NAME                  READY   AGE
# letsencrypt-staging   True    <time>
# letsencrypt-prod      True    <time>

# ClusterIssuer詳細確認
kubectl describe clusterissuer letsencrypt-prod
```

## 使用方法

### Ingressでの証明書自動発行

Ingressリソースにアノテーションを追加することで、自動的にTLS証明書が発行されます。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # 本番用証明書発行
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - example.kojigenba-srv.com
    secretName: example-tls  # cert-managerが自動生成
  rules:
  - host: example.kojigenba-srv.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: example-service
            port:
              number: 80
```

### テスト時はStagingを使用

本番前のテストには`letsencrypt-staging`を使用してください（レート制限回避）。

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
```

### 手動でCertificateリソース作成

Ingress以外で証明書が必要な場合、Certificateリソースを直接作成できます。

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-cert
  namespace: my-namespace
spec:
  secretName: example-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - example.kojigenba-srv.com
  - www.example.kojigenba-srv.com
```

## 証明書管理

### 証明書一覧確認

```bash
# Certificate リソース確認
kubectl get certificate -A

# 特定Namespace内
kubectl get certificate -n <namespace>

# 詳細情報
kubectl describe certificate <cert-name> -n <namespace>
```

### 証明書の状態確認

```bash
# Certificate詳細（Ready状態を確認）
kubectl get certificate <cert-name> -n <namespace> -o yaml

# 証明書Secret確認
kubectl get secret <secret-name> -n <namespace>

# 証明書の有効期限確認
kubectl get certificate <cert-name> -n <namespace> -o jsonpath='{.status.notAfter}'
```

### 証明書の手動更新

cert-managerは自動的に証明書を更新しますが、手動で強制更新することも可能です。

```bash
# Certificateリソースを削除して再作成
kubectl delete certificate <cert-name> -n <namespace>
# Ingressの場合は自動的に再作成される

# または、annotationで強制更新
kubectl annotate certificate <cert-name> -n <namespace> \
  cert-manager.io/issue-temporary-certificate="true" --overwrite
```

## トラブルシューティング

### 証明書が発行されない

```bash
# Certificate状態確認
kubectl get certificate -n <namespace>

# Certificate詳細確認（Eventsセクションに注目）
kubectl describe certificate <cert-name> -n <namespace>

# CertificateRequest確認
kubectl get certificaterequest -n <namespace>
kubectl describe certificaterequest <request-name> -n <namespace>

# Order確認（ACME Challenge詳細）
kubectl get order -n <namespace>
kubectl describe order <order-name> -n <namespace>

# Challenge確認（DNS-01チャレンジ詳細）
kubectl get challenge -n <namespace>
kubectl describe challenge <challenge-name> -n <namespace>
```

### cert-manager ログ確認

```bash
# cert-manager controller ログ
kubectl logs -n cert-manager -l app=cert-manager --tail=100 -f

# webhook ログ
kubectl logs -n cert-manager -l app=webhook --tail=100

# cainjector ログ
kubectl logs -n cert-manager -l app=cainjector --tail=100
```

### Cloudflare API認証エラー

```bash
# Secret確認
kubectl get secret cloudflare-api-token-secret -n cert-manager

# Secret内容確認（Base64デコード）
kubectl get secret cloudflare-api-token-secret -n cert-manager \
  -o jsonpath='{.data.api-token}' | base64 -d

# ClusterIssuer確認
kubectl describe clusterissuer letsencrypt-prod
```

Cloudflare API Tokenの権限を確認:
- Zone: DNS: Edit 権限が必要
- 対象ドメイン（kojigenba-srv.com）が含まれているか確認

### DNS-01 チャレンジ失敗

```bash
# Challenge詳細確認
kubectl describe challenge <challenge-name> -n <namespace>

# DNS TXTレコード確認（外部から）
dig _acme-challenge.example.kojigenba-srv.com TXT

# Cloudflare側でDNSレコード確認
# → Cloudflareダッシュボードで _acme-challenge レコードが存在するか確認
```

### レート制限エラー

Let's Encrypt本番環境には[レート制限](https://letsencrypt.org/docs/rate-limits/)があります。

テスト時は`letsencrypt-staging`を使用してください:

```bash
# Ingress annotationを変更
kubectl annotate ingress <ingress-name> -n <namespace> \
  cert-manager.io/cluster-issuer=letsencrypt-staging --overwrite

# 既存Certificateを削除して再発行
kubectl delete certificate <cert-name> -n <namespace>
```

## 設定ファイル

| ファイル | 説明 |
|---------|------|
| [kustomization.yaml](kustomization.yaml) | cert-manager公式マニフェストを参照 |
| [cluster-issuer.yaml](cluster-issuer.yaml) | Let's Encrypt ClusterIssuer定義（Staging/Production） |
| [cloudflare-secret.yaml.template](cloudflare-secret.yaml.template) | Cloudflare API Token Secret テンプレート |

## アンインストール

```bash
# ClusterIssuer削除
kubectl delete -f cluster-issuer.yaml

# Secret削除
kubectl delete secret cloudflare-api-token-secret -n cert-manager

# cert-manager削除
kubectl delete -k .
```

注: 証明書を使用しているIngressやアプリケーションが存在する場合、事前に削除または設定変更してください。

## 関連ドキュメント

- [cert-manager公式ドキュメント](https://cert-manager.io/docs/)
- [ACME DNS-01チャレンジ](https://cert-manager.io/docs/configuration/acme/dns01/)
- [Cloudflare DNS Provider](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [Ingress NGINX README](../ingress-nginx/README.md)
- [プロジェクトルートREADME](../../../../../README.md)
