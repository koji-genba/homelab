# Samba File Server

宣言的なローカルユーザ定義を利用したSambaファイルサーバーのKubernetesデプロイメント。

## 概要

- **プロトコル**: SMB3 (TCP 445)
- **認証**: ローカルユーザ + Samba tdbsam backend
- **ストレージ**: Static NFS PV (mergerfs: 192.168.10.11:/mnt/shared, HDD直接: 192.168.10.11:/mnt/tank-gen2/data/shared)
- **対応クライアント**: Windows, macOS, Android
- **アクセス権限**: `samba-users` ローカルグループ所属者
- **状態管理**: Samba passdb は Pod 起動時に ConfigMap/Secret から毎回再生成

## アーキテクチャ

```
クライアント (Win/Mac/Android)
    ↓ SMB3 (445/TCP)
Samba Container (K8s Pod)
    ├─ smbd (tdbsam backend)
    ├─ local UNIX users/groups
    └─ generated Samba passdb

[shared]     → /mnt/shared          (mergerfs: SSD cache + HDD, 19Ti)
[shared-hdd] → /mnt/tank-gen2/data/shared  (HDD直接, 18Ti)
[archive]    → /mnt/tank-gen1/data/archive (archive, 6Ti)
```

## ファイル構成

```
samba/
├── README.md                    # このファイル
├── namespace.yaml               # Namespace定義
├── pv-shared.yaml              # Static PV (mergerfs shared用, 19Ti)
├── pvc-shared.yaml             # PVC (mergerfs shared用)
├── pv-shared-hdd.yaml          # Static PV (HDD直接 shared用, 18Ti)
├── pvc-shared-hdd.yaml         # PVC (HDD直接 shared用)
├── pv-archive.yaml             # Static PV (archive用)
├── pvc-archive.yaml            # PVC (archive用)
├── configmap-smb.yaml          # Samba設定 (smb.conf)
├── config/
│   ├── users.json              # ローカルユーザ/グループ定義
│   └── secrets.json.template   # SambaパスワードJSONテンプレート
├── deployment.yaml             # Deployment定義
├── service.yaml                # LoadBalancer Service
├── deploy.sh                   # デプロイメント実行スクリプト
├── scripts/
│   └── add-user.sh             # ユーザ追加補助スクリプト
└── docker/
    ├── Dockerfile              # Sambaコンテナイメージ
    └── docker-entrypoint.sh    # 起動スクリプト
```

## 前提条件

- Kubernetes クラスタが稼働中
- MetalLB がインストール済み
- NFSサーバー (192.168.10.11) が稼働中
  - `/mnt/shared` がエクスポート済み (mergerfs union mount, fsid=100)
  - `/mnt/tank-gen2/data/shared` がエクスポート済み
  - `/mnt/tank-gen1/data/archive` がエクスポート済み
- Docker イメージレジストリへのアクセス権限

## デプロイメント手順

### 1. Dockerイメージのビルドとプッシュ

```bash
# バージョン変数を設定
export SAMBA_VERSION="v1.34"

# Samba Dockerイメージをビルド
cd docker
docker build -t ghcr.io/koji-genba/samba:${SAMBA_VERSION} .

# レジストリにプッシュ
docker push ghcr.io/koji-genba/samba:${SAMBA_VERSION}
```

**v1.34 での変更点:**
- OpenLDAP 依存を削除
- ConfigMap/Secret からローカル UNIX ユーザと Samba passdb を起動時に再生成
- Samba local SID を固定し、Samba 状態用 PV を不要化
- `users.json` と `scripts/add-user.sh` による UID/RID/SID 管理を追加

