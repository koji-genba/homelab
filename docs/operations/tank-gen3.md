# tank-gen3運用

この文書はai・archiveの切り替え完了時に適用する運用契約である。構築・移行の実施記録や
再起動試験の合格を意味しない。[ADR-0010](../adr/0010-tank-gen3-cold-pool.md)、
[NFS export契約](nfs-export.md)、[ホスト復旧](proxmox-host-recovery.md)を併せて参照する。

## poolとdataset

| 項目 | 設定 |
| --- | --- |
| pool | `tank-gen3`、Seagate BarraCuda ST24000DM001-3Y7103 24TB ×2 mirror、FW DN02 |
| disk全体のby-id | `ata-ST24000DM001-3Y7103_ZXA2KJFS`、`ata-ST24000DM001-3Y7103_K1N00Y6B` |
| 接続 | LSI SAS2008 / SAS9211-8i、FW 20.00.07.00 |
| 作成時 | `ashift=12` |
| poolのdataset既定値 | `compression=lz4`、`atime=off`、`xattr=sa`、`dnodesize=legacy` |
| mountpoint | `/mnt/tank-gen3`、用途別は`/mnt/tank-gen3/data/<用途>` |
| `data/ai` | `recordsize=1M`、通常のsnapshot取得対象外 |
| `data/archive` | `recordsize=1M`、投入・検証ごとに`@verified-YYYYMMDD`、通常`readonly=on` |

CMRの製品で、HAMR採用の可能性は高いが、当該型番・FWのメーカーによる直接の明記は未確認。
HAMR採用を断定して保守方針を変えない。導入前のSMART long test合格を必須にする。
long testは読み出しの検査であり、ホストからの全面書込み検査の代わりではない。

## 起動とscrub

poolを作成・importしたら、`systemd-escape --template=zfs-import@.service tank-gen3`で生成した
`zfs-import@tank\x2dgen3.service`を必ずenableする。既にimport済みのpoolにunitをstartしない。
全5 poolの個別importを揃え、次の計画再起動でimport → dataset mount → NFSの順とclient復帰を確認する。

Debianの既定scrubからこのpoolだけを外す。

```sh
zfs set org.debian:periodic-scrub=disable tank-gen3
```

`/etc/systemd/system/tank-gen3-scrub.service`:

```ini
[Unit]
Description=Quarterly scrub of tank-gen3
After=zfs-import.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/zpool scrub tank-gen3
```

`/etc/systemd/system/tank-gen3-scrub.timer`:

```ini
[Unit]
Description=Quarterly tank-gen3 scrub
[Timer]
OnCalendar=*-01,04,07,10-01 03:30:00
Persistent=false
Unit=tank-gen3-scrub.service
[Install]
WantedBy=timers.target
```

ホストのローカル時刻で1・4・7・10月の1日03:30に開始し、第2日曜の既存pool scrubと重ねない。
`Persistent=false`で停止期間分の起動直後の追いつき実行を避ける。予定日に停止していた場合は
他poolのscrub・long testと重ならない保守枠で手動実行し、完了とエラー数を記録する。
他の仕組みでtank-gen3の月次timerが有効なら停止・無効化し、二重実行を防ぐ。

```sh
systemctl daemon-reload
systemctl enable --now tank-gen3-scrub.timer
systemctl list-timers --all '*scrub*'
zpool status tank-gen3
```

## ドライブ監視

pve1のsmartmontools 7.5に同梱の`smartd.conf(5)`のDEVICESCAN節を確認した。
DEVICESCAN以降の行は無視される。先行する個別行と同じデバイスはscanから除外され、
比較時にはsymlinkが解決され、同一identify情報でも重複が除外される。
したがって、次の個別2行を既存DEVICESCANの**前**に置き、既存diskの監視を維持する。
`-l scterc,70,70`はsmartd起動時にだけ適用される（単位は0.1秒）。

