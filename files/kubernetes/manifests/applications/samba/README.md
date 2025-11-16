# Samba File Server

OpenLDAPユーザ認証を利用したSambaファイルサーバーのKubernetesデプロイメント。

## 概要

- **プロトコル**: SMB3 (TCP 445)
- **認証**: OpenLDAP (dc=kojigenba-srv,dc=com)
- **ストレージ**: NFS共有 (nfs-shared StorageClass)
- **対応クライアント**: Windows, macOS, Android
- **アクセス権限**: `samba-users` LDAP グループ所属者

## アーキテクチャ

```
クライアント (Win/Mac/Android)
    ↓ SMB3 (445/TCP)
Samba Container (K8s Pod)
    ↓ LDAP
OpenLDAP (openldap namespace)
    ↓ NFS
NFS Shared Storage (/tank/data/shared)
```

## ファイル構成

```
samba/
├── README.md                    # このファイル
├── namespace.yaml               # Namespace定義
├── pvc-shared.yaml             # PersistentVolumeClaim
├── configmap-smb.yaml          # Samba設定 (smb.conf)
├── deployment.yaml             # Deployment定義
├── service.yaml                # LoadBalancer Service
├── secret.yaml.template        # シークレットテンプレート
├── deploy.sh                   # デプロイメント実行スクリプト
└── docker/
    ├── Dockerfile              # Sambaコンテナイメージ
    └── docker-entrypoint.sh    # 起動スクリプト
```

## 前提条件

- Kubernetes クラスタが稼働中
- OpenLDAP が `openldap` namespace で稼働中
- MetalLB が インストール済み
- NFS Provisioner が稼働中
- Docker イメージレジストリへのアクセス権限

## デプロイメント手順

### 1. Dockerイメージのビルドとプッシュ

```bash
# Samba Dockerイメージをビルド
cd docker
docker build -t ghcr.io/koji-genba/samba:v1.10 .

# レジストリにプッシュ
docker push ghcr.io/koji-genba/samba:v1.10
```

### 2. OpenLDAPの更新

OpenLDAPのブートストラップ設定に `samba-users` グループが追加されているため、既存のOpenLDAPをリセットするか、手動でグループを追加する必要があります。

**方法A: OpenLDAPをリセット（推奨）**
```bash
# OpenLDAPクラスタをリセット
kubectl delete pvc openldap-data-pvc -n openldap
kubectl rollout restart deployment/openldap -n openldap
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=openldap -n openldap --timeout=60s
```

**方法B: 手動でグループを追加**
```bash
# LDAP操作ツールを使用してグループを追加
ldapadd -x -D "cn=admin,dc=kojigenba-srv,dc=com" -W <<EOF
dn: cn=samba-users,ou=groups,dc=kojigenba-srv,dc=com
objectClass: posixGroup
objectClass: sambaGroupMapping
cn: samba-users
gidNumber: 10004
description: Samba File Share Users
sambaGroupType: 2
sambaSID: S-1-5-21-3623811015-3361044348-30300820-515
EOF
```

### 3. Sambaのデプロイ

```bash
# OpenLDAPのadminパスワードを環境変数に設定
export SAMBA_ADMIN_PASSWORD="<OpenLDAP_admin_password>"

# デプロイメント実行
./deploy.sh
```

デプロイスクリプトが以下を自動実行します：
- Namespace作成
- Secret生成
- ConfigMap適用
- PVC作成
- Deployment起動
- Service作成
- Pod Ready確認

## Sambaアクセス

### サービスアドレス

```
smb://192.168.11.103/shared
```

### ネットワーク情報

| 項目 | 値 |
|------|-----|
| **ServiceIP** | 192.168.11.103 |
| **ポート** | 445 (TCP) |
| **Namespace** | samba |
| **Pod** | samba-* |

## 設定詳細

### Samba共有設定 (smb.conf)

#### [shared] 共有
- **パス**: /mnt/shared
- **説明**: Shared Storage
- **アクセス権限**: `@samba-users` グループメンバー
- **ファイル作成マスク**: 0755

