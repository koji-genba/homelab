# UPS / NUT運用

[ADR-0011](../adr/0011-ups-nut-shutdown.md) / [ADR-0012](../adr/0012-ups-stayoff-nfs-order.md) / [issue #158](https://github.com/koji-genba/homelab/issues/158)。
2026-10-31 JSTに段階1〜3（導入・secondary接続・dry-run停電試験）を確認した（運用者報告）。
同日20:00〜20:30の段階4で実停止・killpower・起動後の復旧を確認し、UPSの停電中の再投入とNFSの先行停止が判明した。
このPRでondelay=-1とpve-guestsのNFS順序を導入する。修正後の実機反映・停電試験は**未検証**。

## 構成

CyberPower CPJ1200（USB 0764:0501、iProduct CPJ1200）をpve1（192.168.10.11、PVE 9.2 / Debian 13）へ接続。
pve1、DGX head .51 / worker .52、スイッチとルーターは同じUPSから給電する。
pve1のDebian NUT（確認対象2.8.1-5）はprimary、MODE=netserver、UPS名cpj1200。
upsdは127.0.0.1 / 192.168.10.11の3493/tcpでlistenする。LISTENは接続元ACLではない。
firewallは追加せず、現状のServer LANの境界を前提にする。

DGX secondaryの設定は別repo [koji-genba/edgexpert-ai-stack](https://github.com/koji-genba/edgexpert-ai-stack)
のNUT手順に従う。private repoの内容は転記しない。primary名はupsmon-pve1、共用secondary名はupsmon-dgx。
DGXはupsschedで停電継続120秒後にローカル停止し、推論の猶予120秒、Docker停止、hard NFSの通常unmount後まで
upsmon接続を維持する必要がある。pve1のHOSTSYNCは既定240秒、実測後に調整する。

## シナリオ

| 状況 | 動作・復帰 |
| --- | --- |
| 120秒以内に復電しLBにならない | ONBATT→ONLINE通知、DGX timer取消、通常運転を続ける |
| 120秒超、まだLBではない | DGXが先に停止、pve1とVMは稼働を続ける |
| DGX停止中・停止後、LB前に復電 | pve1は稼働を続ける。ONLINE時に接続元に.51/.52がなければ手動起動を案内。停止途中で接続が残る場合は検出できないので両台を確認する |
| 120秒以前でもOB+LBになる | primaryがFSD、DGXの停止と切断をHOSTSYNCまで待ち、pve1の停止へ進む |
| FSD後、VM停止中に復電 | FSDを自動取消せず停止を完遂。最後にUPS出力を切り、ondelay=-1で停止を維持する方針（CPJ1200では未検証）。復電後も手動で出力を戻す |
| 出力断後に復電 | 商用電源を確認してからUPSの電源ボタンで出力を戻す。ネットワーク・DGXが起動し、pve1は電源ボタンで起動。推論は手動起動 |
| UPS/upsd通信断 | COMMBAD/NOCOMM通知。最後の状態がOBならDEADTIME経過で危険と判断する場合がある。通信断を通常の停電timerと混同しない |

pve1には停電タイマーを置かず、通常はOB+LBで停止する。VMの停止は次の順で、down_delayは
**停止待ち上限であり、停止後の追加待ちではない**。超過時はPVE stopallが強制停止し得る。

| VM | 起動order | 停止待ち上限 |
| --- | --- | --- |
| 102 gateway | 1 | 180秒 |
| 101 Apps | 2 | 420秒（homelab-apps.serviceのTimeoutStopSec=300 + OS停止） |
| 103 ElastiFlow / 104 Hermes / 105 Runner / 111 stashPadDev | 3 | 各180秒 |

停止はorder 3（同orderは並列）→2→1→pve1。startupはpve1 Ansibleの `guest_startup` roleで管理し、
`qm set --startup order=...,down=...` をrootで実行する。upは省略し追加の起動待ちは設けない。
`qm config` のstartup行を比較し、キー順が違うだけなら変更しない。VM不在・読み取り失敗は明示的に失敗する。
checkでは変更予定だけを表示する。startupの単独更新はVM再起動を必要としない。
[PVEの実装](https://github.com/proxmox/qemu-server/blob/master/src/PVE/QemuServer.pm)ではstartupは
fast_plug_optionとして設定を即時保存し、QEMUへの操作はしない。
[PVEの起動・停止仕様](https://pve.proxmox.com/pve-docs/qm.1.html#_automatic_start_and_shutdown_of_virtual_machines)も参照。

2026-10-31、TerraformでVM102のstartupを更新しようとして `/` の `Sys.Modify` 不足による403で失敗した。
VM102に変更はなかった（運用者報告）。tokenの権限は増やさず、pve1 Ansibleへ移管する。
Terraformの6 rootにはstartupブロックを置かず、`lifecycle.ignore_changes = [startup, ...]` で管理対象から外す。
[provider 0.117.0の実装](https://github.com/bpg/terraform-provider-proxmox/blob/v0.117.0/proxmoxtf/resource/vm/vm.go)
ではstartupはoptionalのlistで、通常更新はHasChange(startup)の場合だけAPIへ送る。
[Terraformのignore_changes仕様](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#ignore_changes)
と合わせると、Ansibleが設定したstartupだけでは更新差分が出ず、他に差分がなければNo changesとなる。
cloneの読み取りでは未指定startupをstateへ取り込まない分岐もあるが、startupを除去する更新は発生しない。
これはソースと仕様による確認で、実機planはこの記録作成時には実行していない。段階4ではstartup順での実停止・起動を確認した。

### pve-guestsとNFSの順序

このPRで `guest_nfs_order` roleが
`/etc/systemd/system/pve-guests.service.d/50-homelab-nfs-order.conf` に `After=nfs-server.service` を配置する。
VM停止完了→NFSサーバー→mergerfs→ZFSの順を意図し、起動はその逆でNFS準備後にVMを起動する。
Afterは両unitが起動・停止するときの順序指定であり、NFS起動の成功まで保証する依存ではない。
配置後はdaemon-reloadだけを行う。pve-guestsはRefuseManualStart/Stopのためrestartしない。
実機反映後は次でAfterを確認し、次の計画停止で順序とhard NFS待ちの解消を検証する。

```sh
systemctl cat pve-guests.service
systemctl show pve-guests.service -p After
```

## LBしきい値の決定と測定（2026-10-31 JST）

運用者がpve1のgroup_varsに次の値を採用した。roleのdefaultsは変更せず、未指定時はUPS自身のLBを使う。
段階4では残量49%・runtime908秒でLB/FSDとなり、残量しきい値による停止を確認した。

```yaml
nut_ignorelb: true
nut_battery_charge_low: 50
nut_battery_runtime_low: 300
```

DGX停止後のpve1中心の区間では残量50%が先に効く想定。battery.runtimeは秒で、同じ負荷でも約±25%揺れる。
推論中の約500Wでは持ち時間が約9分しかなく、runtimeを600秒にすると停電直後にOB+LBとなり、
瞬停でも全台停止につながる。pve1の `/lib/nut/upsmon` でNUT 2.8.1には `OBLBDURATION` がないことを
運用者が確認したため、runtimeはUPS既定と同じ300秒にした。
ignorelbはUPSのLBを無視し、driverが残量またはruntimeのしきい値でLBを作る。
overrideはUPS firmwareを書き換えない。[2.8.1 ups.conf](https://networkupstools.org/historic/v2.8.1/docs/man/ups.conf.html)を参照。

段階3での実測と推定（2026-10-31、運用者報告）:

| 条件 | 結果 |
| --- | --- |
| 全台稼働、DGXアイドル | ups.load約37〜39%（約275W）、150秒でbattery.charge 100→88% |
| 上記の放電率 | 約4.8%/分。満充電から約20分の見積もりであり、全放電の実測ではない |
| 同じ負荷でのbattery.runtime | 1033〜1410秒に変動 |
| アイドルDGX 1台 | 負荷約6〜7%（約45W） |
| DGX停止後のpve1とネットワーク | 段階4で負荷約25%を確認。約180Wの換算。20:03の83%→20:14の49%と約3%/分で低下。全放電までの持続時間は未測定 |

### 停止時間予算と実測

待ち上限の合計はHOSTSYNC240 + FINALDELAY5 + order3の180 + Apps420 + gateway180 = **1025秒**。
さらにpve1自身のNFS/ZFS flush・OS停止、UPS offdelay60と安全余裕が必要。
これは各上限を使い切る最悪条件であり、早く停止すれば次に進む。

段階4ではDGXは既に停止済みでHOSTSYNCの待ちはなく、FSDの5秒後にホスト停止を開始した。
order3の最長はHermes94秒、Apps261秒、gateway2秒で、各群の最長時間の合計は357秒。
stopall全体は20:15:02〜20:21:02の360秒、pve1の停止開始から電源オフまでは約376秒、
FSDからUPS出力断までは約436秒（7分16秒）だった。AppsのCompose停止は67秒だがVM全体は261秒で、
OS終盤の待ちも予算に含める必要がある。

ただしこの測定はNFSとmergerfsの先行停止による待ちを含む。修正後の所要時間を測るまでは
Apps420秒・他180秒の上限を短縮しない。runtime300秒は全停止時間の保証ではない。
今回FSD時の表示は908秒で出力断まで到達したが、表示の揺れや起動後の86%への変化から
残時間・残量表示だけで余裕を断定しない。50%でも1025秒以上の最悪条件を保証したわけではない。
次の計画停止でNFS順序、pve1のflush、修正後の実停止時間とondelay=-1を確認する。
バッテリー劣化・USB通信の遅れも含め、時間不足なら負荷・停止猶予・しきい値を見直す。
確認には次を使い、日時・負荷・経過秒・実停止時間を記録する。

```sh
upsc cpj1200@localhost ups.load
upsc cpj1200@localhost battery.runtime
upsc cpj1200@localhost battery.charge
upsc cpj1200@localhost ups.status
```

## シークレットと反映

1. pve1 bundleは[作成手順](../../files/infrastructure/secrets/README.md#pve1-nut用bundle)で2026-10-31に作成済み
   （運用者報告。既存bundleと同じage recipient、`make secrets-scan` はclean）。再作成が必要な場合だけ同手順を参照する。
   `nut.upsmon_primary_password` / `nut.upsmon_secondary_password` は独立した32文字以上の英数字。
   Gatus webhookはApps bundleの既存keyだけを抽出する。値を複製したりログへ出したりしない。
2. SSH agent、別経路で照合済みのpve1のknown_hosts、controllerのage鍵を用意する。pve1へage鍵をコピーしない。
3. 静的検査→実機check/diff→適用の順。以下のapply/checkは実機へ接続する明示操作である。

```sh
make ansible-lint-pve1 ansible-check-pve1
AGE_IDENTITY_FILE=/secure/path/age-identity.txt \
  make ansible-apply-pve1 PVE1_ANSIBLE_ARGS='--check --diff'
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply-pve1
```

パッケージ導入前からUPSが接続されていると、NUTのudevルールが既存USBノードに当たらない場合がある。
roleは接続済み0764:0501のグループがnutでない場合だけ対象デバイスへルールを当て直す（check時は変更しない）。
初回checkでNUT未導入ならpackage予定とUSB接続を検査し、配置は省略する。適用後にcheck/diffを再実行しchanged=0を確認する。
passwordを含むupsmon.conf、upsd.usersとwebhookはdiff非表示。設定変更時はupsmonをrestartする。
既存curl/python3/loggerを使用し、sudo/jqは導入しない。pve1 rootの範囲はNUT、UPS停止に使うVM startup、pve-guestsとNFSの順序。

4. DGX担当とsecondary資格情報を安全な経路で共有し、別repoの手順で両台を反映する。
   DGX側の120秒timer・停止順・SHUTDOWNEXIT・NFS解除後のログアウトが必要。
5. VM作成後、同じpve1 Ansibleのcheck→applyで `guest_startup_vms` を反映する。
   `qm config <VMID>` で6台のstartupを確認する。Terraformはstartupをignoreするため、VM再作成後もAnsibleが必要。
   `nut_shutdown_dry_run=true` はNUTの停止だけを模擬し、通常applyではstartup設定は更新される。
   startupだけの確認・反映は `PVE1_ANSIBLE_ARGS='--tags guest_startup --check'` /
   `PVE1_ANSIBLE_ARGS='--tags guest_startup'` を使える。

6. このPRのondelayとdrop-inは同じpve1 Ansibleで反映する。NUTのdriverがrestartされたことと、
   `upsc cpj1200@localhost ups.delay.start` が `-1`、`ups.delay.shutdown` が `60` であることを確認する。
   `systemctl show pve-guests.service -p After` にnfs-server.serviceが入ることを確認する。
   この設定反映と次回の実動作確認は未検証。NFS順序だけなら `--tags guest_nfs_order` で反映できる。

## 導入後の確認

pve1のrootコンソールで行う。secretを含む設定ファイルをcatしない。

```sh
systemctl status nut-driver@cpj1200.service nut-server.service nut-monitor.service
systemctl status nut-driver-enumerator.path
upsc cpj1200@localhost
upsc -c cpj1200@localhost
upscmd -l cpj1200@localhost
upsrw cpj1200@localhost
upsdrvctl -t shutdown
journalctl -u nut-server -u nut-monitor --since '-10 minutes'
```

upscでOL（通常時）、USB製品、battery.charge/runtime、ups.load、ups.statusを確認。
2026-10-31の確認結果は段階1〜4に記録する。`upsdrvctl -t shutdown`だけで実際の出力制御を確認したとは扱わない。
`upsc -c`で192.168.10.51/.52の接続元を確認。IPv4-mapped IPv6も通知では認識する。
`upscmd -l` / 引数なしの`upsrw`は利用可能なコマンド・変数の一覧だけを読む。
monitorアカウントにinstcmd/set権限は付けない。`upsdrvctl -t shutdown`は手順を表示するだけで、
実際のUSB制御・出力断・復帰を検証しない。`-t`なしはここでは実行しない。

通知だけの試験は、rootからnutユーザーとして実行する（sudo不要）。

```sh
runuser -u nut -- env NOTIFYTYPE=ONLINE UPSNAME=cpj1200@localhost /usr/local/sbin/homelab-nut-notify
journalctl -t homelab-nut --since '-5 minutes'
```

Discordに日本語、ホスト名、ONLINE、battery.charge/runtime・ups.load・ups.statusが届くこととDGX不在時の案内を確認。
従来のinput.voltageはdriverのpollfreq（30秒）ごとの更新のため、ONBATT通知で100.0、ONLINEで0.0と
前の状態の値が出た（2026-10-31実機確認）。通知項目をups.statusへ変更した。段階4ではONBATT・LOWBATT・SHUTDOWNの配送を確認した。
スクリプトは二段forkで切り離し、upsc各3秒、curl最大5秒で打ち切る。失敗はURLを含めずloggerへ残す。
送信完了をシェルの終了コードから判断しない。停電中は外部通信が使えない場合もある。
pve1のprimaryが自分でFSDを立てたとき、NUTはprimary側にFSDイベントを出さない。
FSDイベントはsecondary側の通知なので、primaryの停止開始はLOWBATT・SHUTDOWNで確認する（段階4で確認）。
`upsmon -c fsd`は通知試験ではなく全体の停止要求なので通常設定で実行しない。

## 段階的な試験

### 共通の準備・入力遮断方法

試験前にbackupと復旧経路、UPS容量・バッテリー状態・接続負荷を確認し、保守時間を確保する。
HDD 6本の同時スピンアップがUPSの定格を超えないか確認する。ローカルコンソールを確保する。
AppsのAdGuardが止まるので作業端末のTailscale DNSを先に外し、IP直指定等で管理経路を確保する。
Appsのreconcileを[アプリ運用](application-lifecycle.md)に従い一時停止し、終了後に戻す。
Hermesの作業・Runnerジョブ、書き込み・転送・backup・mover等を調整し、DGX担当と試験を合わせる。
接続対象がUPSのバッテリー給電側に挿さっていることも各機で確認する。

**CPJ1200説明書は運転中の入力プラグ抜去を禁じている。** 今後の試験は接地を維持できる適切な
スイッチ付き電源タップかブレーカーで入力を遮断し、UPS出力側は切らない。
以下のプラグ抜去の記録は実施事実であり、推奨手順ではない。

### 段階1: pve1導入の結果（2026-10-31 JST）

以下の段階1〜4はすべて運用者報告と実機ログの確認結果に基づく。
pve1にdry-run設定で適用した。初回はパッケージより前に挿さっていたUPSへ `62-nut-usbups.rules` が当たらず、
driverが `insufficient permissions` で起動しなかった。roleのudev当て直しで解決した（commit `9481bbd`）。
再applyはchanged=0。通知試験はDiscordに届いた。

`upscmd -l` は `shutdown.return`、`load.off.delay`、`load.on.delay`、`test.battery.start.quick` などを表示した。
`upsrw` の書き換え可能な値は `battery.charge.low`（既定10）、`battery.runtime.low`（既定300）、
`ups.delay.shutdown`、`ups.delay.start`。一覧にあることは実際の出力制御の成功を意味しない。
driverは30秒ごとに `nut_libusb_get_string: Invalid parameter` を出すが、今回の試験では動作に害はなかった。

### 段階2: DGX接続・停止順の結果（2026-10-31 JST）

DGX両台を別repoの `scripts/setup-nut-client.sh --dry-run-shutdown` でdry-run secondaryとして接続し、
pve1の `upsc -c` に.51・.52が出ることを確認した。private repoの設定詳細はそちらの手順に従う。
DGXを手で再起動した際、推論を止めるunit→ `/mnt/ai` のunmount→upsmon終了→pve1のログアウト記録の順になった。
.52では15:55:57.112→.189→.190→pve1 .194と、各記録が数十ミリ秒以内に続いた。
これは手動再起動時の順序確認。推論稼働中の停止時間は段階4にも記録する。全secondaryが残る状態でのHOSTSYNCの余裕は未検証。

### 段階3: dry-run停電試験の結果（2026-10-31 JST）

pve1・DGXともdry-runで実施した。スイッチ付きタップがなかったため、説明書の禁止事項に反して
UPS入力プラグを短時間抜いた。今後は上記の入力遮断方法を準備する。

| 試験 | 結果 |
| --- | --- |
| A: 60秒 | ONBATT/ONLINEがDiscordに届いた。.51がバッテリー給電側に接続されておらず電源断し、復電で自動起動した。After Power Loss = Auto Bootの動作を確認。ONLINEは「DGX(.51) は停止している可能性」と正しく通知した。運用者が.51をバッテリー給電側へ挿し替えた |
| B: 150秒 | .51・.52ともONBATTからちょうど120秒でタイマー満了。dry-runなのでloggerだけが実行され、両台とも稼働を継続した。ONLINE通知にはDGX不在の案内は付かなかった |

NUT 2.8.1のupsschedはタイマー開始・取消を通常ログに出さない。満了はCMDSCRIPTの
`logger -t upssched` で確認できる。開始・取消のログがないことだけを異常と判定しない。
ネットワーク機器はUPSで動き続け、停電中も通知が届いた。負荷・放電率・runtimeは上のしきい値の節に記録した。
このA/Bの結果からFSD経路を検証済みとはしない。

### 段階4: 本番停止と復旧の結果（2026-10-31 20:00〜20:30 JST）

推論 `vllm-glm53-dflash2` を動かした状態で20:00ごろUPS入力プラグを抜き、pve1は20:00:2xにOBを検知した。
プラグ抜去は説明書が禁じる操作であり、次回は共通の準備に記載した入力遮断方法を使う。
当時はoffdelay=60、ondelay=120。次の時系列は実機ログ・UPS表示を運用者が確認した結果である。

| 時刻 | 結果 |
| --- | --- |
| 20:00:26 | DGXにONBATT |
| 20:02:26 | 両DGXの120秒タイマー満了、sudo upsmon -c fsd |
| 20:02:31 | DGX停止開始。推論は.51（gateway/head）3秒、.52（worker）14秒で停止。その後Docker→/mnt/aiのunmount→upsmonログアウト |
| 20:02:36 / 20:02:47 | .51 / .52のログアウト |
| 20:03〜20:14 | DGX停止後の負荷約25%。残量83→49%、約3%/分 |
| 20:14:54 | pve1がbattery is low→FSD。残量49%、runtime908秒、負荷26% |
| 20:14:59 | secondary不在のためHOSTSYNC待ちなしでpve1停止開始 |
| 20:15:00 | nfs-server.serviceが先に停止（問題2） |
| 20:15:01 / 20:15:02 | pve-guests停止開始 / order3のVMを同時停止。111と105は各2秒、103は10秒、104は94秒 |
| 20:16:37〜20:20:58 | Apps（101）停止、261秒。homelab-apps.serviceのCompose停止は67秒、残りはjournald停止後の終盤 |
| 20:20:59 | gateway（102）停止、2秒 |
| 20:21:02 / 約20:21:15 | VM全停止 / pve1電源オフ |
| 約20:22:10 | killpowerでUPS出力断。UPS表示のカウントダウンも確認 |
| 出力断の約1分後 | 入力を抜いたまま出力が戻り、DGXがバッテリーで自動起動（問題1）。pve1はBIOS設定どおり起動せず、運用者が電源ボタンで起動 |
| 起動後〜20:30:38 | 5 pool ONLINE、mergerfs・NFS export6つ復帰。VMは102→101→103→104→…の順で起動。Appsのhomelab-apps.serviceが20:30:38にactive。DGXの/mnt/aiもOK |

DiscordにはONBATT（20:00）、LOWBATTとSHUTDOWN（20:14）が届いた。
primary自身のFSDでFSD通知が出ないのはNUTの仕様であり、通知失敗ではない。
起動時にupsmonが `/etc/killpower` を削除した。直後のupscは86%・OL CHRGで、FSD時の49%より高く出た。
起動直後の表示として記録し、充電完了や残量の増加を証明する値には使わない。

### 問題1: 停電中の出力再投入とstayoff方針

CPJ1200はshutdown.return / ondelay=120で出力を切った後、商用電源がなくても出力を戻した。
ユーザー決定で `nut_offdelay: 60`、`nut_ondelay: -1` をroleのdefaultsとし、長い停電後はUPS出力を手動で戻す。
pve1のBIOSもAC復帰時の自動起動を無効にしたままとする。
**ondelay=-1でCPJ1200が停止を維持する実動作は未検証**で、次の計画停止で確認する。

[NUT v2.8.1 usbhid-ups.c](https://github.com/networkupstools/nut/blob/v2.8.1/drivers/usbhid-ups.c)はondelayを
strtolで符号付き整数としてups.delay.startへ読み、shutdown.returnでその値をload.on.delayへ渡す。
[CPSマッピング](https://github.com/networkupstools/nut/blob/v2.8.1/drivers/cps-hid.c)はDelayBeforeStartupへ対応し、
コマンド値はatol→HIDSetDataValueで送られるため-1を拒否しない。CPSにups.start.autoはなく、この書き込みはstayoff相当。
これはNUT側のソース確認であり、CPJ1200 firmwareの動作保証ではない。2.8.1にsdcommandsはないので追加しない。

[driver共通処理](https://github.com/networkupstools/nut/blob/v2.8.1/drivers/main.c)の-kはまず稼働中driverへ
driver.killpowerを頼むため、新プロセスだけで値を変えても不十分。ups.conf変更は既存の
Enumerate NUT driver→Restart NUT driver→server→monitorのhandlerで反映する。稼働中driverの新しい値も確認する。
ondelay=0で「復電時だけ出力を戻す」可能性は将来の選択肢。CP1500系の
[報告](https://alioth-lists.debian.net/pipermail/nut-upsuser/2022-June/012844.html)はあるがCPJ1200では未検証で、今回採用しない。

### 問題2: VMより先にNFSが停止

nfs-serverが20:15:00に止まり、pve-guestsは20:15:01から停止した。両unit間に順序指定がなかったため、
AppsのNFS9 mountとHermesのbackup NFSがサーバー停止後に終了処理を行い、hard mountで待たされた。
Hermes94秒・Apps終盤の約3分の待ちに影響し、書き込み中ならVM側に残ったデータを失うおそれがあった。
このPRのAfter=nfs-server.serviceで順序を修正する。修正後の実機検証はまだ行っていない。

停止開始時の20:14:59にはmergerfsもsession-398.scopeの一部としてSIGTERMを受けていた。
10-29にSSHセッションから手でmountし直したプロセスがセッションcgroupに残っていたためで、
再起動後は `0::/system.slice/mnt-shared.mount` 配下になった。手動再mountもsystemd unitを通す。
詳細は[Tiered Storage](tiered-storage.md#etcfstabmergerfsマウント)を参照する。

## 長い停電後の手動復旧（新方針の一連の操作は未検証）

1. 商用電源が安定して戻ったことを確認する。バッテリーだけの状態で出力を再投入しない。
2. UPSの電源ボタンで出力を戻す。ondelay=-1は復電だけでは自動復帰しない方針。
3. ネットワーク機器とDGXの自動起動を待つ。DGXはAfter Power Loss = Auto Bootを維持する。
4. pve1を電源ボタンで起動する。BIOSのAC復帰自動起動は無効のままにする。
5. [Proxmox起動後の確認](proxmox-host-recovery.md#検証)でpool5つ、mergerfs、NFS export6つ、VMとAppsの復帰を確認する。
   このPRのdrop-inとAfter=nfs-server.service、NUTのOL・FSDなし、ups.delay.start=-1、killpower flag不在も確認する。
   flagが残っていたら正常なOL・FSDなし・停止処理中でないことを確認してから扱い、無条件に削除しない。
6. DGXの `/mnt/ai` とsecondary接続元.51/.52を確認し、別repoの手順で推論を手動起動する。
   最後にreconcileと作業端末のTailscale DNSを戻し、通知とアプリを確認する。

DGXの起動途中に `mnt-ai.mount` が `Network is unreachable` で一度失敗するのは2026-10-09にもある既存挙動。
`/mnt/ai` にアクセスすればautomountで接続する。NFSとUPS出力が戻るまで推論は起動しない。
UPS出力が切れなかった短い停電では、停止済みDGXは電源ボタンで起動する場合がある。WoLは今回使わない。

## 次の計画停止で確かめること（未検証）

通常の計画停止は下の手順に従い、flagなしの通常shutdownではUPSを切らない。
stayoffを確かめるUPS出力断試験は、保守時間と全負荷の安全を確保した上で別の明示操作として行う。
`upsmon -c fsd` は通知だけの試験ではなく全体の停止要求。`upsdrvctl -t shutdown` は実出力を制御しない。
実際のkillpower試験はdry-runを解除したことを確認し、DGX停止→VM停止完了→NFS停止→mergerfs→ZFSのログ順、
Apps/Hermesの待ち時間、出力断後も停電中・復電後とも出力が戻らないこと、UPSボタンで戻せることを検証する。
HDD6本の同時スピンアップの電力も確認する。FSD後の停止途中での復電のケースも分けて確認する。
[CPJ1200説明書](https://sakae-denshi.com/wp-content/uploads/2023/08/CPS_UM_CPJ1200_jp.pdf)の禁止事項に従い入力遮断方法を準備する。

## 計画停止（未検証）

startup設定が6台に反映済みであることを `qm config <VMID>` のstartup行で確認し、NUTはOL・FSDなし、
`/etc/killpower`なしを確認する。backup・ストレージの健全性、保守時間、コンソール、DNS、reconcile、Hermesの作業を
上の試験前確認と同様に整える。SSHでのshutdown前に操作対象がpve1であることを確認する。

1. DGXを別repoの通常停止手順で先に止める。推論・Docker停止、hard NFSの通常unmount完了を確認する。
   `upsc -c`の接続元消失だけをNFS解除の証明にしない。DGXが止まらなければpve1停止へ進まない。
2. pve1のrootで `shutdown -h now` を実行する。個別の `qm shutdown` 列挙は不要で、pve-guestsが
   order3→Apps→gatewayの順に停止する。PVEコンソールで停止の完了とtimeoutがないことを確認する。
3. 通常shutdownではUPS出力を切らないので、起動はpve1/DGXの電源ボタンを使う。
   計画停止時もpve-guestsのAfterにnfs-serverがあることとmergerfsのcgroupがmount unit配下であることを事前確認する。
   起動後は上の復帰確認を行う。UPSの出力を意図的に切る作業は別途計画する。
