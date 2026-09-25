# 引き継ぎ（2026-09-25）

旧Kubernetes VM 101/102/103は保持期間満了後の2026-09-23にProxmoxから削除した。Apps VM
（VMID 101、`192.168.10.101`）が本番サービスの唯一のwriterである。移行の実施記録は
[移行手順書](k8s-to-compose.md)にある。Phase 0〜4の経緯は[archive/](archive/)に残す。
Phase 5着手前の詳細な安全条件は[旧引き継ぎ](archive/next-session-pre-phase5.md)に保存した。

## 実施済み

- 2026-09-25にApps `112→101`、Tailscale gateway `105→102`、ElastiFlow `110→103`を
  Terraformから再構築した。`stashPadDev`（111）とtemplate（9000）は変更していない。
- AppsのAnsible適用は`failed=0`で完了。7 Compose container、8 NFS mount、内部/外部DNS、
  7 HTTPS endpointのTLSを確認。Terraform 3 rootの実機planはすべて`No changes`。
- gatewayをTailscaleで再認証し、旧deviceを削除して新deviceを`home-gateway`に改名。
  `192.168.10.0/24`とexit nodeのみ広告・承認した。撤去済みVLAN 11は広告しない。
- ElastiFlowの3 serviceはactiveで、Elasticsearchはgreen、sFlow UDP 6343は待受中。
  再構築に伴い旧VMのローカルフロー履歴は引き継いでいない。
- 3 rootのTerraform stateをageで暗号化し、承認済みの`state-backup`ブランチへ退避した。
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
- 旧cert-manager用Cloudflare tokenをUIで失効し、APIが403を返すことを確認。旧tokenを含む
  Apps VMの切替前backupを削除し、現行CaddyのhealthとHTTPS endpointを再確認。
- Phase 5変更をPR #50でmainへmergeし、Apps VMのreconcile成功と稼働commitを確認。
- stashPad PR #107のimageをstagingで確認後、PR #51でproductionへ昇格。prod/stagingとも
  digest `sha256:4e3005005acf63d6295ae1b3b81fd421376bae42cdc13f7d26d6495ec1e4a2ad`でhealthy。

## 引き続き必要なこと

1. 受入試験のうち、Trusted LAN・tailnetからのアプリ操作、SMB read/write、通知など対話が必要な項目を
   再実施する。実施結果を[移行手順書](k8s-to-compose.md)へ記録する。
2. Phase 5直前snapshotは保持する。削除は今回の承認範囲外とし、別途明示承認があるまで残す。

## 安全条件と既知の制約

- `state-backup`ブランチは暗号化Terraform stateの保管用。削除しない。
- `tank-gen2/data/k8s-volumes`というdataset名と現行3 data directoryはApps VMが使用中。
  dataset自体や3 directoryを削除しない。
- `stashPadDev`（VMID 111）とtemplate（VMID 9000）はVMID整理の対象外。
- Apps VMを再構築する際は[復旧手順](../operations/apps-vm-recovery.md)のProxmox ACL再付与に注意。
- DGX Spark 2台の`/etc/fstab`追記は別作業として未実施。
- Apps VMのCompose定義は`origin/main`から供給される。
