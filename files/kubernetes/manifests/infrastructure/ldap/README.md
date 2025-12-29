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
docker build -t ghcr.io/koji-genba/openldap:<version> .

# ghcr.io にプッシュ（適宜バージョンを変更）
docker push ghcr.io/koji-genba/openldap:<version>
```

#### phpLDAPadmin イメージ

```bash
cd files/kubernetes/manifests/infrastructure/ldap/docker/phpadmin
docker build -t ghcr.io/koji-genba/phpldapadmin:<version> .

# ghcr.io にプッシュ（適宜バージョンを変更）
docker push ghcr.io/koji-genba/phpldapadmin:<version>
```

**注**: 公式イメージ `leenooks/phplaadmin` をベースにしているため、Docker Hub へのアクセスが必要です。

**注**: OpenLDAPイメージは `imagePullPolicy: IfNotPresent` で参照されます。phpLDAPadminイメージは `Always` でプルされます。いずれもghcr.ioに存在する必要があります。

### 2. Namespace作成（先に実施）

```bash
cd files/kubernetes/manifests/infrastructure/ldap
kubectl apply -f namespace.yaml
```

### 3. Secret生成

**推奨: 統合スクリプトを使用**

```bash
# 全設定ファイルを一括生成（推奨）
scripts/generate-all.sh

# プロンプトに従ってLDAP管理パスワードを入力:
# - admin_password: cn=admin,dc=...用
# - config_password: rootpw用
# ユーザーパスワードは openldap/bootstrap/user-configs/*.json から自動読み込み

# 生成されたSecretを適用（namespace が存在する状態）
chmod 600 secret.yaml
kubectl apply -f secret.yaml
```

**または: Secret のみ生成**

```bash
# Secretのみ生成する場合
scripts/generate-user-secrets.sh

# 生成されたSecretを適用
chmod 600 secret.yaml
kubectl apply -f secret.yaml
```

### 4. ConfigMap 設定（phpLDAPadmin）

phpLDAPadmin は `.env` ファイルから設定を読み込みます。

```bash
# ConfigMap を適用
cd files/kubernetes/manifests/infrastructure/ldap
kubectl apply -f phpldapadmin/configmap-phpadmin.yaml
```

**注**: パスワードを変更する場合は、`phpldapadmin/configmap-phpadmin.yaml` の `LDAP_PASSWORD` を編集してから適用してください。

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
ldapsearch -x -H ldaps://ldaps.kojigenba-srv.com:636 \
  -D "cn=admin,dc=kojigenba-srv,dc=com" \
  -W \
  -b "dc=kojigenba-srv,dc=com" \
  -LLL
```

## ユーザー・グループ管理

### 宣言的なユーザー管理

このプロジェクトでは、JSONファイルベースの宣言的なユーザー管理を採用しています。

#### 新しいユーザーの追加

1. **JSONファイルを作成**

```bash
cat > openldap/bootstrap/user-configs/newuser.json <<EOF
{
  "id": "newuser",
  "email": "newuser@kojigenba-srv.com",
  "displayName": "New User",
  "firstName": "New",
  "lastName": "User",
  "password": "initial-password-123",
  "groups": ["system-users", "samba-users"]
}
EOF
```

2. **設定を生成・適用**

```bash
# 全設定ファイルを生成（推奨）
./scripts/generate-all.sh
# プロンプトでLDAP管理パスワードを入力:
#   - Admin password (for cn=admin,dc=...)
#   - Config password (for rootpw)
# ユーザーパスワードはJSONファイルから自動読み込み

# Kubernetesに適用
chmod 600 secret.yaml
kubectl apply -f secret.yaml
kubectl apply -f openldap/bootstrap-configmap.yaml
kubectl apply -f openldap/bootstrap-update-configmap.yaml

# ブートストラップJobを再実行
kubectl delete job openldap-bootstrap -n openldap
kubectl apply -f openldap/bootstrap-job.yaml

# Job完了を確認
kubectl wait --for=condition=complete --timeout=120s job/openldap-bootstrap -n openldap
```

#### ユーザーの削除

1. JSONファイルを削除

```bash
rm openldap/bootstrap/user-configs/unwanted-user.json
```

