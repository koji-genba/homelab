# ADR-0011: NUTによるUPS監視と協調停止

## 状態

承認済み。2026-10-31 JSTに導入・secondary接続・dry-run停電試験を確認（運用者報告）。
本番の協調停止・killpower・一連の復電起動は未検証。

## 背景

[issue #158](https://github.com/koji-genba/homelab/issues/158)。pve1にはCPJ1200がUSB接続され、
pve1・DGX 2台・スイッチ・ルーターへ給電している。NFS sharedのasync exportでは異常電源断で
完了応答済みの直近の書き込みを失い得る。DGXはhard NFS clientなので、NFS serverのpve1を先に止めると
I/Oが待ち続ける。AppsのCompose停止には最大300秒必要で、PVE既定の180秒では足りない。

## 決定

pve1へDebian公式nut-server/nut-clientを入れる。ハードウェアの電源管理として、ホストにソフトを
極力入れない方針の例外とする。sudo・jq等は追加しない。新しいAnsible pve1 rootはNUTだけを管理し、
mover・exports・mergerfs・zfs-import@の管理は将来のissueとする。

pve1はMODE=netserver、UPS名cpj1200、driver=usbhid-ups、USB 0764:0501。
upsdは127.0.0.1と192.168.10.11の3493/tcpでlistenする。firewallは追加しない。
primary/secondary用の別アカウントを用意し、passwordはpve1専用SOPS bundleで管理する。

DGX .51/.52はsecondaryで、停電継続120秒で自分を止める。推論の120秒猶予、Docker、NFS unmount後まで
upsmonの接続を残す設計は別repo [edgexpert-ai-stack](https://github.com/koji-genba/edgexpert-ai-stack)
の担当範囲。ここにはprivate repoの手順を転記しない。pve1にタイマーは置かず、OB+LBでFSD、
HOSTSYNC既定240秒でsecondaryの切断を待つ。通信断時はNUT標準のDEADTIME判定もある。

VMは起動order 1=gateway、2=Apps、3=ElastiFlow/Hermes/Runner/stashPadDev。
停止は逆順、同orderは並列。shutdown timeoutはApps420秒、他180秒。
up_delayはprovider既定の省略を使い、追加の待ちは入れない。起動順だけでサービスreadyは保証しない。

LBのしきい値は導入後に負荷・残runtime・停止所要時間を測って決める。既定はUPS自身のLB。
2026-10-31の測定後の具体値は下記の追記を参照する。
Ansibleからignorelbとoverride.battery.charge.low/runtime.lowを指定できる。
UPSのruntimeが正しいことも実測し、Apps420秒を含む全停止時間と余裕を確保する。

offdelay=60、ondelay=120。POWERDOWNFLAGはDebian既定の/etc/killpower、最終段階のnutshutdownが
UPSの出力停止と復電後の復帰を要求する。BIOSのAC復帰時電源オンと組み合わせる。
CPJ1200でのkillpower・遅延・復電タイミングごとの動作は実機検証が必要。

dry-runはSHUTDOWNCMDをloggerだけにしPOWERDOWNFLAGを省く。古いflagがあるとAnsibleは拒否し、
運用者が状態を確認して除去する。SHUTDOWNCMD/POWERDOWNFLAGの反映はupsmon restartとする。
FSDはpve1のdry-runでもsecondaryへ伝わるので、全機を模擬停止にするにはDGX側もdry-runにする。

通知はupsmonのNOTIFYCMDから非同期でDiscordへ送る。AppsのGatus webhookをそのkeyだけ抽出し再利用する。
root:nut 0640で保存し、JSONは既存python3で生成、curlの時間制限を設ける。失敗はURLを含めずsyslogへ残す。
ONLINEでは接続元にDGXがいなければ手動電源オンと推論起動を案内する。WoLは将来検討とする。

## 影響

停電で正常停止する経路を追加するが、UPS故障・USB通信断・バッテリー劣化や時間不足によるデータ損失は残る。
DGX早期停止後にLB前に復電するとUPS出力は切れず、DGXは止まったままになり得る。
FSD後は復電しても停止を完遂する。Discordは外部ネットワークに依存し、停止の成立条件にはしない。
計画停止もDGXを先に止めた後pve1を通常shutdownし、VMの逆順停止に任せる。

## 2026-10-31 追記: 実機試験とLBしきい値

以下は運用者による同日JSTの実機報告。LB値はユーザー決定としてpve1のgroup_varsに
`nut_ignorelb: true`、`nut_battery_charge_low: 50`、`nut_battery_runtime_low: 300` を設定する。
roleのdefaultsは未指定のまま保つ。DGX停止後のpve1中心の区間では残量50%が先に効く想定。
runtimeは同じ負荷でも約±25%揺れ、推論中約500Wでは持続約9分なので、600秒だと瞬停でも
OB+LBによる全台停止になり得る。pve1の `/lib/nut/upsmon` で2.8.1に `OBLBDURATION` がないことを
確認したため、runtimeはUPS既定と同じ300秒にする。

段階1ではpve1へdry-runで適用し、初回のUSB権限不足をudevルール当て直しで解決した（`9481bbd`）。
再applyはchanged=0、Discord試験通知も到達した。`upscmd -l` にshutdown.return等の出力制御コマンドと
バッテリーquick testがあり、`upsrw` は残量low（既定10）・runtime low（既定300）・出力停止/起動遅延を表示した。
これはコマンドの実動作の確認ではない。30秒ごとの `nut_libusb_get_string: Invalid parameter` は今回の試験に害はなかった。

段階2ではDGX .51/.52をdry-run secondaryとして接続し、pve1でも接続元を確認した。
手動再起動で推論停止unit→NFS unmount→upsmon終了→pve1のログアウト記録の順を確認。
.52の記録は15:55:57.112→.189→.190→pve1 .194と数十ミリ秒以内に続いた。

段階3のdry-run停電試験A（60秒）ではONBATT/ONLINE通知が届いた。.51がバッテリー給電側でなかったため
電源断して復電で自動起動し、After Power Loss = Auto Bootが効くことを確認した。
ONLINEの.51不在案内も正しく、運用者が給電先を修正した。
試験B（150秒）では両DGXとも120秒でtimerが満了し、loggerだけで稼働を継続、ONLINEに不在案内は付かなかった。
upssched 2.8.1は開始・取消を通常ログに出さず、満了はCMDSCRIPTのloggerで確認する。
このA/BではFSD経路を検証済みとしない。
当日はスイッチ付きタップがなく、説明書が禁じる入力プラグ抜去を短時間行った。
今後の試験は適切なスイッチ付きタップかブレーカーによる入力遮断とする。

DGXアイドル・全台稼働で負荷37〜39%（約275W）、150秒で残量100→88%（約4.8%/分、満充電から約20分の見積もり）。
同負荷のruntimeは1033〜1410秒。アイドルDGX 1台は6〜7%（約45W）、DGX停止後のpve1とネットワークは
25%（約180W）と推定する。ネットワーク機器は停電中も稼働し、通知が届いた。

input.voltageはpollfreq（30秒）ごとの更新で、ONBATT通知に100.0、ONLINEに0.0と前の値が出た。
通知項目をups.statusへ変更する。変更後の実配送は未検証。
DGXの起動時の `mnt-ai.mount: Network is unreachable` は2026-10-09にもある既存挙動で、
`/mnt/ai` アクセス時のautomountで接続する。

## 未検証の点

段階4の本番停止・killpower・復電起動は後日検証する。Appsを含む実停止時間、負荷のある推論の停止時間、
HOSTSYNCの余裕、PVE stopall、pve1のflush、shutdown.returnの実動作、ACあり/なしの出力復帰、
HDD 6本の同時スピンアップ、pve1のAC復帰設定、DGX .52の復電起動は未検証。
USBの長期安定性とDGX停止後の持続時間も継続確認が必要。
HOSTSYNCとVM等の待ち上限だけで1025秒あり、さらにpve1停止・offdelay・余裕が必要。
今回の50%/300秒はこの最悪条件を保証せず、段階4の実測で負荷・停止猶予・しきい値の整合を確認する。
試験結果と今後の手順は[UPS運用](../operations/ups-nut.md)に従う。
