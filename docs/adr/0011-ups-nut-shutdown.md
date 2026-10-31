# ADR-0011: NUTによるUPS監視と協調停止

## 状態

承認済み。repo定義済み、実機の適用・停止・復電は未検証。

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
Ansibleからignorelbとoverride.battery.charge.low/runtime.lowを指定できる。
UPSのruntimeが正しいことも実測し、Apps420秒を含む全停止時間と余裕を確保する。

offdelay=60、ondelay=120。POWERDOWNFLAGはDebian既定の/etc/killpower、最終段階のnutshutdownが
UPSの出力停止と復電後の復帰を要求する。BIOSのAC復帰時電源オンと組み合わせる。
CPJ1200でのkillpower・遅延・復電タイミングごとの動作は実機検証が必要。

dry-runはSHUTDOWNCMDをloggerだけにしPOWERDOWNFLAGを省く。古いflagがあるとAnsibleは拒否し、
運用者が状態を確認して除去する。SHUTDOWNCMD/POWERDOWNFLAGの反映はupsmon restartとする。
FSDはdry-runでもsecondaryへ伝わるので全機の模擬停止にはならない。

通知はupsmonのNOTIFYCMDから非同期でDiscordへ送る。AppsのGatus webhookをそのkeyだけ抽出し再利用する。
root:nut 0640で保存し、JSONは既存python3で生成、curlの時間制限を設ける。失敗はURLを含めずsyslogへ残す。
ONLINEでは接続元にDGXがいなければ手動電源オンと推論起動を案内する。WoLは将来検討とする。

## 影響

停電で正常停止する経路を追加するが、UPS故障・USB通信断・バッテリー劣化や時間不足によるデータ損失は残る。
DGX早期停止後にLB前に復電するとUPS出力は切れず、DGXは止まったままになり得る。
FSD後は復電しても停止を完遂する。Discordは外部ネットワークに依存し、停止の成立条件にはしない。
計画停止もDGXを先に止めた後pve1を通常shutdownし、VMの逆順停止に任せる。

## 未検証の点

USBの安定性、runtimeの精度、負荷ごとの持続時間、DGX停止時間、HOSTSYNCの余裕、PVE stopallの実所要時間、
CPJ1200のshutdown.returnとACあり/なしでの出力復帰、HDD 6本の同時スピンアップ、BIOS設定、通知の実配送。
導入後の試験と計画停止は[UPS運用](../operations/ups-nut.md)に従う。
