# tank-gen1 の作業用ストレージ（scratch）

2026-11-05に[issue #186](https://github.com/koji-genba/homelab/issues/186)の設計を以下の手順で**反映済み**。
pve1のdataset・export、Appsのmount・guard・Samba、両DGXのmountと書き込み、
WindowsからのSMB作成・読み取り・削除を確認した。反映後の使用量は116K / quota 3T。
実施記録は手順1〜6に記載し、残る確認事項は「未検証の項目」にまとめる。

## 目的と消失許容

`tank-gen1`（TOSHIBA MD04ACA400 4TB ×2 mirror、導入前は空き約3.5TiB）を、
消えても困らないものを雑に置く作業用の置き場にする。スナップショット・バックアップ・復元・自動削除は無し。
唯一のコピーや機密情報を置かず、不要になったデータは利用者が消す。共有データは誰でも消せる。
mirrorは復元手段ではない。入口のsticky bitはroot所有の目印とREADMEを利用者の削除から守るが、
NFS利用者は全て同じUIDへsquashされるので、利用者同士の削除を分離しない。

当面の利用者はDGX 2台（NFS）と作業端末（Apps VMのSamba経由）だけ。
Appsの他のcontainerには渡さず、mergerfs・mover・snapshot jobの対象にも加えない。

## pve1の契約

| 項目 | 値 |
| --- | --- |
| dataset | `tank-gen1/data/scratch` |
| mountpoint | `/mnt/tank-gen1/data/scratch`（`tank-gen1`の`/mnt/tank-gen1`から継承） |
| property | `recordsize=1M,compression=lz4,atime=off,xattr=sa,quota=3T` |
| 同期とexport管理 | `sync=standard`（既定）、`sharenfs=off`。`/etc/exports`で管理 |
| 共有入口 | `root:10004`、`1775`（sticky） |
| marker | `.homelab-export`、内容`scratch`、`printf '%s\n' scratch`で作成、`root:root 0644` |
| README | `README-DISPOSABLE.txt`、`root:root 0644`、日英で消失許容を表示 |
| client | Apps `192.168.10.101/32`、DGX `192.168.10.51/32`・`192.168.10.52/32` |
| export option | `rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004`、`fsid`無し |

UID `10002`はSambaの`koji-genba`、GID `10004`は`samba-users`。
NFSの全アクセス（rootも含む）は`10002:10004`になる。`async`はpve1異常停止で応答済みの書き込みも
失う可能性を受け入れる設定で、ZFSの`sync=standard`とは別である。
起動時の`zfs-import@tank\x2dgen1.service`と既存の月1回の汎用scrubは維持する。

容量は`quota=3T`で制限する。圧縮・metadataによって実データ量は変わり、他poolへの自動退避はしない。
`zpool list tank-gen1`と`zfs list -o name,used,avail,quota tank-gen1/data/scratch`で残量を見る。
MD04の通電時間は53,336時間と38,694時間。2026-11-04のSMART採取結果は異常なしだったが、
古いディスクの残寿命を保証しない。scrubは維持し、唯一のコピーを置かない前提を変えない。

## AppsのmountとSamba

`nfs_mounts`に`name: scratch`、server `192.168.10.11`、export `/mnt/tank-gen1/data/scratch`、
local path `/srv/homelab/nfs/scratch`、marker `.homelab-export` / `scratch`を宣言する。
optionsは既存rw mountと同じ
`hard,_netdev,nfsvers=4.1,noatime,rsize=1048576,wsize=1048576,timeo=600,retrans=2,nconnect=8`。
cutover有効時はstorage roleが`rw`を付ける。
`scratch_mount_path`から`compose.env`の`SCRATCH_MOUNT_PATH`を生成し、
既存共有と同じ短いbind構文でSambaの`/mnt/scratch`へ渡す。

共有は`\\samba.kojigenba-srv.com\scratch`。`[scratch]`は`valid users = @samba-users`、
`writable = yes`、`browseable = yes`、`create mask = 0664`、`directory mask = 0775`、
commentは`Disposable workspace - no snapshots or backups`。
maskは許可bitの上限であり、clientが要求しないgroup書き込みbitを強制付与しない。
2026-11-05にはDGXから作ったファイルがpve1で`10002:10004`・`664`になることと、
WindowsのSMBで作成・読み取り・削除できることを確認した。

## 反映手順（PRは1本）

以下は2026-11-05に実施した手順で、将来作り直す際にも使う。各実機操作には別途明示の承認が必要。
順序はpve1準備 → reconcile停止 → PRブランチからAnsible → merge → main反映 → DGXとする。

### 1. pve1の準備

実施記録（2026-11-05 00:18）: スクリプトでdatasetを作成し、上表のproperty・継承mountpoint、
入口`root:10004 1775`、marker（`scratch`）とREADMEの`root:root 0644`を確認した。
`/etc/exports`をバックアップして1行だけ追記し、`exportfs -ra`後の`exportfs -v`で
3 clientの`/32`と`async,no_subtree_check,anonuid=10002,anongid=10004,rw,root_squash,all_squash`を確認した。
既存6 exportに変更がないことと全poolのhealthyも確認した。

pve1のrootで現状のdataset・mountpoint・exportを確認する。既存datasetがある場合は作成を再実行せず差分を調べる。
親`tank-gen1/data`が存在し、`/mnt/tank-gen1/data`を継承していることを先に確認する。

```sh
zfs get mountpoint tank-gen1 tank-gen1/data
zpool status tank-gen1
cp -a /etc/exports "/etc/exports.bak.$(date +%Y%m%dT%H%M%S)"
exportfs -v
zfs create -o recordsize=1M -o compression=lz4 -o atime=off -o xattr=sa \
  -o quota=3T -o sharenfs=off tank-gen1/data/scratch
findmnt -M /mnt/tank-gen1/data/scratch
chown root:10004 /mnt/tank-gen1/data/scratch
chmod 1775 /mnt/tank-gen1/data/scratch
printf '%s\n' scratch > /mnt/tank-gen1/data/scratch/.homelab-export
cat > /mnt/tank-gen1/data/scratch/README-DISPOSABLE.txt <<'README'
消えてもよい作業用の置き場。スナップショット・バックアップ・復元は無い。
唯一のコピーや機密情報を置かない。誰でも消せる。
自動削除は無いので要らなくなったら自分で消す。
DGX は /mnt/scratch、SMB は \\samba.kojigenba-srv.com\scratch

Disposable workspace. No snapshots, backups, or recovery.
Do not store the only copy of anything or confidential information. Anyone can delete data.
There is no automatic cleanup; delete your data when you no longer need it.
DGX: /mnt/scratch; SMB: \\samba.kojigenba-srv.com\scratch
README
chown root:root /mnt/tank-gen1/data/scratch/.homelab-export /mnt/tank-gen1/data/scratch/README-DISPOSABLE.txt
chmod 0644 /mnt/tank-gen1/data/scratch/.homelab-export /mnt/tank-gen1/data/scratch/README-DISPOSABLE.txt
```

markerは既存の[Open WebUI手順](open-webui.md)と同じ改行付き。
mount guardの`$(cat ...)`は末尾の改行を除いて値を比較する。Appsの未mount directoryには作らない。
`sync`は既定の`standard`を維持し、継承元で変更されていたら先に差分を解消する。
既存のexports行を変えず、次の1行だけを追加する（重複追加しない）。

```exports
/mnt/tank-gen1/data/scratch 192.168.10.101/32(rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004) 192.168.10.51/32(rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004) 192.168.10.52/32(rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004)
```

```sh
exportfs -ra
exportfs -v
zfs get mountpoint,recordsize,compression,atime,xattr,quota,sync,sharenfs tank-gen1/data/scratch
stat -c '%u:%g %a %n' /mnt/tank-gen1/data/scratch /mnt/tank-gen1/data/scratch/.homelab-export /mnt/tank-gen1/data/scratch/README-DISPOSABLE.txt
cat /mnt/tank-gen1/data/scratch/.homelab-export
zfs list -t snapshot -r tank-gen1
```

上表のproperty・owner/mode、marker値、3 clientの有効exportを照合し、既存exportが変わっていないことと
snapshot jobの対象でないことを確認する。この段階ではAppsとDGXの宣言は変わらない。

### 2. Appsのreconcileを一時停止

実施記録（2026-11-05 00:22〜00:25）: timerを停止し、作業用pauseを作成した。
Ansibleがtimerをstartし直したが、00:23のreconcileは`project=paused result=skipped`だった。

Appsでtimerを止め、実行中serviceが終了するまで待つ。途中で強制停止しない。

```sh
sudo systemctl stop homelab-app-reconcile.timer
systemctl is-active homelab-app-reconcile.service
sudo ls -l /var/lib/homelab/reconcile.paused /var/lib/homelab/reconcile.pending
```

`deploy`は`/var/lib/homelab`（`root:root 0750`）内を参照できないため、pause・pendingの有無は`sudo`を付けて確認する。
serviceがinactiveになったこと、既存pause/pendingの有無と理由を確認する。
pendingがあれば対象と再反映の扱いを[共通手順](application-lifecycle.md#rollbackと再開)で確認し、消さない。
既存pauseがあれば上書き・解除せず、理由を解決してから続ける。
既存pauseが無い場合だけ`sudo touch /var/lib/homelab/reconcile.paused`で作業用pauseを作ったことを記録する。
Ansibleはtimerをstartedへ戻すので、timer停止だけでは競合を防げない。

### 3. 管理端末のPRブランチからAnsible

実施記録（2026-11-05 00:22〜00:25）: PRブランチから`make ansible-apply`を実施し、
`ok=108, changed=10, failed=0`。`compose.env`変更で全projectを再作成した。
Appsでscratchのsource、`nfs4`・`rw,vers=4.1,nconnect=8`、marker、guard本体の直接実行、
`SCRATCH_MOUNT_PATH`を確認し、全13コンテナのrunning/healthyとAdGuardのDNS応答を確認した。

管理端末で`feat/tank-gen1-scratch`のPR内容と必要なssh-agent・age identityの準備を確認し、
**mainへのmerge前にPRブランチで**`make ansible-apply`を実施する。
AnsibleはAppsの既存`/opt/homelab`を更新しない。そこで動くSambaはまだ既存共有のまま。
`compose.env`変更によって全projectが作り直されるので、AdGuardのDNSとSMBが短く止まる。

Appsで確認する。

```sh
findmnt -M /srv/homelab/nfs/scratch -o SOURCE,FSTYPE,OPTIONS
cat /srv/homelab/nfs/scratch/.homelab-export
sudo /usr/local/sbin/homelab-mount-guard
systemctl status homelab-apps.service
```

sourceが`192.168.10.11:/mnt/tank-gen1/data/scratch`、fstypeが`nfs4`、`rw`・`nconnect=8`、
markerが`scratch`であることを確認する。guard unitがactiveというだけで済ませず本体を実行する。
全12 projectの`docker compose ps`と既存のDNS・SMB・HTTPサービス、Gatus・dead-manの復帰を確認する。
失敗したらpauseを維持して原因を直し、mergeへ進まない。

### 4. PRをmainへmerge

実施記録（2026-11-05、Ansible確認後・00:30の再開前）: PR #191・#192をmainへmergeした。

手順3の実機確認後、同じPRをmainへmergeする。作業用pauseを維持する。
実施結果を日付付きで記録し、未検証の項目は確認できるまで残す。

### 5. Appsをmainへ進めてSambaを公開

実施記録（2026-11-05 00:30〜00:31）: 作業用pauseを外し、reconcileを1回実行した。
`/opt/homelab`をmainへfast-forwardし、`.env.example`変更で全projectを再作成した。
約1分40秒で全コンテナがhealthy/runningに戻り、AppsのHEADとmainの一致、pendingが空であること、
Sambaのhealthy、`/srv/homelab/nfs/scratch` → `/mnt/scratch`のrw bind、
`testparm -s`の`[scratch]`を確認した。匿名の共有一覧は`valid users = @samba-users`どおり拒否された。
同日、運用者がWindowsの`\\samba.kojigenba-srv.com\scratch`で作成・読み取り・削除を確認した。

Ansibleで追加したmount/env/guardが残っていることを確認し、この作業で作ったpauseだけを外す。
既存checkoutをmainへ進める処理はreconcileに任せる。

```sh
sudo rm /var/lib/homelab/reconcile.paused
sudo systemctl start homelab-app-reconcile.service
sudo systemctl start homelab-app-reconcile.timer
sudo journalctl -u homelab-app-reconcile.service -n 100 --no-pager
```

reconcileが`/opt/homelab`をmainへfast-forwardし、Sambaを再作成して`[scratch]`を公開する。
このPRは`.env.example`も更新するため、この段階でも**全12 projectが再作成される**。
Homepageのscratchカードもこの段階で反映される。journal・deployments記録・pending残存を確認する。
Sambaの`docker compose ps`、container内`testparm -s`、`/mnt/scratch`のbindとmarkerを確認し、
認証済みSMBでファイル・directoryの作成、読み取り、削除を試す。作成物の数値UID/GIDとmodeも照合する。
rootのmarkerとREADMEがSMBから削除できないこと、既存共有・DNS・他projectの復帰も確認する。
匿名共有一覧のhealthcheck成功だけでは、認証付きの読み書き確認を代替しない。

### 6. DGXのfstab（ユーザーが2台とも実施）

実施記録（2026-11-05、時刻記録なし）: 運用者が両DGXのfstabへscratchを追加してautomountを開始した。
`.51`・`.52`ともscratch行が1つ、`mnt-scratch.automount`と`mnt-scratch.mount`がactive、
`nfs4`・`rw,vers=4.1,nconnect=8`、marker `scratch`を確認し、`/mnt/ai`（tank-gen3）は維持された。
DGXから作成したファイルがpve1で`10002:10004`・`664`となり、all_squashで所有者が揃うことを確認した。試験ファイルは削除済み。

aiのfstab行は変更せず、次の1行を追加する。反映前にfstabをバックアップし重複がないか確認する。

```fstab
192.168.10.11:/mnt/tank-gen1/data/scratch /mnt/scratch nfs4 hard,_netdev,nfsvers=4.1,noatime,rsize=1048576,wsize=1048576,timeo=600,retrans=2,nconnect=8,x-systemd.automount 0 0
```

```sh
sudo mkdir -p /mnt/scratch
sudo systemctl daemon-reload
sudo systemctl start mnt-scratch.automount
ls /mnt/scratch
findmnt -M /mnt/scratch -o SOURCE,FSTYPE,OPTIONS
cat /mnt/scratch/.homelab-export
probe=$(mktemp /mnt/scratch/.write-test.XXXXXX)
printf 'scratch test\n' > "$probe"
stat -c '%u:%g %a %n' "$probe"
rm "$probe"
```

期待値はscratchのsource、`nfs4`、`rw`、`vers=4.1`、`nconnect=8`、marker `scratch`。
一般ユーザーで書き込みを試し、SMB→両DGX、DGX→SMB、DGX同士でも読み書き・削除を確認する。
`mktemp`は通常0600を使うため、通常の作業で作ったfile/directoryのmodeも別途確認する。
all_squashによりDGXから見た持ち主は全て10002。DGXから`chown`はできず、gitが所有者の警告
（safe.directory）を出すことがある。信頼した作業directoryだけ個別に扱う。
同じファイルの同時編集の整合性を保証する用途にはしない。

## 未検証の項目

- READMEとmarkerをSMB・DGXから削除しようとした際に、stickyで拒否されること。削除試験は未実施。
- pve1・Apps再起動後のscratch自動mountとguard通過。再起動は未実施。
- 大きなファイルの転送速度。計測は未実施。

## mount guardの波及と障害時の切り離し

ユーザーはscratch障害による全projectへの起動依存を受け入れた。
guardは全projectの起動・更新前に全mountを検査するので、scratchの不在・marker不一致でも全体が止まる。
既存containerを一斉停止する意味ではないが、再起動や更新、起動時の復旧が妨げられる。
`RequiresMountsFor`も全mountを含み、`hard` NFSやpoolの`failmode=wait`で処理自体が待つ場合もある。

scratchだけを切り離して他projectを復旧する場合は、承認を得て次の順に実施する。

1. 手順2と同じ方法でreconcileを停止・pauseし、SMB/DGXのscratch利用を止める。
   Sambaを旧定義がある間に停止する。停止もNFS I/O待ちで完了しない場合は、強制unmountへ進まず保守を判断する。
2. 復旧用の変更でSambaのscratch bindと`[scratch]`、Homepageカードを外す。
   `apps.yml`とexampleのscratch `nfs_mounts`宣言、`scratch_mount_path`、templateとexampleの
   `SCRATCH_MOUNT_PATH`、検証用envも外す。
3. scratchを外したComposeをAppsへ用意してから、同じ宣言を持つ管理端末で`make ansible-apply`する。
   通常reconcileはguardを通ってから起動するため、まだscratchを参照するApps checkoutのまま適用しない。
   pause中にreview済みmainへcheckoutを進める場合はclean状態とfast-forwardを確認し、
   [project撤去の共通手順](application-lifecycle.md#projectの撤去共通手順)の順序管理に従う。
4. Ansibleは削除した宣言をunmountもfstab削除もしない。Appsの`/etc/fstab`からscratchの行だけを外し、
   `sudo systemctl daemon-reload`後、利用が止まってから`sudo umount /srv/homelab/nfs/scratch`する。
   新guardとunitにscratch依存が無いこと、guard本体、全projectの起動とDNS・既存SMBの復帰を確認する。
5. 作業用pauseだけを解除しreconcileとtimerを再開する。DGXのfstab整理もユーザーが行う。
   原因を直してscratchを再導入する場合は、本ページの1〜6を再び使う。

## 撤去と復旧

恒久撤去は上の切り離しに加え、両DGXでscratchの利用を止め、fstabのscratch行を外し、
`mnt-scratch.automount`を停止、`/mnt/scratch`をunmountしてdaemon-reloadする。aiは維持する。
全clientのmountと利用が無くなってからpve1のexportsをバックアップし、scratch行だけを削除して
`exportfs -ra`・`exportfs -v`で確認する。dataset削除は別途明示の承認を得て、対象を照合した上で
`tank-gen1/data/scratch`だけを削除する。pool・親dataset・import unit・月次scrubは残す。

pool喪失時には中身を戻さない。pool自体が利用可能になったらdataset・property・入口権限・
marker・README・exportを手順1で作り直し、client mountとguard・SMBを確認する。
[ホスト復旧](proxmox-host-recovery.md)も同じ契約を使う。
