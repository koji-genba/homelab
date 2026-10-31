# UPS / NUT運用

[ADR-0011](../adr/0011-ups-nut-shutdown.md) / [issue #158](https://github.com/koji-genba/homelab/issues/158)。
2026-10-31 JSTに段階1〜3（導入・secondary接続・dry-run停電試験）を確認した（運用者報告）。
段階4の本番停止・killpower・復電後の一連の起動は**未検証**。以下では確認結果と残る試験を分ける。

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
| FSD後、VM停止中に復電 | FSDを自動取消せず停止を完遂。最後にUPSの出力を切り、復電条件を満たせば出力が戻る設計（実動作は未検証） |
| 出力断後に復電 | ondelayとUPSの条件に従い出力復帰、BIOSで各機電源オン。推論は手動起動 |
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
これはソースと仕様による確認で、実機planは今回実行していない。新しいroleの実機反映も未検証。

## LBしきい値の決定と測定（2026-10-31 JST）

運用者がpve1のgroup_varsに次の値を採用した。roleのdefaultsは変更せず、未指定時はUPS自身のLBを使う。
この値の実機反映・LB/FSDからの停止完了は、段階1〜3の結果だけでは検証済みとしない。

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
| DGX停止後のpve1とネットワーク | 負荷約25%（約180W）と推定。停止後の持続時間は未検証 |

### 停止時間予算と残る確認

待ち上限の合計はHOSTSYNC240 + FINALDELAY5 + order3の180 + Apps420 + gateway180 = **1025秒**。
さらにpve1自身のNFS/ZFS flush・OS停止、UPS offdelay60と安全余裕が必要。
これは各上限を使い切る最悪条件であり、早く停止すれば次に進む。
DGXが120秒で先に停止済みならHOSTSYNCを全て使うとは限らないが、本番停止時間はまだ未検証。

runtime300秒は停止に必要な全時間を保証する値ではなく、高負荷時の瞬停による即時FSDを避けるための判断。
残量50%も、上記1025秒以上の最悪条件を支えられると証明した値ではない。
段階4でDGX停止後の負荷・残時間、Appsを含む実停止時間を測り、時間不足なら負荷・停止猶予・しきい値を見直す。
バッテリー劣化、表示の揺れ、USB通信の遅れを含む余裕を取り、アイドル時の見積もりを推論中へ流用しない。
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
既存curl/python3/loggerを使用し、sudo/jqは導入しない。pve1 rootの範囲はNUTとUPS停止に使うVM startup。

4. DGX担当とsecondary資格情報を安全な経路で共有し、別repoの手順で両台を反映する。
   DGX側の120秒timer・停止順・SHUTDOWNEXIT・NFS解除後のログアウトが必要。
5. VM作成後、同じpve1 Ansibleのcheck→applyで `guest_startup_vms` を反映する。
   `qm config <VMID>` で6台のstartupを確認する。Terraformはstartupをignoreするため、VM再作成後もAnsibleが必要。
   `nut_shutdown_dry_run=true` はNUTの停止だけを模擬し、通常applyではstartup設定は更新される。
   startupだけの確認・反映は `PVE1_ANSIBLE_ARGS='--tags guest_startup --check'` /
   `PVE1_ANSIBLE_ARGS='--tags guest_startup'` を使える（実機反映は未検証）。

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
以下は導入後の確認手順。2026-10-31の実施結果は段階1〜3に記録し、`upsdrvctl -t shutdown`の実機確認は未検証とする。
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
前の状態の値が出た（2026-10-31実機確認）。通知項目をups.statusへ変更した。変更後の実配送は未検証。
スクリプトは二段forkで切り離し、upsc各3秒、curl最大5秒で打ち切る。失敗はURLを含めずloggerへ残す。
送信完了をシェルの終了コードから判断しない。停電中は外部通信が使えない場合もある。
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

以下の段階1〜3はすべて運用者報告に基づく。
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
この記録は手動再起動時の順序確認であり、負荷のある推論の停止時間やFSD時のHOSTSYNCの余裕は未検証。

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

### 段階4: 本番どおりの停止・復帰（未検証、後日実施）

pve1・DGXの実際の協調停止、killpower、復電での一連の起動はまだ未検証。
本番設定へ切り替える前に、dry-runとflagの状態を確認する。

- pve1はSHUTDOWNCMDがloggerのみ、POWERDOWNFLAG省略であることをrootで
  `grep -E '^(SHUTDOWNCMD|POWERDOWNFLAG)' /etc/nut/upsmon.conf` によりsecretを表示せず確認し、
  `test ! -e /etc/killpower` を確認する。DGXも別repoのdry-run手順に従う。
- FSD模擬が必要なら、両方のdry-run設定確認後の明示操作として行う。FSDは復電だけでは解除されない。
  試験後はOLを確認し、dry-runを維持して `systemctl restart nut-server.service nut-monitor.service`、
  upscでFSD消失を確認する。flagが残る場合は停止処理中でないこととOL・FSDなしを確認してから
  rootで `rm -- /etc/killpower`。Ansibleはstale flagを自動削除しない。このFSD復旧経路も未検証。
- DGXは別repoの手順で状態を戻してdry-runを解除する。pve1は決定したLB値を反映し、
  `nut_shutdown_dry_run=false` で再適用する。monitorのrestartとflag不在を確認する。
- 短い停電、DGX早期停止後の復電、LB/FSD後の復電（VM停止中・出力断後）を分けて試す。
  DGXの実停止・NFS解除、HOSTSYNC、VM順とAppsを含む実停止時間、pve1のflush・停止、UPS出力断を確認する。
- FSD後は復電しても停止を完遂すること、`shutdown.return` の実動作、offdelay=60 / ondelay=120の
  実遅延と復帰を観察する。pve1のAC復帰設定、HDD 6本の同時スピンアップも確認する。
- 出力断・復帰に失敗する場合や停止時間予算が足りない場合は無人運転を保留し、
  安全を確認して電源操作で復旧する。reconcile・端末DNSも戻す。

killpowerはDebianの `/usr/lib/systemd/system-shutdown/nutshutdown` が最後に `upsmon -K` を確認して
実行する。通常の計画停止ではflagを立てない。CPJ1200のACあり/なしでのshutdown.returnの挙動は未検証。
[CPJ1200取扱説明書](https://sakae-denshi.com/wp-content/uploads/2023/08/CPS_UM_CPJ1200_jp.pdf)と
[NUT 2.8.1 usbhid-ups](https://networkupstools.org/historic/v2.8.1/docs/man/usbhid-ups.html)を参照する。

## BIOSと復帰

pve1（ASUS TUF GAMING X570-PLUS）のAC復帰時電源オンは未検証で、段階4で確認する。
DGXの `Advanced → Power On Behavior → After Power Loss Behavior = Auto Boot` は、
2026-10-31の試験Aで.51が復電で自動起動し、動作を確認できた。.52の復電起動は未検証。
[NVIDIA公式UEFI手順](https://docs.nvidia.com/dgx/dgx-spark-uefi/advanced-tab.html#power-on-behavior)を参照。
UPSがACを切らなかった早期停止では自動起動しない場合がある。DGXは電源ボタンで起動する。
OSが戻っても推論は手動起動する。WoLは今回使わない。
DGX起動途中に `mnt-ai.mount` が `Network is unreachable` で一度失敗するのは今回以前からの挙動で、
2026-10-09の起動でも記録されている（運用者報告）。`/mnt/ai` にアクセスすればautomountで接続する。
起動後は[Proxmoxホスト復旧の確認](proxmox-host-recovery.md#検証)に従いpool、NFS、VM、Appsを確認し、
DGXは別repoの起動手順に従う。reconcileと端末DNSを戻し、NUT OL・接続元・通知も確認する。

## 計画停止（未検証）

startup設定が6台に反映済みであることを `qm config <VMID>` のstartup行で確認し、NUTはOL・FSDなし、
`/etc/killpower`なしを確認する。backup・ストレージの健全性、保守時間、コンソール、DNS、reconcile、Hermesの作業を
上の試験前確認と同様に整える。SSHでのshutdown前に操作対象がpve1であることを確認する。

1. DGXを別repoの通常停止手順で先に止める。推論・Docker停止、hard NFSの通常unmount完了を確認する。
   `upsc -c`の接続元消失だけをNFS解除の証明にしない。DGXが止まらなければpve1停止へ進まない。
2. pve1のrootで `shutdown -h now` を実行する。個別の `qm shutdown` 列挙は不要で、pve-guestsが
   order3→Apps→gatewayの順に停止する。PVEコンソールで停止の完了とtimeoutがないことを確認する。
3. 通常shutdownではUPS出力を切らないので、起動はpve1/DGXの電源ボタンを使う。
   起動後は上の復帰確認を行う。UPSの出力を意図的に切る作業は別途計画する。
