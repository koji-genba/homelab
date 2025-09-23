# cert-manager セットアップ手順

## 前提条件
- cert-manager がクラスターにインストール済み
- Cloudflare API Token（Zone:DNS:Edit権限付与済み）
- kubectl アクセス権限

## セットアップ手順

### 1. Cloudflare Secret作成
```bash
# テンプレートをコピー
cp cloudflare-secret.yaml.template cloudflare-secret.yaml

# API Tokenを設定（YOUR_CLOUDFLARE_API_TOKEN_HERE を実際の値に置換）
sed -i 's/YOUR_CLOUDFLARE_API_TOKEN_HERE/your_actual_api_token/' cloudflare-secret.yaml

# Secret作成
kubectl apply -f cloudflare-secret.yaml

# セキュリティのためファイル削除
rm cloudflare-secret.yaml
```

### 2. ClusterIssuer作成
```bash
kubectl apply -f cluster-issuer.yaml
```

### 3. 動作確認
```bash
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-staging
```

## 代替Secret作成方法

### 環境変数使用
```bash
export CLOUDFLARE_API_TOKEN="your_token_here"
kubectl create secret generic cloudflare-api-token-secret \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  -n cert-manager
unset CLOUDFLARE_API_TOKEN
```
