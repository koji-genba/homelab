# アプリケーションのライフサイクル

- 対象: Apps VM切替後のCompose project更新、promotion、rollback
- 自動化の境界: [ADR-0002](../adr/0002-iac-and-deployment-boundaries.md)

## 通常のreconcile

Apps VMの`homelab-app-reconcile.timer`は15分ごとに`origin/main`をfetchし、fast-forwardだけを
受け入れる。dirty checkoutやnon-fast-forwardは拒否する。Compose projectとCaddy/Gatus設定の
差分から対象projectだけを選び、設定検証、digest gate、起動待ちを通して更新する。

Gatusはalert状態と監視履歴を`gatus` named volume上のSQLite file（`/data/data.db`）に保存する。
再起動・再作成後も進行中の障害を保持し、復旧時には`send-on-resolved: true`によるDiscord復旧通知を送る。
このvolumeはbackup対象外とし、消失時に監視履歴・alert状態だけが失われることを許容する。

実行結果はApps VMの`/var/lib/homelab/deployments.log`にcommit SHA、project、image、成否と
ともに追記される。確認には次を使う。

```sh
ssh deploy@192.168.10.101 sudo systemctl status homelab-app-reconcile.timer
ssh deploy@192.168.10.101 sudo journalctl -u homelab-app-reconcile.service -n 100
ssh deploy@192.168.10.101 sudo tail -n 100 /var/lib/homelab/deployments.log
```

## stashPad stagingとproduction

stagingはGitHubの`stashpad-staging-image` workflowが1時間ごとに`edge` tagを解決し、新しい
manifest digestのときだけ`stashpad-staging/compose.yaml`をmainへcommitする。その後の
Apps VMへの反映は通常reconcileに任せる。

productionは自動更新しない。stagingで確認済みのdigestを`stashpad-prod/compose.yaml`へ
明示的にpromotionし、diffとapplicationのdata/schema互換性をreviewしてmainへmergeする。
mainへのpromotion commitが明示的な承認点であり、merge後のdeploy自体はreconcileが行う。

## Ansibleで生成する設定

AdGuard HomeのDNS rule/config、Samba password、Caddy/Gatus/SillyTavern/Healthchecks/sparkDash/hf-downloaderのruntime
secretはGit reconcileではなくAnsibleの明示適用対象とする。暗号化bundleの復号確認後に
次を実行する。

```sh
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make secrets-decrypt-check
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply
```

Ansibleは変更を検出したときだけ、NFS markerとimage digestを再確認した上でprojectを
force-recreateする。Apps VMにage identityを保持しない。

## 新しいCompose projectの追加

project一覧はAnsibleが描画するhelper（`homelab-compose-up`等）に埋め込まれている。このため新しい
projectはGit reconcileだけでは起動しない。必要な順序は、pve1でNFS directoryとmarkerを作成、
PRをmerge、reconcileでApps VMのcheckoutを進める、`make ansible-apply`の順である。
markerを作る前にAnsibleを適用するとmount guardが全projectを止め、checkoutを進める前に適用すると
digest gateが`missing Compose project`で失敗する。具体例は[Open WebUI運用](open-webui.md)を参照。
NFS dataを持たないprojectではpve1の手順を省く。例は[SearXNG / MCP運用](searxng.md)と[sparkDash運用](sparkdash.md)である。
sparkDashはcheckoutが進んだ後、SOPS bundleに必須の`sparkdash.token`と任意の
`sparkdash.ssh_private_key`を追加してからAnsibleを適用する。正常終了後も
`homelab-compose-up sparkdash`で起動を明示確認する。
Homepageは新しいsecretやNFS directoryを必要としない。merge、reconcileによるcheckout更新、
`make ansible-apply`の順で初回反映し、起動を確認する。
AnsibleはDNS rewriteとhelper一覧を更新し、runtime変更があれば全projectをforce-recreateして
新projectも起動する。変更が無ければhelperの更新だけでは起動しないため、apply後に起動していなければ
`sudo /usr/local/sbin/homelab-compose-up homepage`を実行する。詳細は[Homepage運用](homepage.md)を参照する。

