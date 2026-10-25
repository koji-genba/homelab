# 現行アーキテクチャと復旧目標

- 状態: 現行設計（Compose移行済み）と未達の目標。実機反映の確認日は各運用記録を参照
- 承認日: 2026-08-29
- 根拠: [移行前の監査記録](../archive/current-state-audit.md)
- 実機基準点: [移行前の実測（2026-08-30）](../archive/live-inventory-2026-08-30.md)
- 移行記録: [KubernetesからComposeへの移行](../archive/k8s-to-compose.md)
- 復旧手順: [Apps VM復旧](../operations/apps-vm-recovery.md)
- 設計判断: [ADR一覧](../adr/README.md)
- ネットワーク仕様: [目標ネットワークゾーン](../network/target-zones.md)

## 目標

Proxmoxがインストール済みで、NFS/ZFS上のデータが復旧済みという状態から、リポジトリと
KeePassXC内の復旧情報（recovery material）を使って全アプリケーション機能を再構築できるようにする。

維持する機能は次のとおり。

- stashPad prod/staging、分離されたmetadata、共有media、staging自動更新、prod明示promotion
- SillyTavernのdata、認証、既存FQDN
- Sambaの既存3 shareと既存user（現在は`ai`を加えた4 share。定義は`files/services/compose/samba/config/smb.conf`）
- 内部DNS record、広告block、allow/block list、TailscaleグローバルDNS
- LAN/Tailscaleからの既存FQDNとTLS
- service監視、Discord通知、外部dead-man監視

ZFSスナップショット、レプリケーション、NFSサーバー自体の復旧はこのプロジェクトの対象外とする。
ただし、必要なexport、mount、marker、permissionを契約として記録し、mountできない場合は
アプリケーションを起動しない。

## 再構築性とbackupの方針

