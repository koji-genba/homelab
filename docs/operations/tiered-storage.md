# Tiered Storage (mergerfs + ZFS)

pve1上のtank-gen2に対してSSDライトキャッシュ層をmergerfsで構成する。

## アーキテクチャ

```
書き込み  → /mnt/shared (mergerfs)
                ↓ 新規ファイルはSSD優先 (category.create=ff)
            /mnt/cache-sata  (cache-pool: KIOXIA EXCERIA ×2 mirror)
                ↓ 毎朝5時 mover.sh (cmin+30でsettle判定)
            /mnt/tank-gen2/data/shared  (Toshiba N300 ×2 mirror, 20TB)
                ↓ mover完了後にZFS snapshot

読み込み  → /mnt/shared から透過的にアクセス（SSD・HDD問わず）
            tank-gen2のread cache → M8VC L2ARC (476GB)

tank-gen3 (Seagate BarraCuda 24TB ×2 mirror)
  ├─ data/ai       → DGX / Apps（SSDキャッシュ・mover対象外）
  └─ data/archive  → Apps Samba（通常readonly、verified snapshot）
tank-gen1 → アーカイブの2つ目のコピーの置き場にする案（未決定）
vmpool → VM disk

pve1 /mnt/shared (NFS export)
  → Apps VM /srv/homelab/nfs/shared
  → Compose Samba container /mnt/shared → Windows SMB
```

SMB経路の宣言は`files/infrastructure/ansible/apps/group_vars/apps.yml`の`shared_mount_path`と
`files/services/compose/samba/compose.yaml`のbind mountで確認する。

## コンポーネント

| コンポーネント | デバイス | 役割 |
|---|---|---|
| cache-pool | KIOXIA EXCERIA SATA SSD ×2 (mirror) | mergerfsライトキャッシュ |
| tank-gen2 | Toshiba N300 ×2 (mirror) | 実体ストレージ |
| tank-gen3 | Seagate ST24000DM001 24TB ×2 (mirror) | ai・archive。運用は[tank-gen3](tank-gen3.md) |
| tank-gen1 | Toshiba MD04ACA400 ×2 (mirror) | アーカイブの2つ目のコピーの置き場にする案（未決定） |
| vmpool | WD_BLACK SN770 1TB | VM disk |
| M8VC | Plextor PX-512M8VC 476GB | tank-gen2 L2ARC |
| /mnt/shared | mergerfs union mount | クライアントから見えるパス |

## 設計判断メモ

**category.create=ff**
SSDを先頭ブランチに置き、常にSSD優先で書き込む。`minfreespace`（デフォルト4GB）を下回ったら自動的にHDDにフォールバックするので「SSD満杯ならHDDに書く」は追加設定不要。

**settling time判定にctimeを使う**
一部ディレクトリでWindowsクライアントがlastWriteTimeを過去日時に書き換える運用があるため、mtimeベースのsettling timeが機能しない。ctimeはカーネル管理でクライアントから変更不可なのでこちらを使う。

