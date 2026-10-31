# ADR-0011: NUTによるUPS監視と協調停止

## 状態

承認済み。2026-10-31 JSTに導入・secondary接続・dry-run停電試験を確認（運用者報告）。
同日20:00〜20:30に本番停止・killpower・起動後の復旧を確認。停電中の出力再投入とNFS先行停止を検出し、
自動復帰・NFS順序の前提は[ADR-0012](0012-ups-stayoff-nfs-order.md)で置き換える（変更後は実機未検証）。

## 背景

[issue #158](https://github.com/koji-genba/homelab/issues/158)。pve1にはCPJ1200がUSB接続され、
pve1・DGX 2台・スイッチ・ルーターへ給電している。NFS sharedのasync exportでは異常電源断で
完了応答済みの直近の書き込みを失い得る。DGXはhard NFS clientなので、NFS serverのpve1を先に止めると
I/Oが待ち続ける。AppsのCompose停止には最大300秒必要で、PVE既定の180秒では足りない。

## 決定

pve1へDebian公式nut-server/nut-clientを入れる。ハードウェアの電源管理として、ホストにソフトを
極力入れない方針の例外とする。sudo・jq等は追加しない。採用時はAnsible pve1 rootをNUTだけの管理としたが、
下記追記でVM startupも対象に加える。mover・exports・mergerfs・zfs-import@の管理は将来のissueとする。

pve1はMODE=netserver、UPS名cpj1200、driver=usbhid-ups、USB 0764:0501。
upsdは127.0.0.1と192.168.10.11の3493/tcpでlistenする。firewallは追加しない。
primary/secondary用の別アカウントを用意し、passwordはpve1専用SOPS bundleで管理する。

DGX .51/.52はsecondaryで、停電継続120秒で自分を止める。推論の120秒猶予、Docker、NFS unmount後まで
upsmonの接続を残す設計は別repo [edgexpert-ai-stack](https://github.com/koji-genba/edgexpert-ai-stack)
の担当範囲。ここにはprivate repoの手順を転記しない。pve1にタイマーは置かず、OB+LBでFSD、
HOSTSYNC既定240秒でsecondaryの切断を待つ。通信断時はNUT標準のDEADTIME判定もある。

VMは起動order 1=gateway、2=Apps、3=ElastiFlow/Hermes/Runner/stashPadDev。
停止は逆順、同orderは並列。shutdown timeoutはApps420秒、他180秒。
upは省略し、追加の待ちは入れない。起動順だけでサービスreadyは保証しない。

LBのしきい値は導入後に負荷・残runtime・停止所要時間を測って決める。既定はUPS自身のLB。
2026-10-31の測定後の具体値は下記の追記を参照する。
Ansibleからignorelbとoverride.battery.charge.low/runtime.lowを指定できる。
UPSのruntimeが正しいことも実測し、Apps420秒を含む全停止時間と余裕を確保する。

採用時はoffdelay=60、ondelay=120。復旧方針はADR-0012で手動へ変更する。POWERDOWNFLAGはDebian既定の/etc/killpower、最終段階のnutshutdownが
UPSの出力停止と復電後の復帰を要求する。BIOSのAC復帰時電源オンと組み合わせる。
採用時にはCPJ1200のkillpower・遅延・復電タイミングごとの実機検証が必要としていた。段階4の結果と新方針は後述する。

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
通知項目をups.statusへ変更する。段階4ではONBATT・LOWBATT・SHUTDOWNの配送を確認した。
DGXの起動時の `mnt-ai.mount: Network is unreachable` は2026-10-09にもある既存挙動で、
`/mnt/ai` アクセス時のautomountで接続する。

## 2026-10-31 追記: VM startupの管理をAnsibleへ移管

TerraformでVM102のstartup更新が `/` の `Sys.Modify` 不足で403となり、VM102は変化しなかった（運用者報告）。
tokenの権限は増やさず、pve1のroot接続で `guest_startup` roleが `qm set --startup` を管理し、Terraformの6 rootはstartupをignoreする。

値はgateway order1/down180、Apps order2/down420、他4台order3/down180を維持する。
キー順を正規化して異なる場合だけ更新し、checkは変更予定を表示する。VM不在は明示的に失敗する。
startupの単独更新は設定の即時保存だけで、VMの再起動は不要。新規VM作成・再作成後はpve1 Ansibleを再適用する。
PVEの権限・即時反映処理とprovider 0.117.0/ignore_changesの根拠は[runbook](../operations/ups-nut.md#シナリオ)を参照。
段階4では設定した順でVMの停止・起動を確認した。

## 2026-10-31 20:00〜20:30 追記: 段階4の結果

運用者が実機ログを確認した。推論vllm-glm53-dflash2稼働中、UPS入力プラグを抜いて停電試験を行った。
説明書は禁止しており、今後は適切な入力スイッチ・ブレーカーを使う。
DGXは20:00:26 ONBATT→20:02:26 timer満了→20:02:31停止開始。
推論は.51が3秒、.52が14秒で停止し、Docker→NFS unmount→upsmonログアウト（.51 20:02:36、.52 20:02:47）と続いた。
DGX停止後の負荷約25%、残量は20:03の83%→20:14の49%と約3%/分だった。

pve1は20:14:54、残量49%・runtime908秒・負荷26%でLB/FSD。secondary不在で20:14:59に停止開始。
order3は20:15:02から同時停止し、111と105は各2秒、103は10秒、104は94秒。
Appsは20:16:37〜20:20:58の261秒（Composeは67秒）、gatewayは20:20:59から2秒。
20:21:02 VM全停止、約20:21:15 pve1電源オフ、約20:22:10 UPS出力断（表示のカウントダウンも確認）。
DiscordはONBATT・LOWBATT・SHUTDOWNが到達。primary自身のFSDではFSDイベントは出ず、secondary側のイベントとなる。

出力断の約1分後、入力がないまま出力が戻ってDGXがバッテリーで起動した。
pve1はBIOSのAC復帰起動を無効にしたユーザー設定により起動せず、電源ボタンで起動した。
起動後はupsmonがkillpower flagを消し、5 pool ONLINE、mergerfsとNFS export6つが復帰した。
VMは102→101→103→104→…、Appsは20:30:38 active、DGXの/mnt/aiもOK。
upscの86%・OL CHRGは起動直後の表示で、FSD時49%からの実容量回復を示す値とは扱わない。

NFSは20:15:00にpve-guests（20:15:01）より先に停止し、Apps/Hermesのhard NFSが待たされた。
mergerfsも20:14:59にsession-398.scopeでSIGTERMを受けた。10-29の手動mountがSSHセッションのcgroupに
残っていたためで、再起動後はsystem.slice/mnt-shared.mount配下になった。
2つの対策・手動復旧の決定は[ADR-0012](0012-ups-stayoff-nfs-order.md)、詳細時系列と次回試験は[UPS運用](../operations/ups-nut.md)を参照。

## 未検証の点

ADR-0012のondelay=-1によるCPJ1200のstayoffとUPSボタン復旧、drop-inによる順序改善と修正後の停止時間、
停止途中での復電、USBの長期安定性、HDD同時スピンアップの電力余裕は未検証。
待ち上限1025秒＋ホスト停止等は維持し、実測約436秒だけを根拠に上限・しきい値を短縮しない。