> **注**: バージョン番号は環境変数 `SAMBA_VERSION` で管理しています。デプロイ時には [deployment.yaml](deployment.yaml#L25) で指定されたバージョンと一致させてください。

### 2. ユーザ定義の確認

`config/users.json` は Git 管理するユーザ定義です。UNIX UID/GID、Samba RID、所属グループ、パスワードを参照するための `passwordSecretKey` を宣言します。

既存ファイルの所有権を維持するため、UID/GID は変更しないでください。現在の `koji-genba` は UID/GID `10002:10002` です。

### 3. Samba Secretの作成

`config/secrets.json` は Git 管理しないパスワード定義です。`config/users.json` の各ユーザが持つ `passwordSecretKey` と同じキー名で、実際の Samba パスワードを書きます。

```bash
cp config/secrets.json.template config/secrets.json
chmod 600 config/secrets.json
vi config/secrets.json
```

例:

```json
{
  "koji-genba-password": "actual-samba-password"
}
```

### 4. Sambaのデプロイ

```bash
# デプロイメント実行
./deploy.sh
```

デプロイスクリプトが以下を自動実行します：
- Namespace作成
- Secret生成
- ConfigMap適用 (`smb.conf`, ユーザ定義)
- PVC作成
- Deployment起動
- Service作成
- Pod Ready確認

## Sambaアクセス

### サービスアドレス

| Share | アドレス | 用途 |
|---|---|---|
| shared | `\\192.168.11.103\shared` | 通常利用（mergerfs: SSD→HDD 透過） |
| shared-hdd | `\\192.168.11.103\shared-hdd` | HDD直接（比較・直接コピー用） |
| archive | `\\192.168.11.103\archive` | アーカイブ |

> **注意**: `shared` に書いたファイルはまず SSD に乗り、毎朝5時の mover.sh で HDD に移動されます。
> mover 実行前の SSD 上ファイルは `shared-hdd` からは見えません。通常は `shared` を使用してください。

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
- **パス**: /mnt/shared (mergerfs: SSD cache + HDD)
- **説明**: Shared Storage (mergerfs)
- **アクセス権限**: `@samba-users` グループメンバー
- **パーミッション設定**:
  - ファイル作成マスク: 0600
  - ディレクトリ作成マスク: 0700

#### [shared-hdd] 共有
- **パス**: /mnt/shared-hdd (HDD直接マウント)
- **説明**: Shared Storage (HDD direct) — パフォーマンス比較・直接コピー用
- **アクセス権限**: `@samba-users` グループメンバー
- **パーミッション設定**:
  - ファイル作成マスク: 0600
  - ディレクトリ作成マスク: 0700
- **ストレージ**: Static NFS PV (192.168.10.11:/mnt/tank-gen2/data/shared, 18Ti)

#### [archive] 共有
- **パス**: /mnt/archive
- **説明**: Archive Storage
- **アクセス権限**: `@samba-users` グループメンバー
- **パーミッション設定**:
  - ファイル作成マスク: 0600
  - ディレクトリ作成マスク: 0700
- **ストレージ**: Static NFS PV (192.168.10.11:/tank-gen1/data/archive, 6TB)

### ローカル認証設定

```ini
security = user
server role = standalone server
passdb backend = tdbsam
workgroup = HOMELAB
netbios name = k8s-samba
```

Pod 起動時に `config/users.json` 由来の ConfigMap と `samba-secrets` からローカル UNIX ユーザ/グループと Samba passdb を再生成します。`/var/lib/samba` は `emptyDir` のため、Samba の生成状態は再デプロイで保持しません。

`localSid` は Samba が Windows SID のドメイン部分として使う値です。Samba は未保存時にランダムな `S-1-5-21-x-y-z` を生成して `secrets.tdb` に保存するため、`emptyDir` 運用では `config/users.json` で固定します。既存 LDAP 時代の Domain SID を引き継ぐため、現在は `S-1-5-21-3623811015-3361044348-30300820` を指定しています。

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

### ローカルユーザ動作確認

```bash
# ユーザー情報を取得
kubectl exec -it deployment/samba -n samba -- getent passwd koji-genba

# グループ情報を取得
kubectl exec -it deployment/samba -n samba -- getent group samba-users

# ユーザーのグループメンバーシップを確認
kubectl exec -it deployment/samba -n samba -- id koji-genba
```

### Samba ユーザーデータベース確認

```bash
# Samba のユーザー情報を確認
kubectl exec -it deployment/samba -n samba -- pdbedit -Lv koji-genba

# Samba local SIDを確認
kubectl exec -it deployment/samba -n samba -- net getlocalsid
```

### クライアント接続テスト

#### Windows
```powershell
# 共有資源を表示
net view \\192.168.11.103

# shared共有に接続（通常利用）
net use Z: \\192.168.11.103\shared /user:koji-genba

# shared-hdd共有に接続（HDD直接）
net use X: \\192.168.11.103\shared-hdd /user:koji-genba

# archive共有に接続
net use Y: \\192.168.11.103\archive /user:koji-genba
```

#### macOS
```bash
# Finderから接続
# Cmd+K → smb://192.168.11.103/shared
#          smb://192.168.11.103/shared-hdd
#          smb://192.168.11.103/archive
mount_smbfs -o nobrowse //username@192.168.11.103/shared /Volumes/shared
mount_smbfs -o nobrowse //username@192.168.11.103/shared-hdd /Volumes/shared-hdd
mount_smbfs -o nobrowse //username@192.168.11.103/archive /Volumes/archive
```

#### Linux
```bash
# smbclientでテスト
smbclient -L 192.168.11.103 -U username

# マウント
mount -t cifs //192.168.11.103/shared /mnt/shared -o username=username
mount -t cifs //192.168.11.103/shared-hdd /mnt/shared-hdd -o username=username
```

## Sambaユーザの管理

### Sambaアクセス可能ユーザの追加

Sambaにアクセス可能なユーザにするには、補助スクリプトで `config/users.json` にユーザを追加します。RID は既存 LDAP の規則に合わせて、UID `10001-10999` ではデフォルトで `UID - 9000` から計算されます。

```bash
scripts/add-user.sh newuser 10003
```

スクリプトは `config/users.json` に以下のようなユーザ定義を追加し、`config/secrets.json.template` に対応するパスワードキーも追加します。

```json
{
  "name": "newuser",
  "uid": 10003,
  "gid": 10002,
  "rid": 1003,
  "groups": ["samba-users"],
  "home": "/nonexistent",
  "shell": "/usr/sbin/nologin",
  "passwordSecretKey": "newuser-password"
}
```

実際のパスワードは Git 管理対象外の `config/secrets.json` に書きます。

```json
{
  "koji-genba-password": "current-password",
  "newuser-password": "newuser-password"
}
```

UID から計算される RID を使いたくない場合は、`--rid` で明示します。

```bash
scripts/add-user.sh newuser 10100 --rid 1100
```

## ストレージ情報

### Static PV 設定

既存のNFSデータを直接マウントするため、Static PersistentVolumeを使用しています。

#### Shared Storage — mergerfs (PV/PVC)

**PersistentVolume (samba-shared-pv)**
- **ストレージクラス**: nfs-shared-static
- **容量**: 19Ti (SSD 860GB + HDD 20TB の mergerfs union)
- **アクセスモード**: ReadWriteMany
- **Reclaim Policy**: Retain
- **NFSサーバー**: 192.168.10.11
- **NFSパス**: /mnt/shared (mergerfs union mount, fsid=100)
- **マウントオプション**: sync

**PersistentVolumeClaim (samba-shared-storage)**
- **ストレージクラス**: nfs-shared-static
- **ボリューム名**: samba-shared-pv (静的バインド)
- **容量**: 19Ti
- **アクセスモード**: ReadWriteMany

#### Shared Storage — HDD直接 (PV/PVC)

**PersistentVolume (samba-shared-hdd-pv)**
- **ストレージクラス**: nfs-shared-hdd-static
- **容量**: 18Ti (Toshiba N300 ×2 mirror, 20TB ≈ 18Ti)
- **アクセスモード**: ReadWriteMany
- **Reclaim Policy**: Retain
- **NFSサーバー**: 192.168.10.11
- **NFSパス**: /mnt/tank-gen2/data/shared (HDD直接)
- **マウントオプション**: sync
- **用途**: パフォーマンス比較・大容量データの直接コピー

**PersistentVolumeClaim (samba-shared-hdd-storage)**
- **ストレージクラス**: nfs-shared-hdd-static
- **ボリューム名**: samba-shared-hdd-pv (静的バインド)
- **容量**: 18Ti
- **アクセスモード**: ReadWriteMany

#### Archive Storage (PV/PVC)

**PersistentVolume (samba-archive-pv)**
- **ストレージクラス**: nfs-archive-static
- **容量**: 6Ti
- **アクセスモード**: ReadWriteMany
- **Reclaim Policy**: Retain
- **NFSサーバー**: 192.168.10.11
- **NFSパス**: /mnt/tank-gen1/data/archive
- **マウントオプション**: sync

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
- `SYS_PTRACE`: プロセストレース（デバッグ用）

特権モード（privileged）は無効化しています。

### ネットワークセキュリティ

- SMB2のみサポート（NetBIOS ports 137/138/139 不使用）
- Kubernetesネットワークポリシーで必要に応じて制限可能


## 参考情報

- [Samba公式ドキュメント](https://www.samba.org/samba/docs/)
- [Kubernetes StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/)
