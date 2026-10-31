# pve1 UPS root

今回は **NUT と、UPSの停止に使うVMのstartupを管理する**。mover・exports・mergerfs・zfs-import@ などの管理は将来の issue。
Apps / Agent / gateway / ElastiFlow の root とは独立し、reconcile からは実行しない。
対象は `root@192.168.10.11`。sudo は使わず、追加パッケージは Debian の
`nut-server` / `nut-client`（必須依存を含む）だけ。python3、curl、logger は既存のものを使う。

管理端末の SSH agent と、事前に別経路で fingerprint を照合した known_hosts を使う。
Makefile が known_hosts を read-only mount し、`host_key_checking = true` で照合する。
鍵の自動採取や `StrictHostKeyChecking=no` は使わない。

```sh
make ansible-lint-pve1 ansible-check-pve1  # 静的検査、接続も復号もしない
# 以下は運用者が明示して行う実機操作
AGE_IDENTITY_FILE=/secure/path/age-identity.txt \
  make ansible-apply-pve1 PVE1_ANSIBLE_ARGS='--check --diff'
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply-pve1
```

check/apply は controller で pve1 bundle の `nut` と Apps bundle の
`gatus.discord_webhook_url` だけを抽出する。secret task は `no_log`、secret file は diff 無効。
初回 check で NUT 未導入なら、package の予定とUSB接続を検査し、nut group が必要な配置は省く。
導入後に check/diff を再実行する。upsmon.conf は password を含むため通常設定部分も diff 非表示。
`SHUTDOWNCMD` / `POWERDOWNFLAG` の反映には reload でなく restart を使う。

既定値は `roles/nut/defaults/main.yml`、controller の bundle path は `group_vars/pve.yml`。
roleのLB既定はUPS任せ。pve1のgroup_varsは2026-10-31のユーザー決定でignorelb・残量50%・runtime300秒。
`nut_ignorelb` と `nut_battery_charge_low` / `nut_battery_runtime_low`（null は省略）で調整する。
`nut_hostsync` は既定240秒。
`nut_shutdown_dry_run=true` は logger のみ、POWERDOWNFLAG は省略する。
`/etc/killpower` があれば適用を拒否するので、[runbook](../../../../docs/operations/ups-nut.md)に従い状態を確認する。

Debian 2.8.1-5 の配布 deb をローカル展開して unit、既定設定、最終フックを確認した。
`nut-driver-enumerator.service` が driver instance を登録し、`.path` が設定変更を監視する。
`nut-driver@cpj1200.service`、`nut-server.service`、`nut-monitor.service` と `nut.target` を有効化する。
`/usr/lib/systemd/system-shutdown/nutshutdown` は `upsmon -K` を使い、
既定の `POWERDOWNFLAG /etc/killpower` に従って最後に `upsdrvctl shutdown` を実行する。
RUN_AS_USER は Debian の既定の nut。ホストの通常停止だけでは killpower を要求しない。

[導入・試験・計画停止](../../../../docs/operations/ups-nut.md)と
[secret作成](../../secrets/README.md#pve1-nut用bundle)を参照する。2026-10-31に実機の導入・再適用changed=0・dry-run停電試験を確認（運用者報告）。本番停止・killpower・一連の復帰は未検証。


`guest_startup` roleはgroup_varsの `guest_startup_vms` に従い6台の `qm config` を読み、
startupのプロパティ順を正規化して異なる場合だけ `qm set --startup` を実行する。
裸のorder値と `order=`、省略したupと `up=0` は同等。正のupは除去して追加の起動待ちをなくす。
checkでは読み取りと変更予定の表示だけを行い、存在しないVMは明示的に失敗させる。
全体configには機密項目があり得るためログへ出さない。startup単独の更新でVMの再起動は行わない。
Terraformの6 rootはstartupを `ignore_changes` に入れる。tokenに `/` の `Sys.Modify` がなく、
2026-10-31のVM102への適用が403で失敗したため、権限を増やさずroot接続のAnsibleへ管理を移した。
このroleの実機反映は未検証。VMをTerraformで新規作成・再作成した後も、pve1 Ansibleを再適用する。
`PVE1_ANSIBLE_ARGS='--tags guest_startup --check'`（確認）/ `'--tags guest_startup'`（反映）で
startupだけを扱える。この場合NUT roleの復号・サービス操作は行わない。
