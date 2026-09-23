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
- 参照されなくなったpve1の`k8s-cloud-init.yaml`を`.retired-20260923`へ改名。

## 引き続き必要なこと

1. このブランチをreviewしてmainへmergeし、Apps VMのreconcile後に稼働commitを確認する。
   Ansible templateの変更は別途適用が必要。`make ansible-apply`の前にssh-agentと
   `AGE_IDENTITY_FILE`を用意する。
2. AdGuardの旧LDAP/phpadmin/LDAPS rewrite削除を適用し、公開DNS側に不要recordがないか確認する。
   Caddyが現在使うFQDNは`files/services/compose/edge/Caddyfile`が基準。
3. 旧Kubernetes/Flux/registry/Cloudflare用credentialの発行元と利用状況を確認し、現行サービスと
   共用でないものだけrevokeする。Apps VMが使うCloudflare DNS-01 tokenやregistry credentialを
   誤って無効化しない。
4. 受入試験のうち、Trusted LAN・tailnetからのアプリ操作、SMB read/write、通知など対話が必要な項目を
   再実施する。実施結果を[移行手順書](k8s-to-compose.md)へ記録する。
5. Phase 5の全項目が揃ったら、不要な保管snapshotの期限と削除を別途判断する。

## 安全条件と既知の制約

- `state-backup`ブランチは暗号化Terraform stateの保管用。削除しない。
- `tank-gen2/data/k8s-volumes`というdataset名と現行3 data directoryはApps VMが使用中。
  dataset自体や3 directoryを削除しない。
- `stashPadDev`（VMID 111）、ElastiFlow、Tailscale gatewayは今回の削除対象外。
- Apps VMを再構築する際は[復旧手順](../operations/apps-vm-recovery.md)のProxmox ACL再付与に注意。
- DGX Spark 2台の`/etc/fstab`追記は別作業として未実施。
- Apps VMのCompose定義は`origin/main`から供給される。ブランチ上の変更はmerge前に実機へ反映されない。
