# Samba File Server

OpenLDAPユーザ認証を利用したSambaファイルサーバーのKubernetesデプロイメント。

## 概要

- **プロトコル**: SMB3 (TCP 445)
- **認証**: OpenLDAP ldapsam backend (dc=kojigenba-srv,dc=com)
- **ストレージ**: Static NFS PV (192.168.10.11:/tank/data/shared)
- **対応クライアント**: Windows, macOS, Android
- **アクセス権限**: `samba-users` LDAP グループ所属者
- **NSS統合**: nslcd による LDAP ユーザー/グループ解決

## アーキテクチャ

```
クライアント (Win/Mac/Android)
    ↓ SMB3 (445/TCP)
Samba Container (K8s Pod)
    ├─ smbd (ldapsam backend)
    ├─ nslcd (NSS LDAP daemon)
    └─ LDAP クエリ
         ↓
OpenLDAP (openldap namespace)
    ↓ NFS
NFS Shared Storage (/tank/data/shared)
```

## ファイル構成

```
samba/
├── README.md                    # このファイル
├── namespace.yaml               # Namespace定義
├── pv-shared.yaml              # Static PV (shared用)
├── pvc-shared.yaml             # PVC (shared用)
├── pv-archive.yaml             # Static PV (archive用)
├── pvc-archive.yaml            # PVC (archive用)
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
- MetalLB がインストール済み
- NFSサーバー (192.168.10.11) が稼働中
  - `/tank/data/shared` がエクスポート済み
  - `/mnt/sdc/archive` がエクスポート済み
- Docker イメージレジストリへのアクセス権限

## デプロイメント手順

### 1. Dockerイメージのビルドとプッシュ

```bash
# Samba Dockerイメージをビルド
cd docker
docker build -t ghcr.io/koji-genba/samba:v1.32 .

# レジストリにプッシュ
docker push ghcr.io/koji-genba/samba:v1.32
```

**v1.32 での変更点:**
- NSS LDAP (nslcd) 統合を追加
- UNIX ユーザー/グループの LDAP からの解決をサポート
- Primary Group SID の正しい解決を実現

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
- **ファイル作成マスク**: 0755
- **ストレージ**: Static NFS PV (192.168.10.11:/mnt/sdc/archive, 6TB)

### LDAP連携設定

#### Samba ldapsam 設定

```ini
security = user
passdb backend = ldapsam:ldap://openldap-ldap.openldap.svc.cluster.local:389
ldap suffix = dc=kojigenba-srv,dc=com
ldap user suffix = ou=people
ldap group suffix = ou=groups
ldap admin dn = cn=admin,dc=kojigenba-srv,dc=com
ldap passwd sync = yes
ldap timeout = 10
ldap ssl = off
netbios name = k8s-samba
workgroup = HOMELAB
```

#### NSS LDAP 設定 (nslcd)

```ini
uri ldap://openldap-ldap.openldap.svc.cluster.local:389
base dc=kojigenba-srv,dc=com
base passwd ou=people,dc=kojigenba-srv,dc=com
base group ou=groups,dc=kojigenba-srv,dc=com
binddn cn=admin,dc=kojigenba-srv,dc=com
bindpw <LDAP_BIND_PASSWORD>
```

NSS により、Samba は LDAP から UNIX ユーザー/グループ情報を取得し、Primary Group SID を正しく解決できます。

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

### NSS LDAP 動作確認

```bash
# ユーザー情報を取得
kubectl exec -it deployment/samba -n samba -- getent passwd admin

# グループ情報を取得
kubectl exec -it deployment/samba -n samba -- getent group samba-users

# ユーザーのグループメンバーシップを確認
kubectl exec -it deployment/samba -n samba -- id admin

# nslcd デーモンの状態確認
kubectl exec -it deployment/samba -n samba -- pgrep -a nslcd
```

### Samba ユーザーデータベース確認

```bash
# Samba のユーザー情報を確認
kubectl exec -it deployment/samba -n samba -- pdbedit -Lv admin

# Samba のグループマッピングを確認
kubectl exec -it deployment/samba -n samba -- net groupmap list
```

### クライアント接続テスト

#### Windows
```powershell
# 共有資源を表示
net view \\192.168.11.103

# shared共有に接続
net use Z: \\192.168.11.103\shared /user:admin

# archive共有に接続
net use Y: \\192.168.11.103\archive /user:admin
```

#### macOS
```bash
# Finderから接続
# Cmd+K → smb://192.168.11.103/shared または smb://192.168.11.103/archive
# または
mount_smbfs -o nobrowse //username@192.168.11.103/shared /Volumes/shared
mount_smbfs -o nobrowse //username@192.168.11.103/archive /Volumes/archive
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

### Static PV 設定

既存のNFSデータを直接マウントするため、Static PersistentVolumeを使用しています。

#### Shared Storage (PV/PVC)

**PersistentVolume (samba-shared-pv)**
- **ストレージクラス**: nfs-shared-static
- **容量**: 4Ti
- **アクセスモード**: ReadWriteMany
- **Reclaim Policy**: Retain
- **NFSサーバー**: 192.168.10.11
- **NFSパス**: /tank/data/shared (直接マウント)

**PersistentVolumeClaim (samba-shared-storage)**
- **ストレージクラス**: nfs-shared-static
- **ボリューム名**: samba-shared-pv (静的バインド)
- **容量**: 4Ti
- **アクセスモード**: ReadWriteMany

#### Archive Storage (PV/PVC)

**PersistentVolume (samba-archive-pv)**
- **ストレージクラス**: nfs-archive-static
- **容量**: 6Ti
- **アクセスモード**: ReadWriteMany
- **Reclaim Policy**: Retain
- **NFSサーバー**: 192.168.10.11
- **NFSパス**: /mnt/sdc/archive (直接マウント)

**PersistentVolumeClaim (samba-archive-storage)**
- **ストレージクラス**: nfs-archive-static
- **ボリューム名**: samba-archive-pv (静的バインド)
- **容量**: 6Ti
- **アクセスモード**: ReadWriteMany

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