2. 設定を再生成・適用（上記と同じ手順）

#### グループメンバーシップの変更

ユーザーのJSONファイルで `groups` 配列を編集：

```json
{
  "id": "koji-genba",
  "groups": ["system-users", "samba-users"]
}
```

設定を再生成・適用すると、グループメンバーシップが更新されます。

#### 利用可能なグループ

- `system-admins`: システム管理者（GID 10001）
- `system-users`: 標準ユーザー（GID 10002）
- `system-readonly`: 読み取り専用ユーザー（GID 10003）
- `samba-users`: Sambaファイル共有アクセス権限（GID 10004）

詳細は [openldap/bootstrap/README.md](openldap/bootstrap/README.md) を参照してください。

### 生成スクリプトの使い分け

#### `./scripts/generate-all.sh`（推奨）

**全設定ファイルを一括生成**します。通常はこれを使用してください。

```bash
./scripts/generate-all.sh
```

生成されるファイル：
- `openldap/bootstrap-configmap.yaml` - LDAP エントリ定義
- `openldap/bootstrap-update-configmap.yaml` - グループメンバーシップ更新
- `secret.yaml` - 全パスワードとハッシュ

#### 個別スクリプト（特殊用途のみ）

**通常は不要です。** 以下のような特殊なケースでのみ使用します：

**`./scripts/generate-bootstrap-ldif.sh`**
- ConfigMapのみ再生成したい場合

**`./scripts/generate-bootstrap-update.sh`**
- グループメンバーシップ更新のみ再生成したい場合

**`./scripts/generate-user-secrets.sh`**
- Secretのみ再生成したい場合（パスワード変更時など）
- `generate-all.sh` と同じSecretを生成

**推奨**: ほとんどの場合、`generate-all.sh` だけで十分です。

### パスワード変更（既存ユーザー）

**方法1: LDAP直接変更（推奨）**

```bash
kubectl exec -it deployment/openldap -n openldap -- ldappasswd \
  -x -D "cn=admin,dc=kojigenba-srv,dc=com" -W \
  -S "uid=koji-genba,ou=people,dc=kojigenba-srv,dc=com"
```

**方法2: JSON + 再生成**

1. JSONファイルのパスワードを変更
2. `./scripts/generate-all.sh` を実行
3. 設定を適用（上記手順）

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

### Bootstrap 仕組み

OpenLDAP の初期データは 2 段階で投入されます：

1. **bootstrap.ldif** (`bootstrap-configmap.yaml`): 新規エントリを `ldapadd` で追加
2. **update.ldif** (`bootstrap-update-configmap.yaml`): 既存エントリを `ldapmodify` で更新

この仕組みにより、ConfigMap を変更するだけで既存エントリの属性（memberUid など）を更新できます。

### Samba 統合

OpenLDAP は Samba 認証に必要な以下のスキーマとオブジェクトをサポート：

- **スキーマ**: `samba.schema` (Samba 3.x/4.x 対応)
- **ドメイン**: `sambaDomainName=K8S-SAMBA`
- **グループ**: `sambaGroupMapping` オブジェクトクラス
- **ユーザー**: `sambaSamAccount` オブジェクトクラス (NT Hash 対応)

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
   cp phpldapadmin/configmap-phpadmin.yaml.template phpldapadmin/configmap-phpadmin.yaml
   cp secret.yaml.template secret.yaml  # 既に存在する場合
   ```

2. 機密情報を編集
   ```bash
   # phpldapadmin/configmap-phpadmin.yaml で LDAP_PASSWORD を実際のパスワードに変更
   vi phpldapadmin/configmap-phpadmin.yaml
   ```

3. Kubernetes に適用
   ```bash
   kubectl apply -f secret.yaml
   kubectl apply -f phpldapadmin/configmap-phpadmin.yaml
   ```

### Git 管理

公開リポジトリ使用時は、以下が `.gitignore` で除外されます：
- `secret.yaml` - Kubernetes Secret マニフェスト
- `phpldapadmin/configmap-phpadmin.yaml` - phpLDAPadmin ConfigMap マニフェスト

パスワードやトークンは絶対に commit しないでください。
