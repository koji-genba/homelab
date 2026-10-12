# 文書アーカイブ

この配下は凍結した履歴であり、現在の作業指示ではない。歴史本文の観測値・判断は更新しない。
冒頭注記・リンク・索引の補修は行う。現行の構成と手順は[文書索引](../README.md)から辿る。

| ファイル | 対象時期 | 内容 | 現在これに代わるもの |
| --- | --- | --- | --- |
| [current-state-audit.md](current-state-audit.md) | 2026-08-13〜08-30 | 移行前の構成監査と設計判断の根拠 | [目標アーキテクチャ](../architecture/target-state.md) |
| [live-inventory-2026-08-30.md](live-inventory-2026-08-30.md) | 2026-08-30 | Proxmox、旧Kubernetes、NFS、ネットワークの実測スナップショット | [目標アーキテクチャ](../architecture/target-state.md)、[NFS export契約](../operations/nfs-export.md) |
| [k8s-to-compose.md](k8s-to-compose.md) | 2026年8〜9月 | 移行手順、Phase 0〜5の実施記録と受入試験 | [Apps VM復旧手順](../operations/apps-vm-recovery.md)、[アプリケーションのライフサイクル](../operations/application-lifecycle.md) |
| [k8s-rollback-state.md](k8s-rollback-state.md) | 2026-09-05 | 旧クラスタ停止直前の状態とUnbound復旧案の訂正 | [Apps VM復旧手順](../operations/apps-vm-recovery.md)、[アプリケーションのライフサイクル](../operations/application-lifecycle.md) |
| [next-session.md](next-session.md) | 2026-09-25 | 廃止・VMID整理後の引き継ぎと当時の残る確認事項 | [Apps VM復旧手順](../operations/apps-vm-recovery.md)、[DGX Sparkストレージ運用](../operations/dgx-storage.md) |
| [next-session-pre-phase5.md](next-session-pre-phase5.md) | 2026-09-19 | Phase 5着手前の安全条件、旧rollback、作業指示 | [目標アーキテクチャ](../architecture/target-state.md)、[Apps VM復旧手順](../operations/apps-vm-recovery.md)、[アプリケーションのライフサイクル](../operations/application-lifecycle.md) |
| [implementation-status.md](implementation-status.md) | 2026-08-30〜09-19 | Phase 0〜4の実装・検証・実機反映、Proxmox権限の欠陥、DGXストレージ反映 | [Apps VM復旧手順](../operations/apps-vm-recovery.md)、[DGX Sparkストレージ運用](../operations/dgx-storage.md) |
| [phase2a-inventory.md](phase2a-inventory.md) | 2026-09-05 | cutover前の読み取り専用調査、writer、IP所有権、snapshot計画 | なし |
| [ix-acl-stateful-runbook.md](ix-acl-stateful-runbook.md) | 2026-09-13 | IX2215 ACL移行の投入・受入・当時のrollback記録 | [ネットワークゾーン仕様](../network/target-zones.md)、[現行設定](../../files/infrastructure/network/config.txt) |
| [proxmox-rebuild.md](proxmox-rebuild.md) | 2026年6月 | 旧Kubernetes構成を前提とするホスト再構築手順 | ホスト自体の再構築手順は現行版が未整備。Apps VMは[復旧手順](../operations/apps-vm-recovery.md)を参照 |

## 現役の文書へ移した知見

| 知見 | 現在の所在 |
| --- | --- |
| Apps VMをdestroyする際のProxmox ACL再付与と403の診断 | [Apps VM復旧手順](../operations/apps-vm-recovery.md) |
| IX2215の現行ゾーンと設定の照合 | [ネットワークゾーン仕様](../network/target-zones.md)、[network README](../../files/infrastructure/network/README.md) |
| `make ansible-apply`に要る`SSH_AUTH_SOCK`と`AGE_IDENTITY_FILE` | [アプリケーションのライフサイクル](../operations/application-lifecycle.md)、[toolbox README](../../files/tools/homelab-toolbox/README.md) |
| 現行構成、復旧の安全条件、アプリrollback | [目標アーキテクチャ](../architecture/target-state.md)、[Apps VM復旧手順](../operations/apps-vm-recovery.md)、[アプリケーションのライフサイクル](../operations/application-lifecycle.md) |
