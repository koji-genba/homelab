# OpenLDAP Bootstrap User/Group Management

このディレクトリには、OpenLDAPのユーザーとグループを宣言的に管理するためのJSON設定ファイルが含まれています。

## ディレクトリ構造

```
bootstrap/
├── README.md              # このファイル
├── user-configs/          # ユーザー定義JSONファイル
│   ├── admin-user.json
│   ├── koji-genba.json
│   └── ...
└── group-configs/         # グループ定義JSONファイル
    ├── system-admins.json
    ├── system-users.json
    ├── system-readonly.json
    └── samba-users.json
```

## ユーザー管理

### 新しいユーザーの追加

1. `user-configs/` ディレクトリに新しいJSONファイルを作成します：

```bash
# 例: newuser.json（次に利用可能なUID 10003を使用）
cat > user-configs/newuser.json <<EOF
{
  "id": "newuser",
  "uid": 10003,
  "gid": 10002,
  "sambaSID": "S-1-5-21-3623811015-3361044348-30300820-1003",
  "email": "newuser@kojigenba-srv.com",
  "displayName": "New User",
  "firstName": "New",
  "lastName": "User",
  "password": "initial-password-123",
  "groups": ["system-users", "samba-users"],
  "homeDirectory": "/export/home/newuser",
  "loginShell": "/bin/bash"
}
EOF
```

**RID計算**: UID 10003の下4桁 = 1003 → sambaSID末尾を1003に設定

**必須フィールド:**
- `id`: ユーザーID（LDAP uid、ユニークである必要がある）
- `uid`: UNIX UID番号（例: 10100、**ユニークかつ固定値推奨**）
- `gid`: プライマリグループのGID（例: 10002=system-users）
- `sambaSID`: Samba SID（例: S-1-5-21-...-2100、**ユニークである必要がある**）
- `email`: メールアドレス
- `displayName`: 表示名
- `firstName`: 名
- `lastName`: 姓
- `password`: 初期パスワード（プレーンテキスト、ハッシュ化されて保存）
- `groups`: 所属グループ配列（例: ["system-users", "samba-users"]）

**オプションフィールド（デフォルト値あり）:**
- `homeDirectory`: ホームディレクトリ（デフォルト: `/export/home/<id>`）
- `loginShell`: ログインシェル（デフォルト: `/bin/bash`）

**UID/GID/SID割り当てガイドライン:**

**UID（UNIX User ID）:**
- 範囲: 10001から開始、連番で割り当て
- 予約: 10001はadmin-user用に予約済み
- 推奨: 10002, 10003, 10004, ... と順次割り当て
- **重要**: 一度割り当てたUIDは変更しないこと（Sambaファイル所有権維持のため）

**GID（UNIX Group ID）:**
既存グループから選択（プライマリグループ）:
  - `10001`: system-admins（管理者）
  - `10002`: system-users（一般ユーザー、推奨デフォルト）
  - `10003`: system-readonly（読み取り専用）
  - `10004`: samba-users（Sambaアクセス専用）

**Samba SID（Security Identifier）:**

形式: `S-1-5-21-<ドメインID>-<RID>`

**このドメインのSID構造:**
```
S-1-5-21-3623811015-3361044348-30300820-<RID>
         └────────────┬────────────────┘
              ドメインID（固定）
```

**RID（Relative Identifier）割り当てルール:**

**基本ルール: UIDの下4桁をそのままRIDとして使用**

計算例:
```
UID 10001 → RID = 1001  (下4桁)
  sambaSID: S-1-5-21-3623811015-3361044348-30300820-1001

UID 10002 → RID = 1002  (下4桁)
  sambaSID: S-1-5-21-3623811015-3361044348-30300820-1002

UID 10003 → RID = 1003  (下4桁)
  sambaSID: S-1-5-21-3623811015-3361044348-30300820-1003

UID 10100 → RID = 100   (下4桁、BUT推奨しない)
  sambaSID: S-1-5-21-3623811015-3361044348-30300820-100
  ⚠️ この場合、RID 100は小さすぎるため、UID 10100ではなく1xxxx系を推奨

推奨: UID 10001-10999の範囲を使用（RID 1001-1999に対応）
```

**予約RID:**
- 1001: admin-user用（UID 10001）
- 1002-1999: 一般ユーザー用（UID 10002-10999）

**重要な注意事項:**
- ✅ **SIDは絶対に変更しないこと**: Sambaファイルのアクセス権限と紐付いています
- ✅ **RIDは一意である必要あり**: 重複すると認証エラーが発生します
- ✅ **UIDは10001-10999の範囲を推奨**: RIDと一対一対応させるため
- `groups`: 所属グループの配列

