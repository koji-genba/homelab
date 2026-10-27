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
│   ├── Open WebUI
│   ├── sparkDash (DGX remote monitor)
│   ├── SearXNG + MCP
│   ├── hf-downloader (モデル・データセット取得キュー)
│   ├── Homepage (サービスリンク集)
│   └── Gatus + Healthchecks.io dead-man
├── Tailscale gateway                 192.168.10.102
├── ElastiFlow                        192.168.10.103
├── Hermes Agent VM                   192.168.10.104 (Hermes + Hindsight記憶、repo定義・未構築)
└── Hermes Runner VM                  192.168.10.105 (実行・隔離ブラウザ、repo定義・未構築)
```

Compose定義は12 projects / 13 servicesです。sparkDashの初回反映は[運用手順](docs/operations/sparkdash.md)に従います。

Hermesの常駐エージェントはApps VMとは別の2台（Agent VM / Runner VM）で動かします。両VMともtailnetには参加せず、
Apps VMの15分reconcileの対象外で、`make ansible-apply-agent`で手動反映します。初回構築と運用は
[Hermes Agent運用](docs/operations/hermes-agent.md)を参照してください。
2026-10-17時点で両VMの初回構築は未実施です。ローカルでは新規sessionの想起・訂正・未知属性・再起動後の品質閾値と会話p95目標を満たしました。
会話の創作1件が残ります。2026-10-17のユーザー決定（WS14）でAgent VMは12 vCPU / 24 GiB、embedding 4 CPU / 8 GiB、
reranker 6 CPU / 4 GiBとします。rerank候補は品質優先でMID 20 / HIGH 30を維持します。
2026-10-18の決定（WS18）でrerankerは自前FP32 ONNXを同梱したTEI ORT imageへ切り替え、embeddingはCandleのままです。
WS15のローカル20候補p50は3.49秒から約1.07秒へ短縮し、tanh GELUでCandleとの全順位一致を確認しました。
reranker ONNX imageは2026-10-18に公開・digest固定済みで、Hermes・memory-dbとあわせて3つの自前image全てが
`compose.yaml`に固定されています。起動helperはALL-ZERO placeholderや未固定imageを拒否します（安全策）。本番での会話応答性は適用後に再計測します。
`memory.write_approval: false`、`skills.write_approval: true`も決定済みです。本番未適用で、Runnerは模擬コンテナでの部分確認、本番DRは未検証です。

Caddy、DNS、SMBはLAN IPに加え、Apps VMのtailnet IP `100.86.147.127`でも公開します。
内部FQDNはこのtailnet IPを返します。登録・DNS切替の詳細は[Apps VMのtailnet参加](docs/operations/apps-vm-tailnet.md)を参照してください。

VLAN 10はServer、20はTrusted、30はIoT、40はGuestです。VLAN 11と63は廃止済みです。

## まず読むもの

- [文書索引](docs/README.md)
- [現行アーキテクチャと復旧目標](docs/architecture/target-state.md)
- [コードの配置と責務](docs/CODEBASE_MAP.md)
- [設計判断（ADR）](docs/adr/README.md)
- [ネットワークゾーン仕様](docs/network/target-zones.md)
- [Proxmoxホスト復旧手順](docs/operations/proxmox-host-recovery.md)
- [Apps VM復旧手順](docs/operations/apps-vm-recovery.md)
- [Apps VMのtailnet参加](docs/operations/apps-vm-tailnet.md)
- [アプリ更新・promotion・rollback](docs/operations/application-lifecycle.md)
- [NFS export契約と手動反映メモ](docs/operations/nfs-export.md)
- [DGX Sparkストレージ運用](docs/operations/dgx-storage.md)
- [Open WebUI運用](docs/operations/open-webui.md)
- [SearXNG / MCP運用](docs/operations/searxng.md)
- [sparkDash運用](docs/operations/sparkdash.md)
- [hf-downloader運用](docs/operations/hf-downloader.md)
- [Hermes Agent運用](docs/operations/hermes-agent.md)
- [Hermes Agentバックアップ運用](docs/operations/hermes-agent-backup.md)
- [Homepage運用](docs/operations/homepage.md)
- [過去の監査・移行・実施記録](docs/archive/README.md)

設計変更は新しいADRまたは日付付き補足で記録し、索引・現行設計・運用手順を更新します。
採用時点の判断は固定し、前提が変わった場合は[ADRの規則](docs/adr/README.md)に従い新しいADRで置き換えます。

## リポジトリ構成

```text
docs/
├── README.md                    # 文書索引
├── adr/                         # 採用理由とトレードオフ
├── architecture/                # 現行設計と復旧目標
├── archive/                     # 凍結した過去の監査・移行・実施記録
├── network/                     # VLANゾーンと手動反映の期待状態
└── operations/                  # 日常操作、復旧、サービス・ストレージ運用
files/
├── infrastructure/
│   ├── terraform/apps-vm/       # Apps VM
│   ├── terraform/agent-vm/      # Hermes Agent VM
│   ├── terraform/runner-vm/     # Hermes Runner VM
│   ├── terraform/tailscale/     # Tailscale設定
│   ├── ansible/apps/            # OS、NFS、firewall、Compose lifecycle
│   ├── ansible/agent/           # Agent/Runner VMのOS・サービス
│   ├── network/                 # IX2215の設定と手動変更記録
│   └── secrets/                 # SOPS暗号化済みruntime secrets（agent/を含む）
├── services/
│   ├── compose/                 # サービス単位のCompose project
│   ├── agent/                   # Hermes AgentのCompose stack（reconcile対象外）
│   └── images/                  # カスタムイメージ
scripts/                         # preflight、rollback、state backup/restore
```

カスタムイメージは [caddy-image.yml](.github/workflows/caddy-image.yml) と
[sparkdash-image.yml](.github/workflows/sparkdash-image.yml) でGHCRへ公開します。
sparkDashはDGXのremote monitorとしてComposeに登録し、公開imageのdigestを固定します。
hf-downloaderは[dagu-hf-image.yml](.github/workflows/dagu-hf-image.yml)でDagu + Hugging Face CLIのimageを公開します。
上流更新とComposeのdigest更新は別の変更で行います。hf-downloaderは2026-10-27に本番反映し、
2026-10-28の受け入れ結果は[hf-downloader運用](docs/operations/hf-downloader.md)に記録しています。
Hermesの自前イメージ（`homelab-hermes-agent` / `homelab-memory-db`）は
[hermes-agent-image.yml](.github/workflows/hermes-agent-image.yml) と
[memory-db-image.yml](.github/workflows/memory-db-image.yml) で公開し、同じくdigestを固定します。

## 操作方針

日常操作はルートの `Makefile` を入口にします。管理端末に要求するのは原則としてGit、Docker、Make、SSHだけで、TerraformやAnsibleなどはバージョン固定のtoolboxから実行します。

ローカル検証も行う場合のPython/PyYAMLなどの追加依存は[toolbox README](files/tools/homelab-toolbox/README.md)を参照してください。

実環境の変更は次の境界を守ります。

- Terraformの `apply`、Ansibleの適用、Tailscale変更は手動実行
- stagingのアプリケーション更新は自動反映、productionは明示的な昇格
- 現行構成ではlegacy IPを使用しない
- Apps VMでage秘密鍵を保持しない。復号は管理端末で行い、runtime secretだけをroot専用領域へ転送する
- Terraform stateはローカル管理し、同じリポジトリの `state-backup` branchへage暗号化した復旧コピーを保存する
- NFS mountとmarkerの検証に失敗した場合はアプリケーションを起動しない

実機へ変更を適用する前は、対象の運用手順とpreflightを確認してください。`stashPadDev`（VMID 111）は作業用VMで、この移行の対象外です。