2026-10-12の運用者の判断として、他のVMも含め、repoから機能を再構築できるVMはbackupを取らず、
できないVMは取得する方針とする。repoから再構築できる状態を目標とし、残る穴は
[#87](https://github.com/koji-genba/homelab/issues/87)で追跡する。
ただし、同日の運用者判断でElastiFlowとstashPadDevは失ってよいVMとし、backupを取らない。
これはrepoから再構築できるという評価によるものではない。結果として、全VMのVM backupを取らない。
再構築には上記の復旧済みNFS/ZFSデータと、[復旧用アーティファクト](#復旧用アーティファクト)が必要である。

| 対象 | repoから再構築できるか | diskとともに失うもの | backup |
| --- | --- | --- | --- |
| Apps VM（101） | できる。Terraform → Ansible → Compose。tailnet登録とProxmox権限は文書化された手作業。ただし現行11 projectsでの通し再構築は未実証 | AdGuardの統計・query log、Sambaのログ、Gatusの履歴、sparkDashのunit登録（[再登録手順](../operations/sparkdash.md#永続化backup復旧)あり） | 取らない |
| Tailscale gateway（102） | できる。template 9000からcloneし、手動登録 → Ansibleでprefs適用 → Terraform / 管理画面でroute承認を行う（Ansible手順は実機未検証）。templateの作成が固定されていない点は穴 | nodeのidentity（再登録が必要） | 取らない |
| ElastiFlow（103） | サービスは作り直せるが、`install.sh`の実行・dashboardの取り込みに手作業が残り、dashboardの取得元も固定されていない（[詳細](../../files/infrastructure/terraform/elastiflow/README.md#再構築性とbackup)） | 過去のフローデータ、Kibanaのdashboardへの変更 | 取らない（過去のフローは不要。VMを作り直し、空のindexから取り込み直す） |
| stashPadDev（111） | 2026-10-25に[READMEで開発環境を宣言](../../files/infrastructure/terraform/stashpad-dev/README.md#開発環境の再構築)。手順は実機で通し実行しておらず未検証。template 9000の固定は別の穴として残る | VMの中にしか無い作業、宣言外の追加ツールや設定 | 取らない（重要ではないUbuntuの開発用VM。VM内だけの作業は運用者が別途pushする） |
| Hermes Agent VM（104） | 実装上は可能（実機未検証）。Terraform → Ansible。記憶DBとHermesデータはVM内の専用データディスクにあり、[日次バックアップ](../operations/hermes-agent-backup.md)から戻せる | 直近バックアップ以降の記憶の更新 | 取らない（Proxmox VM backupは取らず、アプリケーションレベルの日次バックアップをpve1のNFS exportへage暗号化して保存する。復号identityはVMに置かない） |
| Hermes Runner VM（105） | 実装上は可能（実機未検証）。Terraform → Ansible。実行accountとChromiumは宣言から再作成する | VM内だけの作業ツリー（キャッシュを除きAgentのバックアップに含める） | 取らない（実行・ブラウザ専用。Discord token・記憶DB・管理鍵を置かない設計） |
| template 9000 | 作成例はあるが固定されていない（[ホスト復旧](../operations/proxmox-host-recovery.md#template-vm-9000)） | — | 取らない（作成の固定は#87で追跡） |

Apps VMのproject定義は`files/services/compose/*/compose.yaml`を正とする。
[2026-09-06の再構築実証](../archive/implementation-status.md#phase-3-再構築性の証明2026-09-06全項目合格)は当時の7 projectsでの記録である。
2026-10-12のpve1確認ではProxmoxのbackup jobもVM backupも無い
（[確認記録とnamed volumeの復旧範囲](../operations/apps-vm-recovery.md#vm内named-volumeの復旧範囲)）。
この方針はVMの再構築を対象とし、pve1のZFS pool上のデータ（NFSでmountするアプリのデータ・共有）の保護は別に扱う。
Hermes Agent VM（104）の記憶・セッション・Runner作業ツリーはrepoから再生成できないため、VM backupの代わりに
日次のアプリケーションレベルbackupをpve1のNFS exportへage暗号化して取る（[Hermes Agentバックアップ運用](../operations/hermes-agent-backup.md)）。
設計判断は[ADR-0008](../adr/0008-hermes-agent-hindsight-vms.md)を参照する。

## 実行環境の構成

```text
Proxmox pve1 192.168.10.11
├── ZFS/NFS                         今回の移行における復旧対象外
├── apps VM (Debian 13)
│   ├── Caddy                       80/443
│   ├── AdGuard Home                53/tcp, 53/udp
│   ├── Samba                       445/tcp
│   ├── stashPad prod/staging       内部Docker network
│   ├── SillyTavern                 内部Docker network
│   ├── Open WebUI                  内部Docker network
│   ├── SearXNG / mcp-searxng       内部Docker network
│   ├── sparkDash                   内部Docker network -> DGX (SSH/HTTP)
│   ├── Homepage                    内部Docker network
│   └── Gatus                       内部Docker network
├── Hermes Agent VM (Debian 13)     192.168.10.104。Hermes + Hindsight + 記憶DB + TEI（tailnet外）
├── Hermes Runner VM (Debian 13)    192.168.10.105。実行とヘッドレスChromium（tailnet外、Dockerなし）
├── Tailscale gateway               VM定義はTerraform、node登録は手動、route広告はAnsible
├── ElastiFlow                      維持
└── stashPadDev                     一時VM、対象外

Healthchecks.io                     外部dead-man監視
GitHub/GHCR                         ソース、CI、公開イメージ
```

`files/services/compose/*/compose.yaml`の定義は11 projects / 12 services。sparkDashはremote-onlyで、初回反映は
[sparkDash運用](../operations/sparkdash.md)に従う。
HomepageはGit管理の静的リンク集で、[Homepage運用](../operations/homepage.md)に従って初回反映する。

Apps VMはVMID 101、Debian 13、管理userは`deploy`で、LAN `192.168.10.101`と
tailnet `100.86.147.127`でサービスを公開する。LAN IP・VMID・legacy NIC無効は
`files/infrastructure/terraform/apps-vm/variables.tf`、tailnet IP・legacy IP無効は
`files/infrastructure/ansible/apps/group_vars/apps.yml`に定義する。
Tailscale gatewayのVM定義とtailnet ACL/DNSはTerraformで管理し、gatewayのnode登録は手動で行う。route広告・exit nodeのprefsは
[gateway専用Ansible](../../files/infrastructure/terraform/tailscale-gateway/README.md)で管理する（実機未検証）。移行の経緯は[移行記録](../archive/k8s-to-compose.md)を参照する。

## サービス経路

| FQDN/サービス | 転送先 | 認証 |
| --- | --- | --- |
| `prod.stashpad.kojigenba-srv.com` / `prod.kojigenba-srv.com` | Caddy -> stashpad-prod | ネットワーク境界/現行アプリの挙動 |
| `staging.stashpad.kojigenba-srv.com` / `staging.kojigenba-srv.com` | Caddy -> stashpad-staging | ネットワーク境界/現行アプリの挙動 |
| `sillytavern.kojigenba-srv.com` | Caddy -> SillyTavern | 既存Basic Auth |
| `openwebui.kojigenba-srv.com` | Caddy -> Open WebUI | Open WebUI内蔵ログイン |
| `searxng.kojigenba-srv.com` | Caddy -> SearXNG | ネットワーク境界（Caddyの信頼network制限、loginなし） |
| `mcp-searxng.kojigenba-srv.com` | Caddy -> mcp-searxng | ネットワーク境界（Caddyの信頼network制限、認証なし） |
| `sparkdash.kojigenba-srv.com` | Caddy -> sparkDash:5555 | 信頼network/tailnet制限 + アプリBearer token（Caddy Basic Authなし） |
| `dns.kojigenba-srv.com` | Caddy -> AdGuard Home UI | AdGuard内蔵ログイン |
| `status.kojigenba-srv.com` | Caddy -> Gatus | Caddy Basic Auth |
| `homepage.kojigenba-srv.com` | Caddy -> Homepage:3000 | 信頼network/tailnet制限 + Caddy Basic Auth（Gatusと共用） |
| DNS | Apps VM port 53 | Server/Trusted/Tailscaleからの接続制限 |
| SMB | Apps VM port 445 | 既存Sambaローカルユーザー |

Tailscaleのglobal nameserverはApps VMのtailnet IPを参照する。AdGuardの内部サービス名と
`samba.kojigenba-srv.com`のrewriteも同じIPを返し、Web/SMBはApps VMへ直接到達する。
DNSの定義元は`files/infrastructure/terraform/tailscale/`と
`files/infrastructure/ansible/apps/roles/secrets/templates/AdGuardHome.yaml.j2`である。
client側の経路・接続先は[Apps VM tailnet運用](../operations/apps-vm-tailnet.md)を参照する。

管理UI、SSH、SMB、DNSの到達元はnftablesとIX2215 ACLで制限する。Internetへ公開サービスを
公開しない。CloudflareはDNS-01 challengeだけに利用する。

<a id="storage-contract"></a>

## ストレージ契約

### 現在のアプリケーションデータ

| サービス | NFSサーバーパス |
| --- | --- |
| SillyTavern | `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa` |
| stashPad prod | `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b` |
| stashPad staging | `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b` |
| Open WebUI | `/mnt/tank-gen2/data/k8s-volumes/open-webui` |
| stashPad media | `/mnt/shared/koji-genba/stashPadLib` |
| Samba shared | `/mnt/shared` |
| Samba shared-hdd | `/mnt/tank-gen2/data/shared` |
| Samba archive | `/mnt/tank-gen1/data/archive` |
| Samba ai / DGX Spark | `/mnt/tank-gen2/data/ai` |

現在もopaque PVC由来pathをmountする。`k8s-volumes`は現行のデータパスであり、削除対象ではない。
`files/infrastructure/ansible/apps/group_vars/apps.yml`の`nfs_mounts`は9 mountである。
初期7 mountに`ai`を加えて8、Open WebUIを加えて9となった。

### Apps VM内のlocal volume

Caddyは`caddy-data`/`caddy-config`、AdGuardは`adguard-work`、SearXNGは`searxng-cache`を持つ。
Gatusは`gatus` named volumeにSQLite（`/data/data.db`）の監視履歴とalert状態を保存する。
定義元は各projectの`compose.yaml`と`monitoring/config.yaml`であり、これらはNFS/ZFSデータの
復旧だけでは戻らない。Gatusのbackup方針は[アプリ更新・promotion・rollback](../operations/application-lifecycle.md#通常のreconcile)、
VM全体の復旧は[Apps VM復旧](../operations/apps-vm-recovery.md)を参照する。
Apps VMのdisk喪失時にnamed volume自体は戻らないが、サービスの設定・identityは宣言とsecretから再生成する。
VM backupを取らない判断と、失う履歴・ログは[再構築性とbackupの方針](#再構築性とbackupの方針)に従う。
確認方法と再生成できる範囲は[VM内named volumeの復旧範囲](../operations/apps-vm-recovery.md#vm内named-volumeの復旧範囲)を参照する。

sparkDashのconfigはApps VMのnamed volume `homelab-sparkdash_sparkdash-config`へ保存する。
初回所有権はimageの10001:10001を引き継ぐ。2026-10-11時点では自動backupを構築せず、VM外の暗号化backupも
必須としない。volume喪失時は再deployとUIでの2台の再登録で復旧する。unit数・benchmark結果・保存secretが
増えたら見直す。保存secretの暗号鍵はciphertextと同じvolumeに置かれる。
NFS/ZFS snapshotやTerraform state-backupには含まれない。
復旧方針は[sparkDash運用](../operations/sparkdash.md)を参照する。

### NFS export契約

`/mnt/tank-gen2/data/ai`はDGX Spark 2台とApps VMが共有する単一exportで、client範囲は
`192.168.10.0/24`のままとする（[ADR-0006](../adr/0006-ai-dataset-single-export.md)）。

既存4親exportのclientはApps VM `192.168.10.101/32`だけとし、基本optionは
`rw,sync,no_subtree_check,no_root_squash`とする。詳細は[NFS export契約](../operations/nfs-export.md)を
正とする。2026-10-12にpve1の`exportfs -v`で既存4 exportの`/32`、`ai`の`/24`、
sharedのfsidが契約どおりであることを確認した（[確認記録](../operations/nfs-export.md#実測された親export)）。
pve1の`/etc/exports`はrepo管理外であるため、変更時は`exportfs -v`で確認する。
段階的なexport切替の経緯は[移行記録](../archive/k8s-to-compose.md)を参照する。

VM側はNFSv4、`hard,_netdev`を使用する。systemd mount unit、`RequiresMountsFor=`、
`findmnt`でのfilesystem type確認、dataset固有markerのすべてを通過しなければCompose
プロジェクトを起動しない。

## 未達の目標・未決事項

- opaque PVC由来pathから`/mnt/tank-gen2/data/apps/{sillytavern,stashpad-prod,stashpad-staging}/`へ
  copy/検証して宣言を切り替える計画は、現行コードには未反映である。既存計画では`mv`を使わず、
  UID/GID、ACL、xattr、hardlinkを保持する。計画の継続・撤回は未決である。
- `no_root_squash`は初期互換性のための契約であり、UID/GID検証後に`root_squash`へ
  狭められるか再評価する目標は未決である。

## ライフサイクルと更新

- 全imageをdigestで宣言する。
- Dependabotが週次でCompose（`docker-compose`）、Dockerfile（`docker`）、Terraform
  （apps-vm / agent-vm / runner-vm / tailscale）、GitHub Actionsを確認する。
  Proxmox providerの更新は3 VM rootを同じversionに揃えてレビューする。
  Compose directoryを`docker`で指定した旧設定の`dependency_file_not_found`は、
  `compose.yaml`を検出する専用ecosystemへの切り替えで対処する。
- `compose.yaml`のdigest-only参照はDependabotの更新先が元のtagではなく`latest`のdigestになるため、
  Appsの上流imageはtag+digestへ移行するフォローアップPRまでignoreで除外し、移行後に削除する。
  Appsの自前・promotion管理imageは`koji-genba/*`で恒久的に除外し、検証済みdigestの手動反映と
  stashPad staging専用の`edge`追跡を維持する（directoryの監視は将来の上流image用に残す）。
  Agent stackの自前`koji-genba/homelab-*`は各workflowの検証済みdigestへ手動で再pinするため除外する。
  上流TEIとHindsightは`cpu-1.9.4@sha256:…` / `1.1.0-slim@sha256:…`のtag+digestで追跡し、
  version更新時もCPU/slim variantの維持を確認する。
  embedding TEIとreranker imageのTEI baseは別々のPRになるため、同じTEI versionに揃えて一緒にレビューする。
  reranker DockerfileのPythonはcp312・hash固定wheelに合わせminor/major更新を除外し、
  `3.12-slim`のdigest更新とTEI base更新は継続する。
  対応根拠: [GitHub Docs](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories#docker-compose)、
  [digest-onlyの更新先](https://github.com/dependabot/dependabot-core/blob/main/docker/lib/dependabot/docker/update_checker.rb)。
- stashPad stagingは定期workflowが`edge`の新digestを検出し、staging定義だけを
  mainへcommitして自動反映する。branch protectionで直接pushを禁止する場合はPR方式へ変更する。
- prodは明示的にversion/digestをpromotionしてmainへmergeする。
- CaddyはCloudflare moduleをversion固定してCI buildし、public GHCRのdigestを使う。
- AdGuard Homeの完全な設定は管理者認証hashを含むため、Gitのallow/blockやlocal
  recordを変更したときもAnsibleを明示適用して再生成する。
- WatchtowerとCIからの直接deployは使わない。

## 復旧用アーティファクト

| アーティファクト | 保管場所 |
| --- | --- |
| 望ましい状態と手順 | Git main branch |
| 暗号化Terraform復旧state | Git `state-backup` branch |
| SOPS暗号化secret | Git main branch |
| age復旧鍵 | KeePassXC |
| ProxmoxとTailscaleのcredential | KeePassXC、デプロイ時に注入 |
| NFS上のアプリケーションデータ | 外部で復旧したNFS/ZFS（Apps VM内のlocal volumeは含まない） |
| sparkDash config | 自動backupなし。再deployとUIで2台を再登録（約5分）、token・SSH鍵はSOPSから再配置 |

### Hermes Agentの確認範囲（2026-10-17）

Agent/Runner VMの初回構築は未実施。ローカルでは会話・export・暗号化scratch restoreとDB復元を確認したが、
新規sessionの想起等の品質閾値と会話p95目標は達成したが、創作1件と20候補rerank速度目標の未達が残る。
Runnerは模擬コンテナの部分試験までで、実VMの復旧・systemd制限・NFS/Discordは未検証。
2026-10-17のユーザー決定（WS14）でAgent VMを12 vCPU / 24 GiBとし、reranker 6 CPU / 4 GiB・embedding 4 CPU / 8 GiBとする。
TEIのCPU上限合計10に対して他サービスとOSに2 CPU相当の余地を残す（予約ではない）。全サービスのメモリ上限合計は
16.625 GiBで、OS・Docker・page cacheに7.375 GiBの余裕がある。swapなしのwarm-upピークを踏まえた値とする。
品質優先でrerank候補MID 20 / HIGH 30を維持し、3秒目標は未達のまま受け入れる。WS13ではbatch 4制約により
rerankerは6 CPUを超えてもほぼ伸びず、新配分の会話応答性は本番適用後に再計測する。
`memory.write_approval: false`で組み込み記憶は即時書き込み、`skills.write_approval: true`は維持する。
Hindsightの自動retainは承認ゲートの対象外で、custom抽出とSOULによる方針を継続する。これらの本番適用は未実施。
計測値と制約は[Hermes Agent運用](../operations/hermes-agent.md#サービスの資源上限)を参照する。
