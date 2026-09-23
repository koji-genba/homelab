# Homelab

自宅サーバーの構成、アプリケーション、ネットワークを管理するためのIaCリポジトリです。

本番アプリケーションはDebian 13のApps VM上でDocker Composeにより稼働しています。旧Kubernetes VMは2026-09-23に廃止しました。

## 目標

- Proxmoxインストール済みの状態から、リポジトリをcloneして復旧できる
- 提供中の機能とFQDNを維持しつつ、機能追加と日常運用を単純化する
- Terraform、Ansible、Compose、SOPS/ageの責務を明確に分ける
- Gitに望ましい状態と設計理由を残し、手作業は切替確認など必要な箇所に限定する
- NFS上の既存データを保護し、誤った空ディレクトリへの書き込みをfail closedにする

## 現行構成の概要

```text
Proxmox VE 192.168.10.11
├── Apps VM (Debian 13, 192.168.10.101)
│   ├── Caddy / AdGuard Home / Samba  192.168.10.101
│   ├── stashPad production/staging
│   ├── SillyTavern
│   └── Gatus + Healthchecks.io dead-man
├── Tailscale gateway                 192.168.10.102
└── ElastiFlow                        192.168.10.103
```

VLAN 10はServer、20はTrusted、30はIoT、40はGuestです。VLAN 11と63は廃止済みです。

## まず読むもの

- [目標アーキテクチャ](docs/architecture/target-state.md)
- [現状監査](docs/architecture/current-state-audit.md)
- [実機インベントリ（2026-08-30）](docs/architecture/live-inventory-2026-08-30.md)
- [設計判断（ADR）](docs/adr/README.md)
- [ネットワークゾーン仕様](docs/network/target-zones.md)
- [KubernetesからComposeへの移行手順](docs/migration/k8s-to-compose.md)
- [Phase 5の引き継ぎ](docs/migration/next-session.md)
- [移行記録アーカイブ（Phase 0〜4の完了記録）](docs/migration/archive/README.md)
- [Apps VM復旧手順](docs/operations/apps-vm-recovery.md)
- [アプリ更新・promotion・rollback](docs/operations/application-lifecycle.md)
- [NFS export契約と手動反映メモ](docs/operations/nfs-export.md)
- [DGX Sparkストレージ運用](docs/operations/dgx-storage.md)

設計を変更するときは、コードだけでなく該当ADRまたは運用手順も更新します。

## リポジトリ構成

```text
docs/
├── adr/                         # 採用理由とトレードオフ
├── architecture/                # 現状監査と目標構成
├── migration/                   # 段階移行、切戻し、廃止条件（archive/は完了記録）
├── network/                     # VLANゾーンと手動反映の期待状態
└── operations/                  # 復旧手順
files/
├── infrastructure/
│   ├── terraform/apps-vm/       # Apps VM
│   ├── terraform/tailscale/     # Tailscale設定
│   ├── ansible/apps/            # OS、NFS、firewall、Compose lifecycle
│   ├── network/                 # IX2215の設定と手動変更記録
│   └── secrets/                 # SOPS暗号化済みruntime secrets
├── services/
│   ├── compose/                 # サービス単位のCompose project
│   └── images/                  # カスタムイメージ
scripts/                         # preflight、rollback、state backup/restore
```

## 操作方針

日常操作はルートの `Makefile` を入口にします。管理端末に要求するのは原則としてGit、Docker、Make、SSHだけで、TerraformやAnsibleなどはバージョン固定のtoolboxから実行します。

実環境の変更は次の境界を守ります。

- Terraformの `apply`、Ansibleの適用、Tailscale変更は手動実行
- stagingのアプリケーション更新は自動反映、productionは明示的な昇格
- legacy IPの取得は旧所有者を停止し、ARP重複がないことを確認した後だけ許可
- Apps VMでage秘密鍵を保持しない。復号は管理端末で行い、runtime secretだけをroot専用領域へ転送する
- Terraform stateはローカル管理し、同じリポジトリの `state-backup` branchへage暗号化した復旧コピーを保存する
- NFS mountとmarkerの検証に失敗した場合はアプリケーションを起動しない

実機へ変更を適用する前は、対象の運用手順とpreflightを確認してください。`stashPadDev`（VMID 111）は作業用VMで、この移行の対象外です。