hf-downloaderは既存のai mountとmarkerを使い、新規exportは作らない。imageだけのPRを先にmergeし、
GHCRへの公開後に得たdigestをComposeへ固定する。tagだけのComposeはdraftのままとし、適用しない。
その後は連携一式のmerge、reconcileでのcheckout更新、`make ansible-apply`、起動確認の順とする。
`files/services/images/dagu-hf/`だけの変更では再作成しない。Composeのdigestが変わらなければ
取得を中断するだけになるためである。imageの公開後にComposeのdigestを更新するとreconcileが反映する。
任意の`hf_downloader.token`を使う場合はapply前に既存SOPS bundleへ追加する。省略時も空fileを配置する。
デプロイ直後に`/setup`でDagu管理者を作成する。詳細は[hf-downloader運用](hf-downloader.md)を参照する。
Daguの状態はbackup対象外のローカルnamed volumeにあり、喪失時は管理者を作り直して取得を再投入する。
モデル・データセット本体はai共有に置き、既存どおりsnapshot対象外・再取得可能として扱う。

現在の定義は`edge dns samba stashpad-prod stashpad-staging sillytavern open-webui searxng sparkdash hf-downloader homepage monitoring`の
12 projects / 13 servicesで、停止順はその逆である。

## projectの撤去（共通手順）

以下は実装から導いた手順で、実機では未検証。
撤去PRではCompose定義、Caddy/Gatus、DNS rewrite、secret/env/NFS宣言に加え、compose roleの
検証一覧、up/down・reconcile・rollback・dead-manのproject一覧を揃えて対象projectを外す。
管理端末はその変更を含む定義を使う。VM側は対象のCompose定義が残っている状態から始める。

1. mainへmergeする前にApps VMで`sudo systemctl stop homelab-app-reconcile.timer`を実行する。
   `sudo systemctl status homelab-app-reconcile.service`とjournalで実行中の処理が終了したことを確認する。
   timerを止めても実行中のserviceは止まらない。終了前にcheckoutやpendingを変更しない。
2. `/var/lib/homelab/reconcile.paused`の有無を確認する。作業前から存在する場合は撤去作業に入らず、
   先にpauseの理由（rollback/障害）を解決し、該当projectをmainの定義へ戻してよいことを確認して
   pauseを解除した後、この手順を最初からやり直す。解決できなければ中断する。
   後段のAnsible適用と`homelab-compose-up all`はpauseを見ずに全projectを再作成し、rollback中の
   projectもVM checkoutの定義へ戻してしまうためである。
   pauseが無い場合は`sudo touch /var/lib/homelab/reconcile.paused`で作成する。Ansibleはtimerを再起動するため、
   checkout更新までこのpauseでも競合を防ぐ。`/var/lib/homelab/reconcile.pending`があれば内容を確認し、
   `SHA project`形式の第2欄が撤去対象の行だけを取り除く。他projectのretryは残す。
3. VMの既存Compose定義を使い、対象projectを停止する（`<project>`は撤去対象へ置き換える）。

   ```sh
   sudo docker compose --project-name homelab-<project> --env-file /etc/homelab/compose.env \
     -f /opt/homelab/files/services/compose/<project>/compose.yaml down --remove-orphans
   ```

   `sudo docker ps -a --filter 'label=com.docker.compose.project=homelab-<project>'`で対象projectのcontainerが残っていないことを確認する。
   named volumeとNFS dataはこの停止で削除しない。
4. 撤去PRをmainへmergeし、管理端末の同じ定義から
   `AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply`を実行する。
   対象を外したhelper、reconciler、dead-man等を先に描画する。
   checkoutだけが先に進むと、古いhelperとdead-man pingが撤去対象の`compose.yaml`を見つけられずに失敗する。
   `compose.env`/secretが変われば残る全projectがforce-recreateされる。
   Ansibleのgit taskは既存checkoutを更新しないため、この段階で残るprojectの旧Compose定義にも
   必要なenv/secretが揃っていることを確認する。移行用に残した入力はcheckout更新後に整理する。
5. pauseを維持したまま、VMのcheckoutがcleanであることを確認し、mainをfast-forwardする。
   pause中はreconcileがcheckout更新も行わないため、この段階は直接更新する。

   ```sh
   sudo git -C /opt/homelab status --porcelain --untracked-files=all
   sudo git -C /opt/homelab fetch --prune origin main
   sudo git -C /opt/homelab merge --ff-only origin/main
   ```

   dirty checkout、non-fast-forward、描画済み定義との不一致があれば停止して原因を調べる。
   Ansibleは一覧から消えたNFS mountを撤去しない。必要ならwriter停止を確認してclient側のfstabとmountを
   整理する。data/markerの削除は別の判断とする。
   移行用env/secretの整理をAnsibleで適用した後、
   `sudo env HOMELAB_FORCE_RECREATE=true /usr/local/sbin/homelab-compose-up all`で残る全projectを再作成する。
   checkoutを直接進めた差分は次のreconcileでは検出されないため、Caddy/Gatus等のGit管理bind設定も
   ここで反映する。DNS/SMBを含む短い中断を見込む。
