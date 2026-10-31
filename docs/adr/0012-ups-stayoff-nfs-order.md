# ADR-0012: UPS出力の手動復旧とVM・NFSの停止順を採用する

## 状態

承認済み（2026-10-31）。PR #172は同日20:49にpve1へ反映済み。
2026-11-01 01:50 JSTの商用電源ありFSD試験でstayoff・手動復旧・VM/NFSの停止と起動の順序を確認した。
[ADR-0011](0011-ups-nut-shutdown.md)のUPS自動復帰・pve1管理範囲の前提を一部置き換える。
NUT primary/secondary、DGXの120秒早期停止、LB50%/300秒、VM startupの順序と待ち上限は維持する。

## 背景

2026-10-31 20:00〜20:30 JSTの本番停電試験で、推論稼働中のDGX早期停止、pve1のLB/FSD、
VM停止、killpowerを確認した。一方、CPJ1200はondelay=120で出力断後に商用電源なしで出力を戻し、
DGXがバッテリーで自動起動した。pve1はユーザー設定のBIOSでAC復帰起動を無効にしており、手動起動だった。

pve1のNFSは20:15:00に止まり、pve-guestsの停止開始20:15:01より先だった。両unitに順序指定がなく、
Apps・Hermesのhard NFSが待たされた。書き込み中ならVM側の未送信データを失うおそれがある。
詳細な時系列・実測は[UPS運用](../operations/ups-nut.md)に記録する。

## 決定

NUTのdefaultsを `nut_offdelay: 60`、`nut_ondelay: -1` とし、ups.confへ出力する。
shutdown.returnを使う既存killpower経路は維持し、出力はstayoff相当で停止したままにする方針。
長い停電後は商用電源確認→UPSボタンで出力復旧→ネットワーク・DGX自動起動→pve1をボタンで起動→
pool/NFS/VM/Apps確認→推論手動起動とする。pve1のBIOSは手動起動のままにする。

NUT v2.8.1はondelayをstrtolで読み、shutdown.returnのload.on.delayへ渡し、CPSのDelayBeforeStartupへ
符号付きの-1を送れる（[usbhid-ups](https://github.com/networkupstools/nut/blob/v2.8.1/drivers/usbhid-ups.c)、
[CPS](https://github.com/networkupstools/nut/blob/v2.8.1/drivers/cps-hid.c)）。
採用時はソースで送信経路を確認し、CPJ1200での実動作は未検証としていた。11-01の実機確認結果は下記に追記する。
sdcommandsは2.8.1にないため使わない。
-kはまず稼働中driverへdriver.killpowerを頼むため、ups.conf変更はdriverのrestartまで反映する。
ondelay=0による復電待ち自動復帰は将来の候補とし、CPJ1200で検証するまでは採用しない。

pve1 Ansibleに独立した `guest_nfs_order` roleを追加する。pve-guestsのdrop-inに
`After=nfs-server.service` を入れ、停止時はVM→NFS→mergerfs→ZFS、起動時はNFS→VMの順にする。
配置時はdaemon-reloadだけを行い、RefuseManualStart/Stopのpve-guestsをrestartしない。
管理範囲はNUT・VM startup・pve-guestsのNFS順序までとし、exports/mover/mergerfs/ZFS自体は引き続き対象外。

## 影響

停電中の予約再投入を避ける方針になり、復電だけで全機を自動復帰させる構成ではなくなる。
UPSが出力を止めた後はネットワークも停止するため、現地での電源操作が必要。
DGXはpve1より先に起動するのでNFS確認まで推論は開始しない。
Afterは既存のNFS起動・停止ジョブとの順序指定で、NFSサービスの起動成功を保証するものではない。

mergerfsがSSHのsession cgroupに残ると、systemdのmount順序とは別にSIGTERMを受け得る。
手動再mountはsystemdのmnt-shared.mount経由とする運用を[Tiered Storage](../operations/tiered-storage.md)へ追記する。
本番停止の実測はApps261秒、Hermes94秒、FSDからUPS出力断まで約436秒だったが、NFS先行停止の影響を含む。
待ち上限は短縮せず、1025秒＋ホスト停止等の最悪予算との整合を再確認する。

## 2026-11-01 追記: FSD試験での確認結果

以下はJSTの実機ログ・運用者の目視による。商用電源を接続したまま、推論vllm-glm53-dflash2稼働中に
pve1でupsmon -c fsdを実行した。入力プラグは抜いていない。

01:50:04にprimaryがFSDを設定、DGX両台は01:50:05に受信して01:50:10に停止開始。
推論は.51が3秒（01:50:14）、.52が14秒（01:50:25）。pve1はHOSTSYNCでsecondaryのログアウトを待ち、
01:50:25にExecuting automatic power-fail shutdown、01:50:30に停止開始した。
primary起点のFSDで両secondaryを待つ経路を初めて確認できた。

pve-guestsは01:50:33からorder3を停止。111・105は各2秒、104は6秒、103は9秒、続く101は19秒、102は2秒。
01:51:06にVM全停止→01:51:06.44にNFS停止→01:51:12にmergerfs unmount、pve1停止と、drop-inどおりだった。
FSDからpve1電源オフまで約70秒（ログ間68秒、HOSTSYNC約21秒・VM約34秒）、UPS出力断までは約122秒。
前回のHermes94秒・Apps261秒は今回6秒・19秒になった。上限は変更せず、詳細比較は[UPS運用](../operations/ups-nut.md)を参照する。

約01:52:06にkillpowerで出力が切れ、商用電源があるにもかかわらず約2分半、UPSボタンを押すまで出力は戻らなかった。
CPJ1200のondelay=-1によるstayoffと、UPSボタンでの出力復旧を確認した。
DGXは01:55:09〜10にAC復帰で自動起動、pve1は運用者が01:55:24に電源ボタンで起動した。
起動時はNFSが01:55:48.000にFinished→01:55:48.002にpve-guests開始→102→101→103…と順序も改善した。

起動後はkillpower flagなし、5 pool ONLINE、mergerfs・export6つ復帰、NUT OL・接続元3つ、
Appsのhomelab-apps.service active、DGXの/mnt/ai OKを確認した。
UPSボタン→ネットワーク・DGX自動起動→pve1ボタン→起動後の確認という手動復旧の主要手順を実際に通した。

## 未検証の点・推測

入力なしで出力が戻らないことは直接試していない。ただし商用電源があっても自動再投入しなかったため、
入力がなければ戻らないと見てよいと判断する。これは実測ではなく**推測**である。
停止途中での復電、別負荷・バッテリー劣化時の持続時間、HDD同時スピンアップの電力余裕は引き続き確認する。
