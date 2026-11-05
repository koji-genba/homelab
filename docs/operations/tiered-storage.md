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
  └─ data/archive  → Apps Samba（書き込み可、毎日04:30に自動snapshot）
tank-gen1/data/scratch → DGX / Apps Samba（消失許容、quota 3T、snapshot無し）
  ※ 2026-11-05反映・確認済み
tank-gen1/data/hermes → Runner / Apps Samba（受け渡し、quota 2T、snapshot/backup無し、実機未反映）
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
| tank-gen1 | Toshiba MD04ACA400 ×2 (mirror) | [scratch作業用](scratch-storage.md)（quota 3T、snapshot/backup無し。2026-11-05反映・確認済み）と [Hermes共有](hermes-share.md)（quota 2T、実機未反映） |
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
`shared-hdd`は`sync`のまま維持し、2026-10-29に`async`へ変更した`shared`とは永続化の条件が異なる。

## 設定

### /etc/fstab（mergerfsマウント）

```
/mnt/cache-sata:/mnt/tank-gen2/data/shared  /mnt/shared  fuse.mergerfs  defaults,cache.files=off,dropcacheonclose=false,category.create=ff,inodecalc=path-hash,func.getattr=newest,fsname=mergerfs-shared,noforget,x-systemd.requires=zfs-mount.service  0  0
```

`inodecalc=path-hash`: moverによってファイルがSSD→HDDに移動してもinode値が変わらない。NFS経由でstale handleが出るのを防ぐ。

`noforget`: NFSのファイルハンドルの安定性のため、2026-10-29にpve1のfstabへ追加し、mergerfsをマウントし直して反映済み。
mergerfsプロセスの引数に`noforget`があることと、markerを確認した。

マウントし直す際はApps VMを停止し、pve1で`exportfs -u`の後に`exportfs -f`で
カーネルのNFS exportキャッシュを破棄してから`systemctl stop mnt-shared.mount`する。
2026-10-29の保守では、`exportfs -u`だけではキャッシュがマウントを参照し続け、
ユーザー空間のプロセスが掴んでいなくても`umount`がbusyになった。
fstabを変更した場合は`systemctl daemon-reload`の後、`systemctl start mnt-shared.mount`で戻す。
再マウント後は`exportfs -ra`で再exportしてからApps VMを起動する。
停止・export解除済みで単に再マウントする場合も、`systemctl restart mnt-shared.mount`などunitを通す。