**利用可能なグループ:**
- `system-admins`: システム管理者
- `system-users`: 標準ユーザー
- `system-readonly`: 読み取り専用ユーザー
- `samba-users`: Sambaファイル共有アクセス権限

2. 設定を生成・適用します：

```bash
# ルートディレクトリ（ldap/）で実行
cd ../../  # ldap/ ディレクトリへ移動

# 全ての設定を生成（対話的にLDAP管理パスワードを入力）
./scripts/generate-all.sh
# プロンプトで以下を入力:
#   - Admin password (for cn=admin,dc=...)
#   - Config password (for rootpw)

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

### ユーザーの削除

1. `user-configs/` から該当ユーザーのJSONファイルを削除します：

```bash
rm user-configs/unwanted-user.json
```

2. 設定を再生成・適用します（上記と同じ手順）

### ユーザー情報の変更

1. 該当ユーザーのJSONファイルを編集します：

```bash
nano user-configs/koji-genba.json
```

2. 設定を再生成・適用します

**注意:**
- `id` (ユーザーID) の変更は推奨されません（新しいユーザーとして扱われます）
- パスワード変更の場合は、LDAPに直接変更する方法も利用できます

## グループ管理

### ユーザーのグループ追加/削除

ユーザーのJSONファイルの `groups` 配列を編集します：

```json
{
  "id": "koji-genba",
  "groups": ["system-users", "samba-users", "new-group"]
}
```

設定を再生成・適用すると、グループメンバーシップが更新されます。

## 自動生成スクリプト

### `../../scripts/generate-all.sh`

全ての設定ファイルを一括生成します。

### 個別スクリプト

- `../../scripts/generate-bootstrap-ldif.sh`: bootstrap-configmap.yaml 生成
- `../../scripts/generate-bootstrap-update.sh`: bootstrap-update-configmap.yaml 生成
- `../../scripts/generate-user-secrets.sh`: secret.yaml 生成

## パスワード管理

### 初期パスワード設定

JSONファイルの `password` フィールドにプレーンテキストで指定します。
スクリプトが自動的に以下を生成します：
- SSHA ハッシュ（LDAP userPassword）
- NT ハッシュ（Samba sambaNTPassword）

### パスワード変更（既存ユーザー）

**方法1: LDAP直接変更（推奨）**

```bash
# OpenLDAP Pod内で実行
kubectl exec -it deployment/openldap -n openldap -- ldappasswd \
  -x -D "cn=admin,dc=kojigenba-srv,dc=com" -W \
  -S "uid=koji-genba,ou=people,dc=kojigenba-srv,dc=com"
```

**方法2: JSON + 再生成**

1. JSONファイルのパスワードを変更
2. `generate-all.sh` を実行
3. `secret.yaml` を適用
4. ブートストラップJobを再実行

## トラブルシューティング

### ユーザーが作成されない

1. ブートストラップJobのログを確認：

```bash
kubectl logs -n openldap job/openldap-bootstrap
```

2. LDIFファイルの内容を確認：

```bash
kubectl get configmap openldap-bootstrap-config -n openldap -o yaml
```

### グループメンバーシップが更新されない

bootstrap-update-configmap.yaml が正しく生成されているか確認：

```bash
cat ../../openldap/bootstrap-update-configmap.yaml
```

### パスワードハッシュ生成エラー

スクリプト実行時のエラーメッセージを確認し、必要なツールがインストールされているか確認：
- `jq`
- `slappasswd` (ldap-utils)
- `openssl`
- `iconv`
- `perl` (オプション、NT hash生成用)

## セキュリティ考慮事項

1. **パスワードの保護**
   - JSONファイルのパスワードはプレーンテキストで保存されます
   - このディレクトリを適切に保護してください
   - 本番環境では、初回作成後にパスワードを変更することを推奨

2. **secret.yaml の管理**
   - `secret.yaml` はGitにコミットしないでください（.gitignore で保護）
   - 生成後、権限を `chmod 600` に設定してください
   - Kubernetes適用後は削除することを推奨

3. **admin-user の特別扱い**
   - `admin-user` は固定UID (10001) とSID (1001) を持ちます
   - システム管理者として特別な権限を持ちます
   - パスワードは特に厳重に管理してください

## 参考資料

- [OpenLDAP Documentation](https://www.openldap.org/doc/)
- [RFC 2307 - LDAP as a Network Information Service](https://tools.ietf.org/html/rfc2307)
- [Samba LDAP Integration](https://wiki.samba.org/index.php/Setting_up_Samba_as_a_Domain_Member)
