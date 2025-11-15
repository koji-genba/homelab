# OpenLDAP Deployment

Kubernetes上のOpenLDAP（Samba統合対応）

## 前提条件

- cert-manager導入済み
- NFSストレージクラス（`nfs-k8s-volumes`）利用可能
- ローカルにDocker環境

## デプロイ手順

### 1. Dockerイメージビルド & プッシュ

#### OpenLDAP イメージ

```bash
cd files/kubernetes/manifests/infrastructure/ldap/docker
docker build -t ghcr.io/koji-genba/openldap:v1 .

# ghcr.io にプッシュ
docker push ghcr.io/koji-genba/openldap:v1
```

#### phpLDAPadmin イメージ

```bash
cd files/kubernetes/manifests/infrastructure/ldap/docker/phpadmin
docker build -t ghcr.io/koji-genba/phpldapadmin:v1.2 .

# ghcr.io にプッシュ
docker push ghcr.io/koji-genba/phpldapadmin:v1.2
```

**注**: 公式イメージ `leenooks/phplaadmin` をベースにしているため、Docker Hub へのアクセスが必要です。

**注**: Kubernetes は `imagePullPolicy: IfNotPresent` で両イメージを参照するため、ghcr.io に存在する必要があります。

### 2. Namespace作成（先に実施）

```bash
cd files/kubernetes/manifests/infrastructure/ldap
kubectl apply -f namespace.yaml
```

### 3. Secret生成

```bash
# スクリプト実行（プロジェクトルートから）
scripts/generate-ldap-secrets.sh

# プロンプトに従ってパスワード入力
# - admin_password: cn=admin,dc=...用
# - config_password: rootpw用
# - admin_user_password: admin-user用

# 生成されたSecretを適用（namespace が存在する状態）
kubectl apply -f files/kubernetes/manifests/infrastructure/ldap/secret.yaml
```

### 4. ConfigMap 設定（phpLDAPadmin）

phpLDAPadmin は `.env` ファイルから設定を読み込みます。

```bash
# ConfigMap を適用
cd files/kubernetes/manifests/infrastructure/ldap
kubectl apply -f configmap-phpadmin.yaml
```

**注**: パスワードを変更する場合は、`configmap-phpadmin.yaml` の `LDAP_PASSWORD` を編集してから適用してください。

### 5. デプロイ

```bash
cd files/kubernetes/manifests/infrastructure/ldap
./deploy.sh
```

または個別にデプロイ：

```bash
# OpenLDAP と phpLDAPadmin をデプロイ
kubectl apply -f deployment.yaml
kubectl apply -f service-ldap.yaml
kubectl apply -f service-ldaps.yaml
kubectl apply -f service-phpadmin.yaml
kubectl apply -f deployment-phpadmin.yaml
kubectl apply -f ingress.yaml
```

## 動作確認

### LDAP接続テスト

```bash
# Podに接続
kubectl exec -it -n openldap deployment/openldap -- bash

# LDAP検索
ldapsearch -x -H ldap://localhost:389 \
  -D "cn=admin,dc=kojigenba-srv,dc=com" \
  -W \
  -b "dc=kojigenba-srv,dc=com" \
  -LLL

# Sambaユーザ確認
ldapsearch -x -H ldap://localhost:389 \
  -D "cn=admin,dc=kojigenba-srv,dc=com" \
  -W \
  -b "dc=kojigenba-srv,dc=com" \
  "(objectClass=sambaSamAccount)"
```

### LDAPS接続テスト

```bash
ldapsearch -x -H ldaps://ldap.kojigenba-srv.com:636 \
  -D "cn=admin,dc=kojigenba-srv,dc=com" \
  -W \
  -b "dc=kojigenba-srv,dc=com" \
  -LLL
```

## トラブルシューティング

### ログ確認

```bash
# OpenLDAPログ
kubectl logs -n openldap deployment/openldap

# phpLDAPadmin ログ
kubectl logs -n openldap deployment/phpadmin

# Bootstrap jobログ
kubectl logs -n openldap job/openldap-bootstrap
```

### Secret確認

```bash
kubectl get secret openldap-secrets -n openldap -o yaml
```

### 再デプロイ

```bash
# データを保持したまま再デプロイ
kubectl delete deployment openldap -n openldap
kubectl apply -f deployment.yaml

# 完全クリーン
./deploy.sh --clean
```

## ログレベル変更

初期構築完了後、deployment.yamlのCMDを変更：

```yaml
# 詳細ログ（初期構築）
exec slapd -d 481 ...

# 標準ログ（安定稼働後）
exec slapd -d 256 ...
```

## アーキテクチャ

- **Base DN**: `dc=kojigenba-srv,dc=com`
- **Admin DN**: `cn=admin,dc=kojigenba-srv,dc=com`
- **People OU**: `ou=people,dc=kojigenba-srv,dc=com`
- **Groups OU**: `ou=groups,dc=kojigenba-srv,dc=com`
- **Domain SID**: `S-1-5-21-3623811015-3361044348-30300820`

## セキュリティ

### 機密情報の管理

- **Kubernetes Secret**: パスワードハッシュは `secret.yaml` で管理（`.gitignore` で除外）
- **ConfigMap**: phpLDAPadmin の `.env` は `configmap-phpadmin.yaml` で管理（`.gitignore` で除外）
- **テンプレート**: `.template` 拡張子のファイルはリポジトリに含める
  - `secret.yaml.template` - OpenLDAP secret テンプレート
  - `configmap-phpadmin.yaml.template` - phpLDAPadmin configmap テンプレート

### デプロイ時の手順

1. テンプレートからコピー
   ```bash
   cp configmap-phpadmin.yaml.template configmap-phpadmin.yaml
   cp secret.yaml.template secret.yaml  # 既に存在する場合
   ```

2. 機密情報を編集
   ```bash
   # configmap-phpadmin.yaml で LDAP_PASSWORD を実際のパスワードに変更
   vi configmap-phpadmin.yaml
   ```

3. Kubernetes に適用
   ```bash
   kubectl apply -f secret.yaml
   kubectl apply -f configmap-phpadmin.yaml
   ```

### Git 管理

公開リポジトリ使用時は、以下が `.gitignore` で除外されます：
- `secret.yaml` - Kubernetes Secret マニフェスト
- `configmap-phpadmin.yaml` - phpLDAPadmin ConfigMap マニフェスト

パスワードやトークンは絶対に commit しないでください。
