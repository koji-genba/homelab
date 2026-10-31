# 文書索引

現行の構成と運用手順は次の順で読む。過去の観測・移行記録は[アーカイブ](archive/README.md)にまとめてある。

## 現行構成

- [現行アーキテクチャと復旧目標](architecture/target-state.md): 現行の実行環境、サービス経路、ストレージ契約と未達の復旧目標・未決事項。
- [CODEBASE_MAP](CODEBASE_MAP.md): コードの配置、責務、反映経路と変更箇所の案内。

## 日常操作

- [アプリケーションのライフサイクル](operations/application-lifecycle.md): Git reconcile、stashPad promotion、Ansible反映、rollbackと再開。

- [UPS / NUT運用](operations/ups-nut.md): pve1の導入、停電・復電試験、しきい値と計画停止（2026-10-31に導入・dry-run試験を確認、本番停止は未検証）。

## 復旧

- [Proxmoxホスト復旧手順](operations/proxmox-host-recovery.md): 2026-10-12に確認したpve1の構成に基づく、ホストOS、ネットワーク、ストレージからVM群までの復旧手順。
- [Apps VM復旧手順](operations/apps-vm-recovery.md): 必要な復旧情報、Proxmox側準備、VM再構築と検証。
- [Apps VMのtailnet参加](operations/apps-vm-tailnet.md): tailnet登録、サービス公開、DNS切替と戻し方。
- [NFS export契約](operations/nfs-export.md): 必要なexport、mount、markerと手動反映の契約。

## サービス別運用

- [Homepage運用](operations/homepage.md): サービスリンク集の設定、初回反映、ログと復旧。
- [Open WebUI運用](operations/open-webui.md): DGXのvLLMへ接続するchat UIのデータ、設定、反映と検証。
- [SearXNG / MCP運用](operations/searxng.md): 検索とMCPの構成、利用側設定、反映と検証。
- [sparkDash運用](operations/sparkdash.md): DGX remote monitorのsecret、unit登録、永続化と更新。
- [hf-downloader運用](operations/hf-downloader.md): Daguの取得キュー、任意HF token、初回反映と復旧。
- [DGX Sparkストレージ運用](operations/dgx-storage.md): モデル・学習データ用NFSのpve1、Apps VM、DGX側手順と反映記録。
- [Hermes Agent運用](operations/hermes-agent.md): Agent VM / Runner VMの構成、初回構築、設定・image・secretの更新、ローカル計測・模擬Runner試験と残る品質/速度の制約。
- [Hermes Agentバックアップ運用](operations/hermes-agent-backup.md): 日次バックアップ、リストア、エクスポート、記憶再構築、健康確認とpve1側の準備。

## ストレージ・性能

- [tank-gen3運用](operations/tank-gen3.md): ai・archive mirrorのプロパティ、監視、scrubとarchiveの書き込み可・自動snapshot運用。
- [Tiered Storage](operations/tiered-storage.md): mergerfsのSSD書き込み層、moverとZFS snapshotの運用。
- [SMB転送速度トラブルシューティング](operations/smb-performance-troubleshooting.md): Tailscale経路とcache-poolのTRIMに関する調査記録。

## ネットワーク

- [ネットワークゾーン仕様](network/target-zones.md): Server、Trusted、IoT、Guestの境界と到達性、移行確認記録。
- [network README](../files/infrastructure/network/README.md): IX2215の設定基準と`config.txt`の管理方法。

## 設計判断

- [ADR索引](adr/README.md): 採用時点の設計判断と後続ADR。

## コードに隣接するREADME

| 文書 | 内容 |
| --- | --- |
| [runtime secrets](../files/infrastructure/secrets/README.md) | SOPS/age bundle、keyの形式とsecret編集・反映 |
| [pve1 NUT Ansible](../files/infrastructure/ansible/pve1/README.md) | NUTだけを管理するhost root、check/applyと管理境界 |
| [Ansible secrets role](../files/infrastructure/ansible/apps/roles/secrets/README.md) | 管理端末での復号とruntime secretの生成・転送 |
| [Apps VM Terraform](../files/infrastructure/terraform/apps-vm/README.md) | Debian 13 VMとcloud-init、credentialとplan/applyの前提 |
| [Tailscale gateway Terraform](../files/infrastructure/terraform/tailscale-gateway/README.md) | gateway VMの構築と手動登録 |
| [ElastiFlow Terraform](../files/infrastructure/terraform/elastiflow/README.md) | フロー収集・保存・可視化VMの構築 |
| [stashPadDev Terraform](../files/infrastructure/terraform/stashpad-dev/README.md) | 開発用VMの構築と操作 |
| [Tailscale Terraform](../files/infrastructure/terraform/tailscale/README.md) | tailnet ACL、DNS、routeのimport・plan・apply |
| [Compose](../files/services/compose/README.md) | projectの構成、起動順、検証とruntime設定 |
| [AdGuard config](../files/services/compose/dns/config/README.md) | 生成されたAdGuard設定の配置と更新の境界 |
| [DNS filters](../files/services/compose/dns/filters/README.md) | フィルターのGit sourceとAdGuard設定への反映 |
| [toolbox](../files/tools/homelab-toolbox/README.md) | 固定versionの実行環境、管理操作とローカル検証の依存 |

## 履歴

- [アーカイブ索引](archive/README.md): 移行前監査、実測値、完了した移行・実装記録と旧手順。

## 文書の置き方

現役の手順・設計は`archive/`の外に置き、コードの実体に合わせて更新する。
完了した作業記録・過去の観測は`archive/`に置き、歴史本文の観測値・判断を凍結する。
アーカイブの冒頭注記・リンク・索引は補修する。
ADRの採用時点の判断は固定し、設計判断の変更は新しいADRか日付付き補足で記録する。
前提を置き換える場合は[ADR索引の規則](adr/README.md)に従い、新しいADRと現行設計・運用手順・索引を更新する。
