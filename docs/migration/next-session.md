# Phase 5 引き継ぎ（2026-09-23）

旧Kubernetes VM 101/102/103は保持期間満了後の2026-09-23にProxmoxから削除した。Apps VM
（VMID 112、`192.168.10.101`）が本番サービスの唯一のwriterである。移行の実施記録は
[移行手順書](k8s-to-compose.md)にある。Phase 0〜4の経緯は[archive/](archive/)に残す。
Phase 5着手前の詳細な安全条件は[旧引き継ぎ](archive/next-session-pre-phase5.md)に保存した。

## 実施済み

- Apps VMの7 Compose project、8 NFS mount、reconcile timerの稼働を確認。
- Proxmoxで旧VM 3台を停止状態から削除し、VM diskが残っていないことを確認。
- 旧4 NFS exportを`192.168.10.101/32`へ制限。DGX Spark 2台も使う`ai` exportは
  `192.168.10.0/24`を維持。設定と復旧方法は[NFS export契約](../operations/nfs-export.md)。
- `tank-gen2/data/k8s-volumes@pre-phase5-retire-20260923`を取得後、未使用PVC directory 8件を削除。
  Apps VMが使うSillyTavern、stashPad prod/stagingの3件は保持。
- Kubernetes Terraform、Kubespray、Flux、manifestを作業ブランチのactive treeから削除。
- 参照されなくなったpve1の`k8s-cloud-init.yaml`を退避後に削除。
- Phase 2B/3以前のrollback用snapshot 8件を削除し、
  `tank-gen2/data/k8s-volumes@pre-phase5-retire-20260923`だけを保持。
- AdGuard実機とAnsible定義から旧LDAP/phpadmin/LDAPS rewriteを削除。実機設定のbackupは
  `/etc/homelab/adguard/AdGuardHome.yaml.pre-phase5-20260923`。
- GitHubの旧Flux専用deploy key（ID 156354019）を失効。repository deploy keyは0件。
- Docker復旧後、`make ansible-lint ansible-check adguard-config-check secrets-scan`に合格。
- Caddy専用Cloudflare account tokenを作成し、対象zoneのReadと一時TXT recordの作成・削除で
  Zone Read / DNS Editを確認。SOPS bundleとApps VMのruntime secretを更新してCaddyだけを再作成し、
  新tokenがactiveであること、現行HTTPS endpointと7 containerが正常であることを確認。

## 引き続き必要なこと

1. このブランチをreviewしてmainへmergeし、Apps VMのreconcile後に稼働commitを確認する。
   AdGuardの変更は実機へ手動反映済み。merge後にAnsibleで宣言状態を再適用する際はssh-agentと
   `AGE_IDENTITY_FILE`を用意する。merge前にmainのAnsibleを適用すると旧rewriteが戻るため、
   DNS定義のmergeを先に行う。
2. 旧Kubernetes/Cloudflare用credentialをrevokeする。GitHubの旧Flux keyは失効済み。
   Caddyは専用tokenへ切替・検証済みなので、旧cert-manager tokenをCloudflare UIで失効する。
   新tokenには他のtokenを一覧・削除する権限を付けていない。
   GitHub Actionsは組み込み`GITHUB_TOKEN`だけを使用し、カスタムsecretは0件。
3. 受入試験のうち、Trusted LAN・tailnetからのアプリ操作、SMB read/write、通知など対話が必要な項目を
   再実施する。実施結果を[移行手順書](k8s-to-compose.md)へ記録する。
4. Phase 5直前snapshotは保持する。削除は今回の承認範囲外とし、別途明示承認があるまで残す。

## 安全条件と既知の制約

- `state-backup`ブランチは暗号化Terraform stateの保管用。削除しない。
- `tank-gen2/data/k8s-volumes`というdataset名と現行3 data directoryはApps VMが使用中。
  dataset自体や3 directoryを削除しない。
- `stashPadDev`（VMID 111）、ElastiFlow、Tailscale gatewayは今回の削除対象外。
- Apps VMを再構築する際は[復旧手順](../operations/apps-vm-recovery.md)のProxmox ACL再付与に注意。
- DGX Spark 2台の`/etc/fstab`追記は別作業として未実施。
- Apps VMのCompose定義は`origin/main`から供給される。ブランチ上の変更はmerge前に実機へ反映されない。
