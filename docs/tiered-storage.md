# Tiered Storage (mergerfs + ZFS)

pve1上のtank-gen2に対してSSDライトキャッシュ層をmergerfsで構成する。

## アーキテクチャ

```
書き込み  → /mnt/shared (mergerfs)
                ↓ 新規ファイルはSSD優先 (category.create=ff)
            /mnt/cache-sata  (cache-pool: KIOXIA EXCERIA ×2 mirror, 860GB)
                ↓ 毎朝5時 mover.sh (cmin+30でsettle判定)
            /mnt/tank-gen2/data/shared  (Toshiba N300 ×2 mirror, 20TB)
                ↓ mover完了後にZFS snapshot

読み込み  → /mnt/shared から透過的にアクセス（SSD・HDD問わず）
            tank-gen2のread cache → M8VC L2ARC (476GB)

NFS export → /mnt/shared → K8s Samba pod → Windows SMB
```

## コンポーネント

| コンポーネント | デバイス | 役割 |
|---|---|---|
| cache-pool | KIOXIA EXCERIA SATA SSD ×2 (mirror) | mergerfsライトキャッシュ |
| tank-gen2 | Toshiba N300 ×2 (mirror) | 実体ストレージ |
| M8VC | Plextor PX-512M8VC 476GB | tank-gen2 L2ARC |
| /mnt/shared | mergerfs union mount | クライアントから見えるパス |

## 設計判断メモ

**category.create=ff**
SSDを先頭ブランチに置き、常にSSD優先で書き込む。`minfreespace`（デフォルト4GB）を下回ったら自動的にHDDにフォールバックするので「SSD満杯ならHDDに書く」は追加設定不要。

**settling time判定にctimeを使う**
一部ディレクトリでWindowsクライアントがlastWriteTimeを過去日時に書き換える運用があるため、mtimeベースのsettling timeが機能しない。ctimeはカーネル管理でクライアントから変更不可なのでこちらを使う。

**nightly（毎朝5時）**
cache-pool 860GBに対して日次書き込みが満杯になることはないため、随時moveではなくnightly実行。SSDが埋まったとしてもmergerfsのフォールバックで機能継続する。

**ZFS snapshotはmover完了後**
mover前にsnapshotするとSSDに残っているファイルがsnapshotに写らない。moverスクリプトの末尾でsnapshotを取ることで「SSDが空になった完全な状態」を記録する。

**/mnt/tank-gen2/data/sharedのNFS exportも残す**
mergerfsを通さない直接経路として維持。大事なデータのコピーやパフォーマンス比較用。

## 設定

### /etc/fstab（mergerfsマウント）

```
/mnt/cache-sata:/mnt/tank-gen2/data/shared  /mnt/shared  fuse.mergerfs  defaults,cache.files=off,dropcacheonclose=false,category.create=ff,inodecalc=path-hash,func.getattr=newest,fsname=mergerfs-shared  0  0
```

`inodecalc=path-hash`: moverによってファイルがSSD→HDDに移動してもinode値が変わらない。NFS経由でstale handleが出るのを防ぐ。

### /etc/exports

```
/mnt/tank-gen2/data/k8s-volumes  192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank-gen1/data/archive      192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/tank-gen2/data/shared       192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
/mnt/shared                      192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=100)
```

FUSEファイルシステムはカーネルがfsidを自動取得できないため`fsid=100`を明示。

## moverスクリプト

`/usr/local/bin/mover.sh`

cron（毎朝5時）:
```
0 5 * * * /usr/local/bin/mover.sh
```

手動実行（書き込みが止まっている状態であれば任意タイミングでOK）:
```bash
/usr/local/bin/mover.sh
```

lockfileで二重起動を防止しているので、cronと手動が被っても安全。

## ZFS snapshotポリシー

対象: `tank-gen2/data/shared`のみ（moverスクリプト内で自動取得）

| 種別 | タイミング | 保持世代 |
|---|---|---|
| 日次 | 毎日（月次・週次以外） | 14世代 |
| 週次 | 月曜 | 8世代 |
| 月次 | 毎月1日 | 12世代 |

手動snapshot（大量書き込み前後など）はautoprune対象外なので個別にdestroyすること:
```bash
zfs snapshot tank-gen2/data/shared@pre-migration-YYYYMMDD
zfs destroy tank-gen2/data/shared@pre-migration-YYYYMMDD
```

ログ: `/var/log/mover.log`（logrotate: `files/infrastructure/storage/mover.logrotate` を `/etc/logrotate.d/mover` に配置）
