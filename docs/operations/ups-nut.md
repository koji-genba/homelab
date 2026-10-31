# UPS / NUT運用

[ADR-0011](../adr/0011-ups-nut-shutdown.md) / [issue #158](https://github.com/koji-genba/homelab/issues/158)。
この手順による実機の導入・停止・復電は**未検証**。repo定義と事前調査に基づく手順であり、実施履歴ではない。

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

停止はorder 3（同orderは並列）→2→1→pve1。up_delayは省略し追加の起動待ちは設けない。
provider 0.117.0の既定は-1でAPIにupを送らず、PVE既定の起動遅延0秒に委ねる。
[固定版のschemaと更新処理](https://github.com/bpg/terraform-provider-proxmox/blob/v0.117.0/proxmoxtf/resource/vm/vm.go)
ではstartupにForceNewがなく、startup更新はrebootRequiredを立てないため、単独変更はin-placeで再起動不要。
実際のplanで他の変更が混ざらないことは運用者が確認する。
[PVEの起動・停止仕様](https://pve.proxmox.com/pve-docs/qm.1.html#_automatic_start_and_shutdown_of_virtual_machines)も参照。

## しきい値を決める（未検証）

初期値はUPSのLBをそのまま使う。安全な時間予算の確定前に、無人の停電保護が成立したとは扱わない。
通常負荷・推論中・DGX停止後に、次を読み日時、負荷、経過秒、実際の停止時間を記録する。

```sh
upsc cpj1200@localhost
upsc cpj1200@localhost ups.load
upsc cpj1200@localhost battery.runtime
upsc cpj1200@localhost battery.charge
```

battery.runtimeの単位は秒。表示値が実測と合うか、DGX停止後の負荷低下が反映されるか確認する。
最大の停止予算はHOSTSYNC240 + FINALDELAY5 + order3の180 + Apps420 + gateway180 = **1025秒**に、
pve1自身のNFS/ZFS flush・OS停止・UPS offdelay60と安全余裕を加える。実際は早く停止すれば次に進むが、
最悪時間をUPSが支えられないならtimeoutだけで保護は成立しない。負荷・停止時間・設定を見直す。
バッテリー劣化、計測誤差、USB通信の遅れも含む余裕を取る。低負荷でのruntimeを推論中へ流用しない。

測定後、pve1のgroup_varsで `nut_ignorelb: true` と
`nut_battery_charge_low`（%）/ `nut_battery_runtime_low`（秒）を設定できる。
nullならそのoverrideは出力しない。ignorelbはUPSのLBを無視して、driverが残量またはruntimeのしきい値でLBを作る。
overrideはUPS firmwareを書き換えない。片方のしきい値だけ変更しても、もう片方の値でLBになるので両方を確認する。
[2.8.1 ups.conf](https://networkupstools.org/historic/v2.8.1/docs/man/ups.conf.html)を参照。

## シークレットと反映（未検証）

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

初回checkでNUT未導入ならpackage予定だけになり、配置は省略する。適用後にcheck/diffを再実行しchanged=0を確認する。
passwordを含むupsmon.conf、upsd.usersとwebhookはdiff非表示。設定変更時はupsmonをrestartする。
既存curl/python3/loggerを使用し、sudo/jqは導入しない。pve1 rootの範囲はNUTだけ。

4. DGX担当とsecondary資格情報を安全な経路で共有し、別repoの手順で両台を反映する。
   DGX側の120秒timer・停止順・SHUTDOWNEXIT・NFS解除後のログアウトが必要。
5. Terraformの6 rootのstartupを、既存の各rootのplan/保存plan確認/apply手順で運用者が反映する。
   startupだけのin-place変更であることを確認する。AnsibleはVM startupを変更しない。

## 導入後の確認（未検証）

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

upscでOL（通常時）、USB製品、battery.charge/runtime、ups.load、input.voltageを確認。
`upsc -c`で192.168.10.51/.52の接続元を確認。IPv4-mapped IPv6も通知では認識する。
`upscmd -l` / 引数なしの`upsrw`は利用可能なコマンド・変数の一覧だけを読む。
monitorアカウントにinstcmd/set権限は付けない。`upsdrvctl -t shutdown`は手順を表示するだけで、
実際のUSB制御・出力断・復帰を検証しない。`-t`なしはここでは実行しない。

通知だけの試験は、rootからnutユーザーとして実行する（sudo不要）。

```sh
runuser -u nut -- env NOTIFYTYPE=ONLINE UPSNAME=cpj1200@localhost /usr/local/sbin/homelab-nut-notify
journalctl -t homelab-nut --since '-5 minutes'
```

Discordに日本語、ホスト名、ONLINE、4測定値が届くこととDGX不在時の案内を確認。
スクリプトは二段forkで切り離し、upsc各3秒、curl最大5秒で打ち切る。失敗はURLを含めずloggerへ残す。
送信完了をシェルの終了コードから判断しない。停電中は外部通信が使えない場合もある。
`upsmon -c fsd`は通知試験ではなく全体の停止要求なので通常設定で実行しない。

## 段階的な試験（未検証）

試験前にbackupと復旧経路、UPS容量・バッテリー状態・接続負荷を確認し、保守時間を確保する。
HDD 6本の同時スピンアップがUPSの定格を超えないか確認する。ローカルコンソールを確保する。
AppsのAdGuardが止まるので作業端末のTailscale DNSを先に外し、IP直指定等で管理経路を確保する。
Appsのreconcileを[アプリ運用](application-lifecycle.md)に従い一時停止し、終了後に戻す。
Hermesの作業・Runnerジョブ、書き込み・転送・backup・mover等を調整し、DGX担当と試験を合わせる。

1. 通常電源のまま導入して値と通知を読む。再適用changed=0と全secondary接続を確認する。
2. pve1を `PVE1_ANSIBLE_ARGS='-e nut_shutdown_dry_run=true'` で適用し、SHUTDOWNCMDがloggerのみ、
   POWERDOWNFLAGが省略されることを、rootで
   `grep -E '^(SHUTDOWNCMD|POWERDOWNFLAG)' /etc/nut/upsmon.conf` によりsecretを表示せず確認する。
   `test ! -e /etc/killpower`を確認。
   DGX両台も別repoの `scripts/setup-nut-client.sh --dry-run-shutdown` でdry-runにする。
   **pve1とDGXの両方をdry-runにして**、実際には停止せず、停電時の処理をログで確認する。
   DGX側の詳細は別repoの手順に従う。
   CPJ1200説明書は運転中に入力プラグを抜くことを禁じる。
   接地を維持できる適切なスイッチ付き電源タップかブレーカーでUPS入力を遮断し、ONBATT、
   DGXの120秒タイマーの開始・満了、満了前のONLINEによる取消、FSDの流れを条件を分けてログで確認する。
   pve1・DGXとも停止要求がloggerだけになることを確認する。UPSの出力側は切らない。
   LBまで放電する試験は、UPS出力で稼働を続ける負荷を保護できる状態でのみ行い、深放電を避ける。
   任意のFSD模擬はpve1・DGX両方のdry-run設定確認後の明示操作としてのみ行う。
3. 復電しOLを確認する。FSDは自動解除されないので、両方のdry-runを維持したまま
   `systemctl restart nut-server.service nut-monitor.service` し、upscのFSD消失とOLを確認する。
   `/etc/killpower`が残っていたら、停止処理中でないことを確認し、OL・FSDなしを再確認してrootで
   `rm -- /etc/killpower`。Ansibleはstale flagを自動削除せず拒否する。
   DGX側も別repoの手順に従いFSD後の状態を復旧してからdry-runを解除する。
   pve1は`nut_shutdown_dry_run=false`で再適用し、monitorのrestartとflag不在を確認する。
4. pve1・DGXとも本番設定で、短い停電、DGX早期停止後の復電、LB/FSD後の復電（VM停止中・出力断後）の条件を分けて試す。
   DGXの実際の停止はこの段階で確認する。
   FSD後は復電しても停止を完遂すること、VM順とtimeout、NFS解除、pve1停止、出力断、復帰を観察する。
   CPJ1200のoffdelay=60 / ondelay=120が実際にどう丸められるかも記録する。
   出力断の失敗や復帰しない場合は無人運転を保留し、安全を確認して電源操作で復旧する。

killpowerはDebianの `/usr/lib/systemd/system-shutdown/nutshutdown` が最後に `upsmon -K` を確認して
実行する。通常の計画停止ではflagを立てない。CPJ1200のACあり/なしでのshutdown.returnの挙動は未検証。
[CPJ1200取扱説明書](https://sakae-denshi.com/wp-content/uploads/2023/08/CPS_UM_CPJ1200_jp.pdf)と
[NUT 2.8.1 usbhid-ups](https://networkupstools.org/historic/v2.8.1/docs/man/usbhid-ups.html)を参照する。

## BIOSと復帰（未検証）

pve1（ASUS TUF GAMING X570-PLUS）はAC復帰で電源オンになる設定を確認する。
DGXは `Advanced → Power On Behavior → After Power Loss Behavior = Auto Boot` を確認する。
[NVIDIA公式UEFI手順](https://docs.nvidia.com/dgx/dgx-spark-uefi/advanced-tab.html#power-on-behavior)を参照。
UPSがACを切らなかった早期停止では自動起動しない場合がある。DGXは電源ボタンで起動する。
OSが戻っても推論は手動起動する。WoLは今回使わない。
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