2026-10-31の停電試験では、10-29にSSHから手でmountし直したmergerfsがsession-398.scopeに残り、
ホスト停止開始と同時の20:14:59にSIGTERMを受けた（運用者のログ確認）。再起動後は
`0::/system.slice/mnt-shared.mount`配下になった。SSHから直接mountしてセッションのcgroupへ残さず、
再マウントは上記のsystemd unit経由とする。Apps停止・export解除・キャッシュ破棄の前提は省かない。
VM→NFS→mergerfsの順序修正は[UPS運用](ups-nut.md#pve-guestsとnfsの順序)を参照する。

`x-systemd.requires=zfs-mount.service`: `zfs-mount.service`へのRequires / After依存を加え、
ZFSより先にmergerfsがmountされるのを防ぐ。2026-10-27にpve1へ反映し、再起動で順序を確認した。
poolの起動時importは全poolの個別`zfs-import@`を有効にする方式に揃える。
新しいpoolを追加する場合も登録を必須とし、手順と確認範囲は
[ホスト復旧手順](proxmox-host-recovery.md#データpoolのimportとmergerfs)を参照する。

### /etc/exports

client scope、option、fsidは[NFS export契約](nfs-export.md#実測された親export)を参照する。
2026-10-29から`shared`（`/mnt/shared`）だけを`async`とし、ファイルごとのCOMMIT待ちを軽減した。
pve1の異常停止時には完了応答済みの直近数秒程度の書き込みを失う危険を受け入れる。
既存の`shared-hdd`とほかのexportは`sync`を維持する。sharedの変更理由・計測・残課題は
[2026-10の調査記録](smb-performance-troubleshooting.md#2026-10-小さめのファイルを大量に書くと速度が出ない)を参照する。
2026-11-05に[scratch](scratch-storage.md)を3 clientの`/32`へ
`async,all_squash,anonuid=10002,anongid=10004`で追加済み。Apps・両DGXのmount、
DGXでの所有者統一とWindowsのSMB作成・読み取り・削除を確認した。残る確認事項は同運用手順を参照する。
FUSEファイルシステムはカーネルがfsidを自動取得できないため`/mnt/shared`に`fsid=100`を明示。
`/mnt/tank-gen2/data/shared`にも`fsid=101`を明示して、NFS再起動・mergerfs再マウント後のstale file handleを避ける。
既存4 exportはApps VMの`/32`へ制限し、DGXも使う`ai`は`/24`だったが、[Hermes共有](hermes-share.md)追加時にApps・両DGXの3つの`/32`へ絞る（未実施）。
新規hermesはApps・Runnerの2つの`/32`のみ、async・all_squash、snapshot/backup無しとする。
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
2026-11-04の補足: 上記の旧版backupは削除済み。

## ZFS snapshotポリシー

moverの対象: `tank-gen2/data/shared`のみ（スクリプトの`DATASET`で指定し自動取得）。
この自動取得には`cache-pool`上の残存ファイル、`ai`、`archive`、`k8s-volumes`、`scratch`、`hermes`（追加予定）、VM内named volumeは含まれない。
`archive`は別の`archive-snapshot.sh`で毎日04:30に自動取得する（後述）。
`k8s-volumes`には自動snapshotがなく、2026-11-04に最後の手動snapshotも削除した。
取得方針の統一は[issue #185](https://github.com/koji-genba/homelab/issues/185)、
名前を変えるかは[issue #190](https://github.com/koji-genba/homelab/issues/190)で扱う。
snapshotは同じdataset上の世代保持であり、backupと同義ではない。SSDに残るファイルの復旧方針と、
pool喪失に備える別媒体へのbackupは別に確認する。保持世代の正は各スクリプトのprune処理である。

| 種別 | タイミング | 保持世代 |
|---|---|---|
| 日次 | 毎日（月次・週次以外） | 14世代 |
| 週次 | 月曜 | 8世代 |
| 月次 | 毎月1日 | 12世代 |

archiveは書き込み可能な`tank-gen3/data/archive`を対象に、毎日`daily-YYYYMMDD`を14世代、
毎月1日に`monthly-YYYYMMDD`を12世代、月初以外の月曜に`weekly-YYYYMMDD`を8世代保持する。
moverは上表どおり1日1種類だが、archiveは日次を毎日取り、日付もハイフンなしにする。
変更のない日も取得する。同日の既存snapshotは維持し、未mount・dataset不在ならエラーで停止する。
自動削除は対象dataset直下の3種類の接頭辞と8桁日付に一致する名前のみ。
2026-11-04にarchiveの`@to-gen3-1`・`@to-gen3-2`を削除し、初期記録は`@verified-20261031`だけを保持する。
これは自動削除の対象外のままとし、保持の見直しは#185で扱う。
配置・root cron（`30 4 * * * /usr/local/bin/archive-snapshot.sh`）・logrotateの手順は
[tank-gen3運用](tank-gen3.md#archiveの自動snapshot)を参照する。repoからの自動適用はしない。
ログは`/var/log/archive-snapshot.log`、logrotateは`files/infrastructure/storage/archive-snapshot.logrotate`を
`/etc/logrotate.d/archive-snapshot.logrotate`へ手動配置する。

手動snapshot（大量書き込み前後など）はautoprune対象外なので個別にdestroyすること:
```bash
zfs snapshot tank-gen2/data/shared@pre-migration-YYYYMMDD
zfs destroy tank-gen2/data/shared@pre-migration-YYYYMMDD
```

2026-11-04 23:57に、了承を得て`tank-gen2/data/shared@migrate`（2025-12-13作成、6.77G）を削除した。
旧tank（現在のtank-gen1）からtank-gen2への移行時に、送信元で取得して同日にreceiveした記録だった。
保持していたのは移行後に削除したファイル約7GBだけで、内容を書き換えたファイルの旧版は無かった。
差分の「変更」はメタデータだけであることを確認し、運用者が不要と判断した。
同時に`tank-gen2/data/k8s-volumes@pre-phase5-retire-20260923`（58.7M）も了承を得て削除した。
これは撤去時に削除したPVC directory 8件を戻せる最後のsnapshotで、現在は復旧に使えない。
削除後に残すものの現存と全poolのhealthyを確認した。

ログ: `/var/log/mover.log`（logrotate: `files/infrastructure/storage/mover.logrotate` を `/etc/logrotate.d/mover.logrotate` に配置）