#### [archive] 共有
- **パス**: /mnt/archive
- **説明**: Archive Storage
- **アクセス権限**: `@samba-users` グループメンバー
- **ステータス**: 現在は emptyDir で起動（将来的に別NFS実装予定）

### LDAP連携設定

```
security = user
passdb backend = ldapsam:ldap://openldap-ldap.openldap.svc.cluster.local:389
ldap suffix = dc=kojigenba-srv,dc=com
ldap admin dn = cn=admin,dc=kojigenba-srv,dc=com
ldap passwd sync = yes
ldap timeout = 10
```

## トラブルシューティング

### ログ確認

```bash
# Pod ログを確認
kubectl logs -f deployment/samba -n samba

# 実時間でログ追跡
kubectl logs -f deployment/samba -n samba --tail=100
```

### Podの状態確認

```bash
# Deploymentの状態
kubectl get deployment -n samba

# Pod詳細
kubectl describe pod -l app.kubernetes.io/name=samba -n samba

# Service情報
kubectl get svc -n samba
```

### Samba設定の検証

```bash
# Pod内で実行
kubectl exec -it deployment/samba -n samba -- testparm -s
```

### LDAP接続テスト

```bash
# Pod内でLDAPへの接続を確認
kubectl exec -it deployment/samba -n samba -- ldapsearch -x \
  -H ldap://openldap-ldap.openldap.svc.cluster.local:389 \
  -b dc=kojigenba-srv,dc=com \
  -D cn=admin,dc=kojigenba-srv,dc=com \
  -W "cn=samba-users,ou=groups,dc=kojigenba-srv,dc=com"
```

### クライアント接続テスト

#### Windows
```powershell
# 共有資源を表示
net view \\192.168.11.103
```

#### macOS
```bash
# Finderから接続
# Cmd+K → smb://192.168.11.103/shared
# または
mount_smbfs -o nobrowse //username@192.168.11.103/shared /Volumes/shared
```

#### Linux
```bash
# smbclientでテスト
smbclient -L 192.168.11.103 -U username

# マウント
mount -t cifs //192.168.11.103/shared /mnt/shared -o username=username
```

## LDAPユーザの管理

### Sambaアクセス可能ユーザの追加

Sambaにアクセス可能なユーザにするには、OpenLDAPでそのユーザを `samba-users` グループに追加します：

```bash
# LDAPで既存ユーザをsamba-usersグループに追加
ldapmodify -x -D "cn=admin,dc=kojigenba-srv,dc=com" -W <<EOF
dn: cn=samba-users,ou=groups,dc=kojigenba-srv,dc=com
changetype: modify
add: memberUid
memberUid: username
EOF
```

## ストレージ情報

### PVC設定

- **名前**: samba-shared-storage
- **ストレージクラス**: nfs-shared
- **容量**: 1.5Ti
- **アクセスモード**: ReadWriteMany
- **バックエンド**: /tank/data/shared (Proxmox ZFS)

## セキュリティ考慮事項

### Pod実行権限

Deployment では以下の Linux Capability を追加しています：
- `SYS_ADMIN`: ファイルシステムマウント
- `DAC_OVERRIDE`: ファイルアクセス制御
- `SETUID` / `SETGID`: ユーザ ID 切り替え
- `SYS_CHROOT`: chroot操作

特権モード（privileged）は無効化しています。

### ネットワークセキュリティ

- SMB3のみサポート（NetBIOS ports 137/138/139 不使用）
- Kubernetesネットワークポリシーで必要に応じて制限可能

## 今後の拡張予定

1. **Archive共有**: 別NFS共有を使用した実装
2. **リプリケーション**: 高可用性対応
3. **バックアップ**: 定期バックアップスケジュール
4. **ユーザホームディレクトリ**: NFS経由でのホームディレクトリ提供
5. **ドメイン参加**: Active Directory風のドメイン機能

## 参考情報

- [Samba公式ドキュメント](https://www.samba.org/samba/docs/)
- [OpenLDAP統合ガイド](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html#PASSDBBACKEND)
- [Kubernetes StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
