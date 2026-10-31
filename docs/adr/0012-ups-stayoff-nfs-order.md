# ADR-0012: UPS出力の手動復旧とVM・NFSの停止順を採用する

## 状態

承認済み（2026-10-31）。repo定義済み、変更後の実機反映・停電試験は未検証。
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
これはソースで確認した送信経路で、CPJ1200の実動作は未検証。sdcommandsは2.8.1にないため使わない。
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

## 未検証の点

CPJ1200のondelay=-1で停電中・復電後とも停止を維持すること、UPSボタンでの復旧、drop-in適用後の
VM→NFSの実停止順と待ち時間の改善、停止途中で復電するケースは次の計画停止で確認する。