6. pendingに撤去対象が無いことを再確認し、残るprojectとmount guard、DNS、監視を確認する。
   この作業で作成したpauseを`sudo rm /var/lib/homelab/reconcile.paused`で解除し、
   `sudo systemctl start homelab-app-reconcile.timer`、
   `sudo systemctl start homelab-app-reconcile.service`の順で再開する。

## rollbackと再開

rollback先commitが現在のdata/schemaと互換性があることを先に確認する。自動的なDB/data
downgradeは行わない。projectと1つ前の既知commitを指定する。

```sh
PROJECT=stashpad-staging \
ROLLBACK_SHA=<known-good-commit> \
APPS_HOST=192.168.10.101 \
make rollback-app
```

rollback helperは指定commitのCompose定義で対象projectを戻し、
`/var/lib/homelab/reconcile.paused`を作成して自動再更新を停める。成功時にはその時点の
`origin/main` SHAとprojectを`/var/lib/homelab/reconcile.pending`へ記録し、既存の同project
retryは重複排除する。原因の修正、mainの希望状態、data/schemaの互換性を確認してからpauseを
明示解除し、一度reconcileする。reconcileは解除後に現在の`origin/main`を再fetchし、pending
projectを必ず再適用するため、rollback状態が意図せず残らない。

```sh
ssh deploy@192.168.10.101 sudo rm /var/lib/homelab/reconcile.paused
ssh deploy@192.168.10.101 sudo systemctl start homelab-app-reconcile.service
```

### rollbackが失敗したとき

`homelab-rollback-app.sh.j2`は起動試行前に`/var/lib/homelab/reconcile.paused`を作る。
pendingへの追加は起動成功時だけなので、失敗してもpauseが残り、今回のretryがpendingに無い場合がある。
pauseと`/var/lib/homelab/reconcile.pending`を別々に確認し、既存retryと
`deployments.log`・起動失敗の原因を調べてから再開を判断する。

アプリを停止してread-onlyへ戻す場合は、先に`homelab-apps.service`を停止する。
Ansibleのpre-taskも同じ順序を強制し、ExecStopが失敗した状態でNFSをremountしない。

変更後はGatus、Discord通知、Healthchecks.ioのdead-man、対象applicationのread/writeを確認し、
`deployments.log`のSHA/digestとGit宣言を照合する。

## dead-man pingが止まる条件

`healthchecks-ping.sh.j2`は次のいずれかに失敗するとHealthchecks.ioへのpingを送らない。

- `/etc/homelab/secrets/healthchecks.env`が読めない。
- 毎回実行する`homelab-mount-guard`の検証が失敗する、または
  `homelab-mount-guard.service` / `homelab-apps.service`がactiveでない。
- `tailscaled.service`がactiveでない、status/IPv4を取得できない、backendが`Running`でない、
  またはIPv4が`apps_tailnet_ip`と一致しない。
- root filesystem使用率を数値として取得できない、`healthchecks_rootfs_max_percent`が1〜100の範囲外、
  または使用率が閾値以上（現行値は`group_vars/apps.yml`を参照）。
- `/opt/homelab/.git`が無い、Git statusがcleanでない、working treeまたはindexにHEADとの差分がある。
- `shared_mount_path`で一時probe fileの作成・書込み・削除に失敗する。
- helperに列挙されたprojectのactive service一覧やcontainer状態を取得・解析できない、または一覧が空。
  各serviceにrunning containerが1つ以上必要で、そのいずれかが`unhealthy`でも送らない。
  `starting`とhealthcheck無しのrunningは許容し、runningと並存するexited等は無視する。
  現行projectにone-shot、profiles、`deploy.replicas`、init専用serviceの指定は無く、追加時は判定を見直す。
  失敗理由はproject・serviceとともにstderrへ出力し、`journalctl -u homelab-healthchecks-ping.service`で確認する。
- LAN側の`http://status.kojigenba-srv.com/` probeが2xx、3xx、401、403以外を返す（接続失敗も含む）。
- `healthchecks.env`の読み込みに失敗する、`HEALTHCHECKS_PING_URL`が空、またはping送信自体が失敗する。