**cache-poolのSSDはマザーボードのSATA (AHCI) に接続する**
LSI SAS2008 HBA経由ではTRIMが通らない。SAS2008はRZAT/DRATビットを持つドライブだけをUNMAP対応と
報告し、KIOXIA EXCERIAはこのビットを持たないためである。moverが毎日書いては消すこのpoolでTRIMが
効かないと、書き込みレイテンシが48msまで悪化した実績がある
（[SMB転送速度トラブルシューティング](smb-performance-troubleshooting.md#2026-09-速度が出たり0になったりを繰り返す)）。
`zpool status -t cache-pool`に`trim unsupported`が出ていないことと、`autotrim=on`を維持すること。

**nightly（毎朝5時）**
cache-poolの容量に対して日次書き込みが満杯になることはないため、随時moveではなくnightly実行。SSDが埋まったとしてもmergerfsのフォールバックで機能継続する。

**ZFS snapshotはmover完了後**
moverスクリプトの末尾で、settle条件を満たして移動できたHDD側の状態をsnapshotする。
最近変更されたファイルや転送中の変更でSKIPされたファイルはSSDに残りうるため、SSD上の残存データは含まれない。
転送失敗やowner mismatchのerrorsがあればsnapshotを見送る。

**/mnt/tank-gen2/data/sharedのNFS exportも残す**
mergerfsを通さない直接経路として維持。大事なデータのコピーやパフォーマンス比較用。

## 設定

### /etc/fstab（mergerfsマウント）

```
/mnt/cache-sata:/mnt/tank-gen2/data/shared  /mnt/shared  fuse.mergerfs  defaults,cache.files=off,dropcacheonclose=false,category.create=ff,inodecalc=path-hash,func.getattr=newest,fsname=mergerfs-shared,x-systemd.requires=zfs-mount.service  0  0
```

`inodecalc=path-hash`: moverによってファイルがSSD→HDDに移動してもinode値が変わらない。NFS経由でstale handleが出るのを防ぐ。

`x-systemd.requires=zfs-mount.service`: `zfs-mount.service`へのRequires / After依存を加え、
ZFSより先にmergerfsがmountされるのを防ぐ。2026-10-27にpve1へ反映し、再起動で順序を確認した。
poolの起動時importは全poolの個別`zfs-import@`を有効にする方式に揃える。
新しいpoolを追加する場合も登録を必須とし、手順と確認範囲は
[ホスト復旧手順](proxmox-host-recovery.md#データpoolのimportとmergerfs)を参照する。

### /etc/exports

client scope、option、fsidは[NFS export契約](nfs-export.md#実測された親export)を参照する。
FUSEファイルシステムはカーネルがfsidを自動取得できないため`/mnt/shared`に`fsid=100`を明示。
`/mnt/tank-gen2/data/shared`にも`fsid=101`を明示して、NFS再起動・mergerfs再マウント後のstale file handleを避ける。
既存4 exportはApps VMの`/32`へ制限し、DGXも使う`ai`だけを`/24`にする契約である。
2026-10-12にpve1の`exportfs -v`で、このclient範囲とfsidが契約どおりであることを確認した
（[確認記録](nfs-export.md#実測された親export)）。`/etc/exports`はrepoで管理していないため、変更時は`exportfs -v`で確認する。

## moverスクリプト

repoの実体は[`files/infrastructure/storage/mover.sh`](../../files/infrastructure/storage/mover.sh)で、
`/usr/local/bin/mover.sh`はpve1への手動配置先である。repoはこの配置・cronを自動適用しない。
pve1のfstab、autotrim、pool構成もApps VM向けAnsibleの適用対象ではない。

cron（毎朝5時）:
```
0 5 * * * /usr/local/bin/mover.sh
```

手動実行（書き込みが止まっている状態であれば任意タイミングでOK）:
```bash
/usr/local/bin/mover.sh
```

lockfileで二重起動を防止しているので、cronと手動が被っても安全。

移動時はファイルと親ディレクトリの所有者・modeをSSD側から引き継ぐ。
ファイルの数値UID/GIDが移動先と一致しない場合は元ファイルを残し、
`/var/log/mover.log`に`FAILED (owner mismatch)`を記録してsnapshotを見送る。
修正後の確認には、SSD側に小さなテストファイルと専用ディレクトリを作り、
`stat -c '%u:%g %a %n'`でそれぞれの属性を記録してから手動実行し、HDD側と比較する。
手動実行はsettle条件を満たすファイルをすべて対象にするため、書き込み停止中に行う。

既にHDD側で`root:root`になったものは自動修復されない。
`find /mnt/tank-gen2/data/shared -user root -print`で候補を確認し、
本来の所有者が確認できたファイル・ディレクトリだけを個別に修正する。
modeやmtimeは元のSSDディレクトリが削除されていると復元元がないため、
必要ならsnapshotなどで元の値を確認する。

2026-09-26に修正版をpve1へ反映した。旧版は
`/usr/local/bin/mover.sh.bak.issue48-20260926T000227`に保存した。
隔離した一時ディレクトリで`10002:10002`のファイルと親ディレクトリの
所有者・modeを保持することを確認済み。既存データの修復は別途完了済み。

## ZFS snapshotポリシー

対象: `tank-gen2/data/shared`のみ（moverスクリプトの`DATASET`で指定し自動取得）。
この自動取得には`cache-pool`上の残存ファイル、`ai`、`archive`、`k8s-volumes`、VM内named volumeは含まれない。
`archive`は別途、投入・検証ごとに`@verified-YYYYMMDD`を手動取得する。
snapshotは同じdataset上の世代保持であり、backupと同義ではない。SSDに残るファイルの復旧方針と、
pool喪失に備える別媒体へのbackupは別に確認する。保持世代の正は同スクリプトのprune処理である。

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

ログ: `/var/log/mover.log`（logrotate: `files/infrastructure/storage/mover.logrotate` を `/etc/logrotate.d/mover.logrotate` に配置）
