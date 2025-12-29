# Ingress NGINX

HTTP/HTTPSトラフィックのルーティングとSSL終端を行うIngress Controllerのデプロイ手順です。

## 概要

- **Namespace**: ingress-nginx
- **LoadBalancer IP**: MetalLBから自動割り当て（詳細は[MetalLB README](../metallb/README.md)参照）
- **SSL/TLS**: cert-managerと統合

## 前提条件

- Kubernetesクラスタが構築済み
- MetalLBがデプロイ済み

## デプロイ手順

### 1. Kustomizeでデプロイ

```bash
cd files/kubernetes/manifests/infrastructure/ingress-nginx/

kubectl apply -k .
```

### 2. 動作確認

```bash
# Pod状態確認
kubectl get pods -n ingress-nginx

# Service確認（LoadBalancer IPを確認）
kubectl get svc -n ingress-nginx

# 期待される出力:
# NAME                                 TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)
# ingress-nginx-controller             LoadBalancer   10.1.x.x       192.168.11.xxx   80:xxxxx/TCP,443:xxxxx/TCP

# Ingress Class確認
kubectl get ingressclass
```

### 3. LoadBalancer IP取得

```bash
export INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Ingress Controller IP: $INGRESS_IP"
```

## 使用方法

### 基本的なIngressリソース

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - example.kojigenba-srv.com
    secretName: example-tls
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

### cert-manager統合（TLS自動発行）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-example-ingress
  namespace: my-namespace
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production  # cert-manager連携
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"  # HTTP→HTTPS自動リダイレクト
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - secure.kojigenba-srv.com
    secretName: secure-tls  # cert-managerが自動生成
  rules:
  - host: secure.kojigenba-srv.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: backend-service
            port:
              number: 8080
```

### パスベースルーティング

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-based-ingress
  namespace: my-namespace
spec:
  ingressClassName: nginx
  rules:
  - host: app.kojigenba-srv.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-service
            port:
              number: 8080
      - path: /web
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

## カスタマイズ

### タイムアウト設定

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "60"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
```

### リライトルール

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  rules:
  - host: example.com
    http:
      paths:
      - path: /app(/|$)(.*)
        pathType: Prefix
        backend:
          service:
            name: app-service
            port:
              number: 80
```

### アップロードサイズ制限

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "100m"
```

## トラブルシューティング

### Ingressが機能しない

```bash
# Ingress Controller ログ確認
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100 -f

# Ingress詳細確認
kubectl describe ingress <ingress-name> -n <namespace>

# Backendサービス確認
kubectl get endpoints <service-name> -n <namespace>
```

### 502 Bad Gateway エラー

```bash
# バックエンドPod確認
kubectl get pods -n <namespace> -l app=<app-label>

# サービス確認
kubectl get svc <service-name> -n <namespace>

# エンドポイント確認（Podが正しく登録されているか）
kubectl get endpoints <service-name> -n <namespace>
```

### 証明書が発行されない

cert-managerと統合している場合:

```bash
# Certificate確認
kubectl get certificate -n <namespace>

# cert-managerログ確認
kubectl logs -n cert-manager -l app=cert-manager --tail=100

# Ingress annotationを確認
kubectl get ingress <ingress-name> -n <namespace> -o yaml | grep cert-manager
```

詳細は[cert-manager セットアップ手順](../cert-manager/setup-instructions.md)を参照。

### LoadBalancer IPが割り当てられない

```bash
# MetalLB確認
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l component=controller

# Service確認
kubectl describe svc ingress-nginx-controller -n ingress-nginx
```

詳細は[MetalLB README](../metallb/README.md)を参照。

## ログ確認

### アクセスログ

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100 -f
```

### デバッグモード有効化

```bash
# ConfigMap編集
kubectl edit configmap ingress-nginx-controller -n ingress-nginx

# 以下を追加:
data:
  error-log-level: debug
```

## アンインストール

```bash
kubectl delete -k .
```

## 関連ドキュメント

- [NGINX Ingress Controller公式ドキュメント](https://kubernetes.github.io/ingress-nginx/)
- [Ingress Annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/)
- [プロジェクトルートREADME](../../../../../README.md)
