# アプリケーションのライフサイクル

- 対象: Apps VM切替後のCompose project更新、promotion、rollback
- 自動化の境界: [ADR-0002](../adr/0002-iac-and-deployment-boundaries.md)

## 通常のreconcile

Apps VMの`homelab-app-reconcile.timer`は15分ごとに`origin/main`をfetchし、fast-forwardだけを
受け入れる。dirty checkoutやnon-fast-forwardは拒否する。Compose projectとCaddy/Gatus設定の
差分から対象projectだけを選び、設定検証、digest gate、起動待ちを通して更新する。

実行結果はApps VMの`/var/lib/homelab/deployments.log`にcommit SHA、project、image、成否と
ともに追記される。確認には次を使う。

```sh
ssh deploy@192.168.10.42 sudo systemctl status homelab-app-reconcile.timer
ssh deploy@192.168.10.42 sudo journalctl -u homelab-app-reconcile.service -n 100
ssh deploy@192.168.10.42 sudo tail -n 100 /var/lib/homelab/deployments.log
```

## stashPad stagingとproduction

stagingはGitHubの`stashpad-staging-image` workflowが1時間ごとに`edge` tagを解決し、新しい
manifest digestのときだけ`stashpad-staging/compose.yaml`をmainへcommitする。その後の
Apps VMへの反映は通常reconcileに任せる。

productionは自動更新しない。stagingで確認済みのdigestを`stashpad-prod/compose.yaml`へ
明示的にpromotionし、diffとapplicationのdata/schema互換性をreviewしてmainへmergeする。
mainへのpromotion commitが明示的な承認点であり、merge後のdeploy自体はreconcileが行う。

## Ansibleで生成する設定

AdGuard HomeのDNS rule/config、Samba password、Caddy/Gatus/SillyTavern/Healthchecksのruntime
secretはGit reconcileではなくAnsibleの明示適用対象とする。暗号化bundleの復号確認後に
次を実行する。

```sh
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make secrets-decrypt-check
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply
```

Ansibleは変更を検出したときだけ、NFS markerとimage digestを再確認した上でprojectを
force-recreateする。Apps VMにage identityを保持しない。

## rollbackと再開

rollback先commitが現在のdata/schemaと互換性があることを先に確認する。自動的なDB/data
downgradeは行わない。projectと1つ前の既知commitを指定する。

```sh
PROJECT=stashpad-staging \
ROLLBACK_SHA=<known-good-commit> \
APPS_HOST=192.168.10.42 \
make rollback-app
```

rollback helperは指定commitのCompose定義で対象projectを戻し、
`/var/lib/homelab/reconcile.paused`を作成して自動再更新を停める。成功時にはその時点の
`origin/main` SHAとprojectを`/var/lib/homelab/reconcile.pending`へ記録し、既存の同project
retryは重複排除する。原因の修正、mainの希望状態、data/schemaの互換性を確認してからpauseを
明示解除し、一度reconcileする。reconcileは解除後に現在の`origin/main`を再fetchし、pending
projectを必ず再適用するため、rollback状態が意図せず残らない。

```sh
ssh deploy@192.168.10.42 sudo rm /var/lib/homelab/reconcile.paused
ssh deploy@192.168.10.42 sudo systemctl start homelab-app-reconcile.service
```

アプリを停止してread-onlyへ戻す場合は、先に`homelab-apps.service`を停止する。
Ansibleのpre-taskも同じ順序を強制し、ExecStopが失敗した状態でNFSをremountしない。

変更後はGatus、Discord通知、Healthchecks.ioのdead-man、対象applicationのread/writeを確認し、
`deployments.log`のSHA/digestとGit宣言を照合する。