```text
/dev/disk/by-id/ata-ST24000DM001-3Y7103_ZXA2KJFS -a -n standby -m root -M exec /usr/share/smartmontools/smartd-runner -l scterc,70,70 -W 4,45,50 -R 193
/dev/disk/by-id/ata-ST24000DM001-3Y7103_K1N00Y6B -a -n standby -m root -M exec /usr/share/smartmontools/smartd-runner -l scterc,70,70 -W 4,45,50 -R 193
DEVICESCAN -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner
```

`/etc`の既存ファイルは編集前に時刻入りbackupを取る。smartd再起動後は、両serialのopen・監視登録、
ERCのread/writeが7.0秒であることをjournalと`smartctl -l scterc`で確認する。
電源断後のERC保持を前提にせず、再起動後にも確認する。
`-W 4,45,50`は温度差4℃、45℃以上の情報ログ、50℃以上の重大ログ・通知を設定する。
負荷停止や電源断を自動実行する設定ではない。冷却と既存のroot宛通知経路を確認する。

スピンダウンは使わず、EPCのstandby_zは無効のまま、PUISも有効にしない。
NFSのアクセス待ちと回転開始・停止の反復を避ける。idle_bは既定の10分でのヘッド退避を維持する。
`Load_Cycle_Count`（SMART 193、定格60万回）は値と通電時間を定期的に記録し、
前回からの増分/日を見て退避が過度に繰り返されていないか判断する。
併せて代替済み・代替待ち・訂正不能・CRCの増加、温度とSCT温度履歴の最大値を確認する。

## 移行とNFSの切り替え条件

旧`tank-gen2/data/ai`と`tank-gen1/data/archive`は子datasetがないことを確認してから、
writer稼働中に初回snapshotをsendし、`recv -u`で新datasetを作る。mountpointとrecordsizeは受信時に指定する。
archiveは旧recordsizeが128Kでも、受信時の1M指定で既存ブロックは書き直されない。
移行用のai snapshotは通常運用の保持対象に加えず、切り戻し不要の確認後に明示的に整理する。

Appsのstorage roleは`state: mounted`でfstabを更新し、その後`findmnt`で参照元・nfs4・ro/rwを検証する。
既存mountのsourceが変わる場合、fstab更新だけで正しい参照元への付け替えが完了するとは限らない。
writerを停止し、旧mountを**明示的に通常unmount**してからAnsibleを適用する。busyなら原因を調べ、
`-l`や`-f`で隠さない。mount guardはmarker名・値に加えsourceも検査するため、旧mountでは通らない。

初回転送後、reconcileのtimer停止・実行終了・既存pause/pending確認、新規pause作成の順で競合を防ぐ。
Appsのhf-downloaderとSambaは既存checkoutのCompose定義でdownする。project別systemd serviceは存在しない。
archiveのwriterはSamba `[archive]`のみだが、確実な停止のためSamba container全体を停止する。
DGXは利用者がwriterを止め、両機の`mnt-ai.automount`とmountを外す。

差分sendのGUID一致を確認して旧datasetをreadonly・非exportにし、新datasetをmountしてからexportを再読込する。
ai markerの`10002:10002`、archive markerの`0:0`と、それぞれ0644・値を保持する。
旧datasetは検証完了まで残し、削除は別作業とする。
移行後のtank-gen1は、アーカイブの2つ目のコピーの置き場にする案（未決定）。

両exportが揃ったら、切り替え用branchの同じ定義からAnsibleを適用し、mount guard、DGX、
Samba readと小さいhf-downloader取得を確認する。mainへのマージは切り替えの完了時とする。
Ansibleはアプリやtimerを起動し得るので、差分send前には適用しない。

## archiveへの追加

Samba writerを停止・確認してから`readonly=off`へ変更し、追加作業中だけwriterを再開する。
追加後にwriterを再停止し、内容・所有者・代表ファイルのchecksumを検証してから
`@verified-$(date +%Y%m%d)`を取得し、`readonly=on`へ戻す。通常はSambaも含め読取りだけになる。
同日のverified snapshotが既存なら上書き・削除せず、保持方法を判断してから進める。
検証snapshotは同じpool上の世代であり、別媒体backupの代わりではない。
