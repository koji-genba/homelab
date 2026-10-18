# Hermes Agent運用

- 状態: 2026-10-18にAnsible適用、6サービス起動、健康確認・手動backup・scratch restore成功。Discord本受入、RunnerのChromium sandboxのsystemd hardening検証、本番DRは未完了
- 対象: Agent VM（`agent`、VMID 104、`192.168.10.104`）と Runner VM（`runner`、VMID 105、`192.168.10.105`）
- 設計判断: [ADR-0008](../adr/0008-hermes-agent-hindsight-vms.md)
- 復旧・バックアップ: [Hermes Agent運用（バックアップ・リストア・エクスポート・記憶再構築・健康確認）](hermes-agent-backup.md)
- コード配置: [CODEBASE_MAP](../CODEBASE_MAP.md)

この文書はAgent VM / Runner VMの構成、初回構築、日常運用、設定・image・secretの更新を扱う。
バックアップ、リストア、エクスポート、記憶再構築、健康確認は[別文書](hermes-agent-backup.md)を正とし、
ここでは重複させない。

## 用途と構成

個人用の常駐エージェントをDiscordを主窓口として動かす。長期記憶はHindsightへ保存し、コマンド実行と
ブラウザは別VMへ分離する。homelabの管理操作を行うためのものではなく、管理credentialも持たない。

```text
Discord
  │
  ▼
Agent VM 192.168.10.104 (VMID 104, VLAN 10, tailnet外)
  hermes      Hermes gateway（自前image、Hindsight provider同梱）
    ├── terminal backend (SSH) ──┐
    ├── memory → hindsight       │
    └── web → Apps VM の SearXNG/MCP
  hindsight   Hindsight API（local_external、bank `personal`）
  memory-db   PostgreSQL 17 + pgvector + PGroonga（自前image）
  embedding   TEI CPU / ruri-v3-310m
  reranker    TEI CPU ORT / ruri-v3-reranker-310m (FP32 ONNX同梱)
  cdp-tunnel  RunnerのCDPをSSH転送
                               │ SSH (専用鍵, from=192.168.10.104)
                               ▼
Runner VM 192.168.10.105 (VMID 105, VLAN 10, tailnet外)
  hermes-runner  実行account（sudoなし、dockerなし）
  hermes-browser ヘッドレスChromium（CDPはlocalhostのみ）
```

- 推論はDGXの単一エンドポイント`http://192.168.10.51:8000/v1`（`glm-5.3-flash`、OpenAI互換API、
  実体は`tensorfold serve`）を共用する。fallback providerは無い。テキスト専用。
- Agent stackは`files/services/compose/`の外にあるため、Apps VMの15分reconcile・起動helper・digest gate・
  `scripts/compose-config.sh`の対象にならない。変更は`make ansible-apply-agent`で人が反映する。
- 両VMとも`192.168.10.0/24`（Server VLAN）にあり、IPはTerraform変数と`group_vars/{agent,runner}.yml`が正。
  宅外からは既存gatewayのsubnet route（`192.168.10.0/24`）で到達する。Tailscale ACLは変更しない。

### サービスの資源上限

2026-10-17のユーザー決定（WS14）でAgent VMを**12 vCPU / 24 GiB**とする。swapはない前提で設計する。
Agent stackの各サービスは`mem_limit`を持ち、rerankerは`TEI_RERANKER_CPUS=6`、embeddingは`TEI_EMBEDDING_CPUS=4`とする。
embeddingのCandleプールは`RAYON/OMP/MKL=4`、rerankerの周辺プールは6、tokenization workersは6とする。
rerankerのORT intra-op threadsはTEIが`num_cpus::get()`で決める。固定版のnum_cpus 1.17.0はcgroup v1/v2 quotaを読み、
`cpus: 6`で6 threadsになる（OMP等のenvがORTを制御するわけではない）。rerankerは`memswap_limit: 4g`でswapを禁止する。
`max-batch-tokens`はembedding 4096 / reranker 2048を維持する。現行batch上限はembedding Candle 4 / reranker ORT 8。旧Candleでは、
`--max-batch-requests 1`もrouterに4で上書きされていたため削除した（WS16）。
検索queryのembeddingはrerankに先行するが、背景retainのembeddingは併走し得るため、両TEIの上限合計を
10 CPUに抑え、OS・Hermes・Hindsight・memory-db・CDP用に2 CPU相当の余地を残す。
これら他サービスにはCPU上限を設けず、固定CPUの予約や応答時間の保証とはしない。
WS7cのF3再生はreranker 4 CPUで約6.23秒、6 CPUで約5.07秒だった。
新配分は2026-10-18に本番適用済み。直列の単体測定は下記、会話p95・同時稼働時の応答性は未計測。

WS16では両TEIを**cpu-1.9.4**のindex digest `2538ea1c9640d3763b15af668039d24172d063b42337b0c27796fc2be180c78d`に更新する。
旧cpu-1.8.3の内部QueueCommandキューが満杯になるpanic（WS13c、上流#726の対策は1.9.0以降）が理由で、速度改善を目的としない。
1.9系は入力ごとにpermitを即時取得するため、従来C=16では単一の20/30候補rerankさえ429になる。
embeddingの`--max-concurrent-requests`は**128**（2同時×32入力+64）、rerankerは**64**（1同時×最大32入力+32）とする。
Hindsightは1 API worker、embedding batch=32・同時数=2（既定8から制限）を明示する。retainのCoalescingEmbedderは4枠だが、
query・他のretain・consolidationとproviderの共通2枠を共有するため、4×2で計算しない。
WS16の8同時負荷ではqueryの待ち時間がclient既定timeoutの30秒を超えたため、CPU backendへ積む量を2同時へ制限する。
1HTTPで32入力あり、2HTTPでもCandleの実行batch 4を供給できる。Cだけ増やして長い待ち行列を作らない。
rerankerは全recall共通の同時数1、client batch 32、候補LOW 8 / MID 20 / HIGH 30を維持する。
workers・replica・batch・同時数を増やす際はpermit数も再計算する。Cは待機入力数を増やし得るが、backendの実行batch上限とtoken上限は変えない。
固定Hindsight imageのTEI clientは429/5xxを最大3回retry（計4試行）し、使い切ると例外になる。
query embedding失敗もrerank失敗もrecallはエラーになり、429時にrerankを省略して成功を返す設定ではない。
負荷上限に合わせた設定で429自体を避ける。既知panicへの対策を含む版だが、キュー送信の`expect`は残るため全負荷での無障害を保証しない。

embeddingの事前取得はdownload-onlyで1 GiBに制限し、TEI起動前に完了する。rerankerはimage同梱のため事前取得とhost cache mountを使わない。上限は固定モデル前提の値で、
全6サービスの合計16.625 GiBに対し、OS・Docker・page cache用に7.375 GiBを残す。

| サービス | メモリ上限 | 根拠 |
| --- | --- | --- |
| embedding | 8 GiB | WS16 cpu-1.9.4: swapなし・4 CPU・threads4のwarm-up/全負荷peak 5.383 GiB、余裕2.617 GiB。WS13の旧版は4 GiBで起動OOM |
| reranker | 4 GiB | WS16 cpu-1.9.4: swapなし・6 CPUのwarm-up/全負荷peak 2.789 GiB、余裕1.211 GiB。旧版WS13cは3 GiB上限に張り付いた |
| memory-db | 2 GiB | WS7a/WS7c statsの最大254.7 / 175.1 MiB（旧上限の12.44% / 8.55%）のため据え置き |
| hindsight | 1 GiB | 同339.6 / 431.1 MiB（33.16% / 42.10%）のため据え置き |
| hermes | 1.5 GiB | 同473.4 / 392.6 MiB（30.82% / 25.56%）のため据え置き |
| cdp-tunnel | 128 MiB | メモリ計測記録が見つからないため据え置き |

WS16のメモリはcgroup `memory.peak`（page cacheを含む）をhealth初回成功後と負荷後に取得した値。
embeddingのthreads未設定→4は、同じWS13b入力でquery p50 0.198→0.106秒、32-fact retain p50 8.812→6.109秒となった。
最終C=128では単発query p50/p95 0.100/0.147秒、32-fact retain 6.163/6.533秒。
3分間、32件retainを2本並行しながら独立queryを0.5秒おきに送り、retain25回/query358回は全200、
query p50/p95/max 11.917/15.216/16.255秒、retain p50/p95/max 15.143/16.349/16.695秒だった。
queryも共通2枠を使う実clientより厳しいTEI直接負荷で、429・panic・OOMは無かった。
8同時の予備試験は全200でもquery p95 54.989秒だったため採用していない。
rerankerは20/30候補を直列で各60回、全200。20候補p50/p95 3.503/4.701秒は旧cpu-1.8.3の
WS15 3.492/4.718秒と同等（WS13cは3.397/4.503秒、数%の試行差あり）。30候補は4.945/6.730秒。
このローカルCPUでの結果であり、本番5900Xの直列測定は日常運用節に追記した。会話全体の待ち時間は未計測。token上限・候補数・モデルrevisionは維持した。

メモリ記録はWS7aの`itest/logs/{stats,stats-all}.jsonl`、WS7cの`itest/r2/logs/stats.jsonl`を照合した
サンプル最大であり、厳密なピークではない。上記の他サービスは70%を超えていない。
WS13ではembeddingは1 → 2 → 4 CPUでほぼ比例して速くなった。一方rerankerは6 / 8 / 10 CPUで
20候補p50が約3.40 / 3.29 / 3.49秒とほぼ変わらず、Candle ModernBertのbatch size 4制約により
CPU追加では3秒目標に届かなかった。ORTでの手元Ryzen 7 9800X3Dと本番5900Xの直列測定は日常運用節を参照。
WS7cの4.24秒もローカルstack（`http://reranker:8080`）の値で、本番pve1の実測ではない。
embeddingの`--max-batch-tokens`は4096を維持する。通常のretainは日付・entity付きfactをembeddingし、
chunk本文を送るのは`retain_extraction_mode=chunks`（LLM providerがnoneのとき）だけであるため、
4096の理由は長いfact・observationとprefixの余裕とする。Hindsightのo200kとruriのtokenizerは異なる。

2026-10-17の2回のローカル結合試験（いずれも架空データ）で、35会話、export、age暗号化scratch restore、
bank消去→DB復元を確認した。1回目（WS7a、修正前）は**記憶品質の総合受入は未達**、2回目（WS7c、WS12変更前の6-vCPU設定）は
B・D・E・I・Fの品質閾値と会話p95目標を満たした。Aの創作1件と20候補rerank速度目標の未達は残る。この時点では本番VM・Discord・NFSは未検証だった（2026-10-18の実績は末尾の手動反映記録を参照）。

1回目（修正前、WS7a）:

| 項目 | ローカル実測 / 判定 |
| --- | --- |
| B（新規session10問） | 完全正答60%、正答+部分70%。閾値80% / 90%に未達 |
| D / E | 旧情報の現在値としての提示を4/4で抑制、未知属性の創作0/5。ただしDの全文正答は50% |
| I / F | 事実/推測の分離に失敗。Fは全文正答25%、主要要素のみでも75%で100%未達 |
| A / C | Aは62.5%（年補完で3件創作）、Cは100% |
| 会話 end-to-end（35問） | p50 43.14秒 / p95 76.24秒（暫定目標60秒を超過） |
| 診断recall / 内部rerank | p50 7.73 / 7.03秒、p95 10.86 / 10.41秒（rerank目標5秒を超過） |
| retain/consolidation drain | p50 35.88秒 / p95 183.30秒。初期の停止・救済とpollingを含む |
| Compose再作成 / scratch restore / bank消去復元 | 101.03秒 / 27.65秒 / 24.53秒。復元前後119記憶一致 |
| 観測メモリpeak（GiB） | DB 0.249、embedding 4.000、reranker 2.446、Hindsight 0.332、Hermes 0.462 |

メモリはwarm-upを含むDocker statsのサンプル最大であり、厳密な最大値ではない。embeddingは4GiB上限付近まで
到達した。再作成はComposeでの停止・再起動で、VMのOS rebootを確認したものではない。scratchではRunner archiveを
stubにしており、本番restore helper全体・NFS日次backupの検証とは区別する。GLM中継の生成は正式会話の窓で268回、
正式回答のHermes usageは72 calls。Hindsightは識別できる本処理168回とstartup 6回で、初期ログ18回は呼出元不明。
初期の再開・probeも含むため、268回を正式35回答だけの消費量とは扱わない。

2回目（WS7c、WS14変更前の設定）:

| 項目 | ローカル実測 / 判定 |
| --- | --- |
| B（新規session10問） | 完全正答100%、正答+部分100%。閾値80% / 90%に合格 |
| D / E / I / F | Dの旧情報の現在値誤提示0、Eの未知属性創作0/不明100%、Iの事実/推測分離、Fの完全正答100%。すべて合格 |
| A | 87.5%（8問中7正答・1創作）。Cは100% |
| 会話 end-to-end（35問） | p50 22.14秒 / p95 50.39秒 / 最大82.04秒（暫定目標p95 60秒を達成） |
| 診断recall / 内部rerank | p50 4.79 / 4.03秒、p95 5.87 / 5.12秒。20候補rerankはp50 4.24秒で3秒目標は未達 |
| retain/consolidation drain | p50 12.73秒 / p95 96.01秒 / 最大134.81秒 |
| Compose再作成 / scratch restore / bank消去復元 | 94.15秒 / 21.93秒 / 17.30秒。復元前後52記憶一致 |
| 記憶汚染 | 質問だけの群（B・D・E・I・F）で記憶は増えず、assistant由来語句の混入は0件 |

2回目は候補の順位を変えず（最大スコア差約3.1e-8）本文を切らない設定で速度を改善した。品質ベンチは
145記憶・98質問でnDCG@10 0.873（embedding単体）、0.923（rerank後）とWS4のベストペア値に一致する。
GLM中継はHermes本処理55生成（p50 3.77秒）、Hindsight 118生成（p50 5.28秒）、startup 3生成。
20候補のrerank p50 3秒以内は未達だが、2026-10-17のユーザー決定で品質優先のMID 20 / HIGH 30を維持し、
未達のまま受け入れる。12 vCPU / 24 GiBの新配分の会話応答性は本番適用後に再計測する。
E群・I群で複数生成になる問の応答時間（E5 82.04秒、I1 78.10秒）は残課題で、品質とのバランスは引き続きユーザー判断とする。

ローカル模擬Runnerによる結合試験（WS7b、2026-10-17、架空データ）:

Runner VMの代わりに、role `runner`のテンプレート・変数から描画したDebian 13コンテナ（実Chromium、
nftables、`hermes-runner` / `hermes-cdp` / `hermes-browser`）を立て、WS7cのstackのterminal backend・
cdp-tunnelを模擬Runnerへ向けて試験した。以下はWS7b報告の結果で、WS8は保存stdoutと描画物を照合した。
鍵制約・egress・再接続の全ての生ログは残っておらず、systemd制限下の受入とは区別する。

| 項目 | ローカル実測 / 判定 |
| --- | --- |
| terminal backend | Hermesの依頼で`hostname`/`whoami`/`pwd`とファイル作成+一覧を実行。いずれも模擬Runner側で`hermes-runner`、`cwd=/srv/agent-work`として実行され、Agentコンテナ内に実行痕跡は無し |
| 実行accountの権限 | 模擬Runnerにsudo / docker は無く、`hermes-runner`は通常ユーザーのみ |
| 専用鍵の制限 | WS10で補強・再確認。`hermes-runner`鍵は通常コマンドを許可し、`-L` / `-R`を拒否。`hermes-cdp`鍵はlocal forwardingの宛先127.0.0.1:9222のみ許可し、`-R`・他宛先への`-L`・shell/exec・tty・subsystemを拒否 |
| known_hosts | 不一致のknown_hostsでは`Host key verification failed`で接続拒否 |
| ブラウザ（CDP） | cdp-tunnel（`user 10000:10000`）経由で実Chromium（`--no-sandbox`無し。内部sandbox状態の診断結果は未保存）の127.0.0.1:9222へ接続。loopback配信の静的ページの固有文字列と公開サイト（example.com）を取得。トンネル停止→再開後も利用可 |
| Runner egress | `192.168.10.51:8000` / `192.168.10.104` / `100.64.0.1` / `169.254.169.254`への新規接続は拒否、公開インターネット（1.1.1.1:443）は許可。確立済みSSH（戻り）は維持 |
| 運用helper再実行 | `homelab-agent-healthcheck`はrunner/cdpを含む全項目ok。`homelab-agent-backup`の`runner-work.tar.gz`を実模擬RunnerからSSH取得（内容一致） |

模擬と本番の違い（本番でしか確認できない点）:

- 本番Runnerはsystemd unitで起動する。模擬はunitの`ExecStart`引数のみを再現し、`Restart` /
  `ProtectSystem` / `RestrictNamespaces`等のsystemd hardeningは適用していない。
- 本番のChromium sandboxはDebianのunprivileged user namespace（`kernel.unprivileged_userns_clone=1`）で
  有効化する。模擬コンテナではDocker既定seccompが`clone`/`clone3`/`unshare`を落としてzygoteが起動しない
  ため、`clone`/`clone3`/`unshare`を広く許可する3ルールを足したseccomp profileを試験専用に使用した
  （`--no-sandbox`は使っていない）。本番VMでもsystemdの`RestrictNamespaces`は制限を加えるため、この試験だけでは本番sandboxの動作を保証しない。
- `authorized_keys`の`from=`は、模擬では試験networkのAgentコンテナIPに置換した。
- ブラウザツールは`security.allow_private_urls: false`のため、loopbackで配信する試験ページはHermesからは
  SSRF guardで読めない（設計どおり）。ingressの確認はCDP直結で行った。
- Runner VM本体・実NFS・実Discord・実推論エンドポイントでの最終受入は実機で行う。

RunnerのSSH制限（WS10、2026-10-17）:

- `hermes-cdp`の鍵は`from="<Agent IP>",restrict,port-forwarding,permitopen="127.0.0.1:9222"`。
  `permitopen`が制限するのはlocal forwardingの接続先で、`port-forwarding`はremote forwardingも再許可する。
  この鍵オプションだけでは`-R`を禁止できない（WS9で観察）。
- common roleの`99-homelab-hardening.conf`に、Runnerの変数がある場合のみ`Match User`を描画する。
  `hermes-cdp`には`AllowTcpForwarding local`、`PermitOpen 127.0.0.1:9222`、`PermitListen none`を設定し、
  `AllowStreamLocalForwarding` / `AllowAgentForwarding` / `X11Forwarding` / `PermitTTY` /
  `PermitTunnel` / `PermitUserRC`を`no`にする。`MaxSessions 0`でshell・コマンド・subsystemのsession channelを拒否するが、
  `ssh -N -L`のCDPトンネルは維持する。アカウントの`nologin`も維持する。
- `hermes-runner`には`DisableForwarding yes`、`AllowTcpForwarding no`、`PermitListen none`と
  Unix socket・agent・X11・tun転送の禁止を設定する。鍵側の既存制限も維持し、terminal用の通常コマンドは許可する。
  各ブロックは`Match all`で閉じ、Agent VMにはこれらのブロックを描画しない。配置前に候補ファイルを`sshd -t -f`で検証する。
- authorized_keysの`permitlisten="none"`は採用しない。Debian 13のOpenSSH 10.0p1で別の模擬sshdに対して試すと
  `bad key options: invalid permission port`で鍵認証自体が拒否された。`none`を使えるのはsshd_configの`PermitListen`。

仕様: [OpenSSH sshd(8)のauthorized_keysオプション](https://man.openbsd.org/sshd.8#AUTHORIZED_KEYS_FILE_FORMAT)、
[sshd_config(5)の転送・session制御](https://man.openbsd.org/sshd_config.5)。
WS10ではroleから再描画したDebian 13模擬Runnerで`sshd -t`、`sshd -T -C`と実SSHを確認した。
`-R`（動的ポートを含む）・Unix socket転送の拒否、上表の鍵別制限、Runnerのterminal相当の直接SSH、
Hermesイメージでrepoのcdp-tunnelコマンドを使った`/json/version`取得が成功した。
推論やgatewayを起動せず、内部Docker network上の試験のみで、本番VMへの適用・確認は未実施。

## ファイル配置と所有

| 対象 | パス / 定義元 |
| --- | --- |
| Terraform root（Agent VM） | `files/infrastructure/terraform/agent-vm/`（READMEあり） |
| Terraform root（Runner VM） | `files/infrastructure/terraform/runner-vm/`（READMEあり） |
| Ansible root（OS設定） | `files/infrastructure/ansible/agent/`（`site.yml`、inventory、group_vars、roles） |
| Compose定義 | `files/services/agent/stack/compose.yaml`（project `agent`） |
| Hermes Skill | `files/services/agent/hermes/skills/`（週次振り返り） |
| 自前image | `files/services/images/{hermes-agent,memory-db}/` |
| image workflow | `.github/workflows/{hermes-agent-image,memory-db-image}.yml` |
| secret bundle（暗号化） | `files/infrastructure/secrets/agent/runtime.sops.yaml`（exampleは同directory） |
| 反映target | `Makefile`のagent関連target（後述） |

Agent VM上の配置は次のとおり。role `agent_stack`がCompose環境を、role `agent_ops`がバックアップ系と
健康確認を配置する。

| パス | 内容 |
| --- | --- |
| `/opt/homelab-agent/compose.yaml` | 反映されたCompose定義 |
| `/etc/homelab/agent/compose.env` | 非secretの環境変数 |
| `/etc/homelab/secrets/{hermes.env,memory-db.env,agent-monitoring.env}` | 生成・転送されたsecret環境変数（root 0600） |
| `/etc/homelab/agent/ssh/` | 専用SSH鍵（Runner実行用、CDPトンネル用、known_hosts） |
| `/usr/local/sbin/homelab-agent-compose-up` | digestを検証して`up -d --wait`する起動helper |
| `/srv/agent/{hermes,postgres,models,exports,restore-scratch,restore-safety,rebuild,tmp}` | データdisk（`/srv/agent`、ext4）上の可変データ |
| `/srv/agent-work` | Runner VMの作業disk |

## 前提と初回構築の順序

各手順の検証状態を付す。`[実機未検証]`は実装から導いた手順であり、まだ実機で通していない。
Proxmoxのuser/role/token/ACLはTerraform管理外で、apply前に人が用意する（[Apps VM復旧のProxmox準備](apps-vm-recovery.md#terraform実行前のproxmox側準備)に倣う）。

1. **Proxmox側の手動準備** `[2026-10-18 実施]`
   VMID 104 / 105 と `192.168.10.104` / `.105` が空いていることを確認し、各Terraform用のAPI token
   （`terraform@pve!agent-vm` / `terraform@pve!runner-vm`、`privsep=0`）と、`/vms/104`・`/vms/105`および
   image importに必要なdatastore権限のACLを用意する。`terraform-*`のrootは重複確認のためのpingを行わない。
   対象datastore `local`のcontent typeに`Import`と`snippets`が含まれることを確認する。
   最初のAnsible接続前に、Proxmox console等のout-of-band経路で各VMのSSH host-key fingerprintを確認し、
   管理端末の`known_hosts`へ追加する。詳細は各rootのREADMEを正とする。
   実測: tokenとユーザーACLを追加済み。`privsep=0`の3 tokenは同じユーザーACLを継承し、VM別には分離されない。host keyは手順3のout-of-band経路で登録した。
2. **データdiskのby-id確認** `[2026-10-18 実施]`
   `group_vars/agent.yml`の`agent_data_disk`（既定`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1`）と
   `group_vars/runner.yml`の`runner_data_disk`が、hypervisorの割り当てと一致することを確認する。
   一致しない場合は`/dev/sdX`の並びではなくby-idで上書きする。role `agent_storage`は対象diskが無いと
   明示的に失敗する。
   実測: 両VMで既定の`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1`が存在し、group_varsと一致した。
3. **VM作成** `[2026-10-18 実施]`
   API tokenとSSH公開鍵を`TF_VAR_proxmox_api_token` / `TF_VAR_ssh_public_key`として管理端末へ一時注入し、
   validate → plan → applyの順で実行する。applyは保存planのみを使い`-auto-approve`を使わない。

   ```sh
   make terraform-validate-agent-vm
   make terraform-validate-runner-vm
   make TERRAFORM_ROOT=files/infrastructure/terraform/agent-vm terraform-plan
   make TERRAFORM_ROOT=files/infrastructure/terraform/agent-vm terraform-apply
   make TERRAFORM_ROOT=files/infrastructure/terraform/runner-vm terraform-plan
   make TERRAFORM_ROOT=files/infrastructure/terraform/runner-vm terraform-apply
   ```

   実測: bpg/proxmox 0.116.1で保存planから各`3 added, 0 changed, 0 destroyed`、両VMの`cloud-init status`は`done`。
   pve1の`qm guest exec <vmid> -- cat /etc/ssh/ssh_host_ed25519_key.pub`でed25519 host keyを取得し（`ssh-keyscan`は不使用）、
   管理端末の`known_hosts`へ登録後、両VMの`deploy`接続（`StrictHostKeyChecking=yes`）と`sudo -n true`が成功した。

4. **自前imageのdigest確認** `[公開済み]`
   自前3image（`homelab-hermes-agent` / `homelab-memory-db` / `homelab-tei-reranker-onnx`）は2026-10-18に
   `hermes-agent-image.yml` / `memory-db-image.yml` / `tei-reranker-onnx-image.yml`でbuild・公開済みで、
   そのimmutable digestは`files/services/agent/stack/compose.yaml`へ転記済み。3imageとも転記漏れが無いことを確認する。
   起動helperはALL-ZERO placeholderや未固定imageを検出すると起動を拒否する（安全策）。
   Dockerfile更新時の再転記は下記「image更新」の手順で行う。
5. **SOPS bundleの作成** `[実機未検証]`
   `files/infrastructure/secrets/agent/runtime.yaml.example`のkey一覧に従い、Discord bot tokenと
   user/channel ID、運用通知webhook、任意のdead-man ping URLを用意する。PostgreSQL passwordとSSH鍵は
   VM上で生成するためbundleへ入れない。初回は`make secrets-encrypt-agent`で暗号化する
   （既存bundleがある場合は上書きを拒否するため、編集はtoolboxの`sops set`を使い、編集後に`chmod 0600`する）。

   ```sh
   AGE_RECIPIENT=age1... make secrets-encrypt-agent
   AGE_IDENTITY_FILE=/secure/path/age-identity.txt make secrets-decrypt-check-agent
   ```
6. **pve1のバックアップexport準備** `[2026-10-18 実施]`
   pve1の専用datasetとNFS export、markerは[バックアップ文書のpve1準備節](hermes-agent-backup.md#7-pve1-側の事前準備手動自動化しない)に
   従って人が作成する。exportは`192.168.10.104/32`へ限定する。`group_vars/agent.yml`の
   `agent_backup_age_recipients`にはSOPS/state backupと同じhomelab復旧用age公開鍵を設定済み。
   空の間はバックアップがfail closedになる。
   role `agent_storage`は、pve1がexportを広告している場合だけ`/mnt/agent-backups`をmountし、
   advertiseされていない場合は安全にskipする。
   実測: dataset・`/etc/exports`・markerを作成し`exportfs -v`で確認済み。2026-10-18のAnsible適用でAgent VM側のnfs4 mountも確認した。
7. **Ansible適用** `[2026-10-18 実施]`
   実測: 16:49–16:58に初回適用（failed=0）、6サービス起動、ext4/nfs4 mount、17:00健康確認成功。約17:27の再適用でPGDATA所有権障害が発生し、運用者が復旧した（末尾の記録参照）。
   SSH agentとage identityを用意して手動適用する。Agent playが先に走り、Agent VM上で生成したRunner SSH鍵を
   factとしてRunner playが受け取るため、この順序は`site.yml`が保証する。

   ```sh
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519
   AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply-agent
   eval "$(ssh-agent -k)"
   ```
8. **受入確認** `[2026-10-18 一部実施]`
   健康確認（Hermes gateway・Discord connected・Runnerを含む）、手動backupとscratch restoreは成功。
   Discordの本受入、実RunnerのChromium sandboxのsystemd hardening検証、本番DRは残る。健康確認は[バックアップ文書の健康確認節](hermes-agent-backup.md#6-健康確認)を正とする。

## 日常運用

### ORT rerankerのbuild・一致検査（WS18、2026-10-18）

`homelab-tei-reranker-onnx`は元revision `bb46934ee9ed09f850b9fcff17501b3ef7ddb2b3`を
FP32 / opset17 / 動的batch・sequence軸でexportし、TEI cpu-1.9.4へ同梱する。
元モデルカードのApache-2.0宣言を確認済み。imageの`/model/`にLICENSE・MODEL_CARD.md・変更内容のNOTICEと
export.json・SHA256SUMSを保存する。実行時は`--model-id /model`と`HF_HUB_OFFLINE=1`でネットワーク取得を行わない。
モデル名・revisionは`export_model.py`で固定する。Ansibleのreranker model/revision変数はバックアップ出典情報だけに残し、
runtime引数や取得には使わない。fixtureでexporterとの一致を検査する。

Candleが使うtanh近似に合わせ、hidden層と分類headを`gelu_pytorch_tanh`にする。
WS15では20候補p50 3.49→約1.07秒、24クエリ・96回で全順位一致、最大スコア差2.21e-6。
これはローカル単体試験で、本番の会話p95の保証ではない。embeddingのCandle・prefix・次元・既存vectorは変更しない。

WS18でrepoのimageを実際にbuildし、6 CPU / 4g / swapなし / C64 / workers6で各60回を直列測定した。
8回の20/30候補warm-upを各backendで破棄し、cgroup memory.peakを測った（page cache込み）。

| backend | 20候補 p50 / p95秒 | 30候補 p50 / p95秒 | 起動warm-up / 全負荷peak GiB |
| --- | ---: | ---: | ---: |
| Candle（同じTEI・元重み） | 3.513 / 4.759 | 4.962 / 6.951 | 2.793 / 2.793 |
| ORT（自前FP32・tanh） | 1.134 / 1.524 | 1.657 / 2.259 | 2.756 / 2.762 |

全120回・3,000スコアで全順位一致、最大絶対差2.21e-6（閾値1e-4以下）。429・panic・OOMは無く、
memory.eventsのmax/oom/oom_killも0だった。4g上限まで約1.24 GiBの余裕がある。
ホストはRyzen 7 9800X3D / WSL2 Docker 16 vCPUで、本番pve1の測定ではない。

2026-10-18、本番pve1（Ryzen 9 5900X）のAgent stack内からrepoの架空rerank fixture（24 query）で直列測定した。

| 本番の処理 | p50 / p95秒 |
| --- | ---: |
| ORT rerank MID 20候補 | 1.73 / 2.36 |
| ORT rerank HIGH 30候補 | 2.60 / 3.66 |
| embedding 1 query | 0.08 / 0.17 |
| Hindsight recall（小規模の本番bank、5 results） | 約0.43 / 未計測 |

手元9800X3Dの参照値は20候補1.13/1.52秒、30候補1.66/2.26秒。MIDは3秒目標を満たすがHIGHのp95は超過する。
reranker CPU増加（`TEI合計 <= vCPU-2`に従いVMのvCPU増加も必要）またはHIGH 25候補が選択肢で、変更は未決。会話全体・並行負荷の保証ではない。


```sh
docker build -t homelab-tei-reranker-onnx:test files/services/images/tei-reranker-onnx
docker build --target candle-reference -t homelab-tei-reranker-candle:test files/services/images/tei-reranker-onnx
python3 scripts/tests/tei-reranker-parity.py \
  --ort-image homelab-tei-reranker-onnx:test --candle-image homelab-tei-reranker-candle:test \
  --output /tmp/tei-parity
```

一致検査は全24入力・全20順位とsigmoidスコアの最大絶対差≤1e-4を検査する。NaN・候補欠落・HTTP失敗も拒否する。
6 CPU / 4g / swapなし / C64 / workers6 / read-only / cap-drop ALLで順に起動し、作成したcontainerは終了時に削除する。
CIはrunner容量に合わせ2 CPUとし、同じscriptを実行する。`--runs 60 --extra-input <架空のrerank30.json>`で
ローカル受入の20/30候補各60回を実施できる。入力を追加する際は実在の個人情報・秘密を含めない。

依存更新はdigest固定Python・TEIとhash固定wheelの組合せを保ち、lock再生成後にbuildと一致検査をやり直す。
Linux amd64 / CPython 3.12用のwheelのみを許可する。モデルを変える際はrevision・ライセンス・出典・変換設定も再確認する。

### 起動・停止・再起動

Agent stackの起動はdigest検証付きのhelperを使う。`config`引数は`docker compose config`の静的検証だけを行う。

```sh
sudo /usr/local/sbin/homelab-agent-compose-up          # up -d --wait（cdp-tunnel含む）
sudo /usr/local/sbin/homelab-agent-compose-up config   # 静的検証のみ
```

個別操作はhelperと同じcompose引数で行う。`down`はcontainerとnetworkを消すだけで、bind mount先の
`/srv/agent`配下のデータは消さないが、通常の停止には`stop`を使う。

```sh
docker compose --project-name agent \
  --env-file /etc/homelab/agent/compose.env \
  --env-file /etc/homelab/secrets/memory-db.env \
  --file /opt/homelab-agent/compose.yaml stop
```

Hermesの設定を再読込する場合は、同じ引数で末尾を`restart hermes`にする（実行中の会話に影響するため保守時に行う）。

長命サービスは`restart: unless-stopped`のため、VM再起動後は自動で復帰する。operatorが`stop`した
サービスは停止のままになる。

### 設定変更

Hermesの`config.yaml`、`SOUL.md`（初回のみ`force: false`）、Hindsight `config.json`、bank policy、
週次振り返りcronはrole `agent_stack`がテンプレートから描画する。変更はrepoで`group_vars`や
`roles/agent_stack/templates/`を編集し、`make ansible-apply-agent`で反映する。`config.yaml`は毎回上書きされる
ため、VM上で直接編集しない。同じ内容・属性ならtemplate taskは`ok`となる。Hermesにも設定を保存する経路があり、
runtime側で変わった内容は次回applyで戻る。変更時のhandlerは`homelab-agent-compose-up`（`up -d --wait`）で、
bind内の内容変更だけでは再作成・再読込を保証しない。反映には必要に応じて上記の再起動手順を使う。
`SOUL.md`以降に蓄積するデータ（`USER.md`/`MEMORY.md`、sessions、ユーザーが追加したskills/cron）は
Ansibleが上書きしない（週次振り返りcronはAnsibleが冪等に登録する）。

Discordのchannel IDはsecret bundle（`hermes.env`）由来で、`config.yaml`のroutingとnotification channelへ
描画される。変更時はbundleを更新してからapplyする。

### モデルと推論の変更

- 推論endpointを変える場合は`group_vars/agent.yml`の`agent_stack_llm_base_url` / `agent_stack_llm_model`等を
  編集してapplyする。エンドポイントは1つだけなのでfallbackは設定しない。
- embeddingを変える場合は`agent_stack_embedding_*`のモデル名・revision・task prefix・入力上限を同時に更新する。
  embeddingはapply時にdownload-onlyコンテナで事前取得する。rerankerは上記ORT imageのexporterを変更し、
  一致検査を通したimageのdigestを転記する。候補数・token上限を変える場合はAnsible/Composeも合わせる。
  **embeddingの次元が変わる場合は既存のvector indexを再利用できない**ため、bankをエクスポートして
  空のDBへ再構築する（後述のprovider変更と同じ扱い）。
- embeddingのモデル取得だけはAdGuardがxet CDNをNXDOMAIN化するためresolver `1.1.1.1`と`HF_HUB_DISABLE_XET=1`を使う。
  AdGuardの設定は変更せず、TEIは固定local snapshotをHFオフラインで読む。取得helperの依存は
  `roles/agent_stack/files/model-fetch-requirements.txt`で全推移依存をhash固定し、`--require-hashes`で検査する。
  固定Python 3.13 Linux amd64向けなので、image/arch変更時は依存closureも再解決する。

### image更新

自前image（`homelab-hermes-agent` / `homelab-memory-db` / `homelab-tei-reranker-onnx`）は`.github/workflows/`がbuild・公開し、digestを
job summaryへ出力する。上流baseや同梱するHindsight統合revisionを更新するときは、Dockerfile更新 → workflow実行 →
digest転記を**別の変更**で行う。転記後は`make ansible-apply-agent`で反映する。digestを変えない限り
同じimageが使われる。

### secret更新

`files/infrastructure/secrets/agent/runtime.sops.yaml`を編集してapplyする。`make secrets-encrypt-agent`は既存bundleの上書きを拒否するため、
編集はtoolboxの`sops set`で行い、編集後に`chmod 0600`して`make secrets-decrypt-check-agent`で復号を確認する。
Agent VM側の値はrole `agent_stack`が`/etc/homelab/secrets/*.env`へroot 0600で配置する。値は`no_log`で扱い、
ログやcommitに残さない。

## 記憶の運用

- 2026-10-17のユーザー決定で`memory.write_approval: false`とし、組み込み`MEMORY.md`/`USER.md`への
  書き込みは即時反映する。無人実行で保留をレビューする手間を減らすためで、`skills.write_approval: true`は維持する。
  誤った組み込み記憶は`/memory`で確認・削除する。無人background_review由来のreplace/removeは上流の
  別ゲートによりfalseでも保留され、`/memory pending`から確認する。
  この承認ゲートはHindsightのretain/自動retainを止めない。Hindsight側はcustom抽出とSOULの方針で守り、
  誤記憶があれば元発話と照合してbank修復・再構築を判断する。
- 記憶はHindsightの固定bank `personal`に保存し、全Discordチャンネルで共有する。明示された事実と推測の
  区別はbankのmission/disposition、custom抽出、`SOUL.md`の方針で促す。LLMの出力をコードで保証するものではない。
  `retain_extraction_mode=custom` / `retain_custom_instructions`で本人の明示発話だけを個人の事実として抽出し、
  assistantの回答を本人の確認済み情報へ昇格させない。`observations_mission`は統合時の出典・不確実性の保持を促す。
  B1回答の再投入ではmission追加だけは誤名を保存し、custom抽出は0件にできたが、一般的な保証にはならない。
- 週次振り返りはHermes cron（`agent_stack_weekly_review_schedule`、既定で毎週月曜9時）からSkill
  `weekly-review`を実行し、結果を通知チャンネルへ配信する。変化が無い週は`[SILENT]`のみを出力する。
- 検索はPGroongaの全文検索とruri-v3のembedding/rerankを併用する。rerankはCPUで1クエリあたり
  入力長により数秒かかる。候補数はLOW 8 / MID 20 / HIGH 30、TEI client batchは32。
  MID 12への削減は採用しない。飲み物とかばんを一緒に尋ねると、かばんがprefilterで落ちることがある。
  単独の短い自然文で尋ねる回避は確認したが、SOULの分割指示だけでは1回目のF3再試験は失敗した
  （2回目はF群4/4正答）。2回目は推論threads・tokenization workersを絞り、batch request 1も指定して速度を
  改善した（診断rerank p50 7.03→4.03秒、20候補p50 9.00→4.24秒）。旧Candleで20候補のp50 3秒以内は未達で、
  2026-10-17のユーザー決定では品質を優先してMID 20 / HIGH 30を維持した。WS18は候補数を変えずORTで高速化する。
  WS13では6 CPUを超えてもほぼ伸びず、12 vCPU / 24 GiBの新配分の会話応答性は本番適用後に再計測する。
- rerankerの低い絶対値は、固定revisionをtransformersの分類head+sigmoidで照合して最大絶対差7e-7未満だった。
  モデル本来の分布として`agent_stack_recall_min_reranker_score: 0.0`を維持する。未知属性を拒否する閾値ではない。
- 年の無い発話をHermesが明示retain時に2025年へ補い、自動retainの2026年と矛盾させた事例がある。
  pluginはtimestamp/contextを渡すが、モデルの`occurred_at`指定や保存本文を訂正しない。SOULには年を補わず
  原文を保存する指示を加えた。小さな再試験で旧年は出なかったが、未共有の年は本人確認が必要。
- 誤回答の自動retainで、人名の誤り・別予定の日付・推測した変更理由がworld/observationへ伝播した。
  新設定は既存記憶を修復しない。週次振り返りでは本人の元発話と照合し、必要なら監査後に新bankで再構築・再受入する。
  `SOUL.md`は`force: false`なので、既存環境では差分を人がレビューして反映する。
- 「覚えないで」「消して」「何を覚えている？」の専用機能は用意しない。将来必要になった場合は、
  providerをラップせずbankの設定・Skill・cronで実現する方針とする（[ADR-0008](../adr/0008-hermes-agent-hindsight-vms.md)）。

## バックアップ・復元・エクスポート

バックアップ（日次・age暗号化・pve1 NFS）、本番/スクラッチリストア、エクスポート、記憶再構築、健康確認は
[別文書](hermes-agent-backup.md)を正とする。ここでは用途の違いだけ記す。

- **完全復旧（同じprovider内の障害復旧）**はbackup（`pg_dump -Fc`を含むセット）から戻す。
- **provider移行・監査**はexport（`export-bank` + provider非依存JSONL）を作り、別providerへ再投入する。
- **記憶の再構築**はHermesセッションJSONLを`homelab-agent-rebuild-memory`でHindsightへ再投入する。

運用helper（backup / restore / export / rebuild-memory / healthcheck）は2026-10-17のローカル結合試験
（WS7b-ops / WS7b-ops2 / WS7d、架空データ）で修正前の通し確認を行った。
WS8の安全コピー・通知・再開・bank方針の修正後は、ローカルfixtureで回帰検証した。確認済みの範囲と本番でしか確認できない項目は
[バックアップ文書の検証範囲](hermes-agent-backup.md#9-検証範囲2026-10-17)を正とする。rebuild-memoryの
再投入の形（1セッション=1document=1リクエスト、`User:`/`Assistant:`ラベルのJSON配列、`update_mode=replace`、
async完了待ち、per-turn timestamp）と使い方（進捗ディレクトリ、resume、`--fresh`、staged input）も
同文書の記憶の再構築節を正とする。

## provider変更の手順（移行と再構築）

embedding/rerankerまたは記憶providerを変更するときは、次を順に行う。手順は実装から導いたもので、
実機では未検証。現行のrebuild helperの投入先はHindsightのみであり、別providerには専用の投入処理が必要。

1. 変更前のexportを取得する（`homelab-agent-export`）。監査用に保持する。
2. 変更前DBを保全し、別の空DB/一時stackへ新モデルとその設定を用意する。次元変更を現行DBへ先に適用しない。
3. embeddingの次元が変わる場合は、空のDBを前提にbankを再構築する（新しいHindsight DBへセッションJSONLを
   `homelab-agent-rebuild-memory`で再投入する。別provider用の投入処理は別途用意する）。
4. 健康確認と、固定日本語クエリでのrecallを確認する（[健康確認節](hermes-agent-backup.md#6-健康確認)）。

## 静的に検証できること

実機へ接続せずに確認できるtargetは次のとおり。秘密を使わない静的検証はCI（`.github/workflows/validate.yml`）にも登録されている。

| 確認 | target |
| --- | --- |
| Terraform（Agent / Runner） | `make terraform-validate-agent-vm` / `make terraform-validate-runner-vm`、`make terraform-fmt` |
| Ansible（lint / syntax） | `make ansible-lint-agent` / `make ansible-check-agent` |
| Compose（合成envでの`config` + digest固定） | `make agent-compose-config` |
| VM cloud-init / lifecycle | `make agent-vm-cloud-init-test` / `make runner-vm-cloud-init-test` / `make terraform-agent-runner-vm-lifecycle-test` |
| Runnerの権限・egress | `make runner-privilege-fixture` / `make runner-firewall-fixture` |
| Agent/RunnerのTerraform scope | `make agent-runner-scope-fixture` |
| AgentのDNAT guard | `make agent-dnat-guard-fixture` |
| 運用script（backup / healthcheck / restore / rebuild） | `make agent-backup-fixture` / `make agent-healthcheck-fixture` / `make agent-restore-fixture` / `make agent-rebuild-fixture`（restore fixtureはcleanup・model-fetch・behaviorも呼ぶ） |


これらは静的検査と外部操作を置き換えたfixtureで、実機の挙動を保証しない。
ホストでfixtureを実行する場合はPython 3・PyYAMLに加え、helper描画用のJinja2が必要。
secret bundleの復号確認は別枠で`make secrets-decrypt-check-agent`（identityが必要）を使う。

## 既知の制約・未決事項

- 2026-10-18にAnsible適用、健康確認・backup・scratch restore済み。運用者の簡易確認では記憶・VM利用が可能だったが、Discord本受入、実RunnerのChromium sandboxのsystemd hardening検証、本番DRは未完了。
- 本番のHIGH 30候補rerankはp95 3.66秒で3秒目標を超過する。CPU/候補数の変更は未決。
- 初回起動時はDB準備待ちでHindsightが3回起動失敗し、restart policyで復帰した。
- Discordのbot token・channel、運用webhookはsecret bundleが正であり、repoには置かない。
- 推論エンドポイントには優先度機構が無い。背景処理の同時実行を1へ絞ることで会話への影響を抑えるが、
  会話ターンを構造的に優先させる仕組みは持たない。
- GLM endpointはOpenAI互換のstrict `json_schema`を受理することを2026-10-17に確認した。
  ローカル結合試験では実際の抽出・統合スキーマを処理できた。ただし初期consolidationで出力上限に当たり、
  reasoning effortと有限の出力上限を調整し救済した。無人で常に完走することや記憶の正確性までは保証しない。
- `memory.write_approval: false`、`skills.write_approval: true`は2026-10-17にユーザー決定済み。
  context_length・出力上限等のその他ユーザー確認項目は未決であり、決定後に設定とこの文書を更新する。
- AdGuardはHugging Faceのxet CDNをNXDOMAIN化する。回避はモデル事前取得コンテナのresolver変更だけで行い、
  AdGuard設定・TEI実行時の通信は変更しない。

## 手動反映の記録

反映時に記入する。個人ID、token、秘密鍵、host-key fingerprintはこの表に記録しない。

| 日付 | 操作者 | 反映内容 | 確認結果 |
| --- | --- | --- | --- |
| 2026-10-18 | 運用者 | Proxmox token `terraform@pve!agent-vm` / `terraform@pve!runner-vm`作成（`privsep=0`、有効期限2027-04-30 23:59:59 JST）。ユーザーACL `/vms/104`・`/vms/105`に`HomelabTerraform`、propagate 1を追加 | 既存`/vms/101`はpropagate 1、`/storage/local`・`/storage/vmpool`・`/nodes/pve1`・`/sdn/zones/localnetwork`・`/sdn/zones/localnetwork/vmbr0/10`はpropagate 0。3 tokenは同じユーザーACLを継承しVM別分離なし。`apps-vm` tokenの期限は2026-12-04のまま |
| 2026-10-18 | 運用者 | bpg/proxmox 0.116.1、保存planからAgent / Runnerをapply | 各`3 added, 0 changed, 0 destroyed`（`local:import/debian-13-genericcloud-amd64-{agent,runner}.qcow2`、cloud-init snippet、VM）。104: 12 vCPU / 24 GiB / vmpool 40 + 100 GB、105: 8 vCPU / 16 GiB / vmpool 40 + 150 GB。local stateは0600、age暗号化copyを`state-backup`へpush（`d5fdcc5` → `8074808`） |
| 2026-10-18 | 運用者 | pve1の`qm guest exec <vmid> -- cat /etc/ssh/ssh_host_ed25519_key.pub`でhost keyをout-of-band取得し管理端末の`known_hosts`へ登録 | 両VMでcloud-init done、データdiskのby-id一致、`StrictHostKeyChecking=yes`のdeploy接続と`sudo -n true`成功 |
| 2026-10-18 | 運用者 | pve1に`tank-gen2/data/agent-backups`、`/etc/exports`のAgent `/32`限定export、markerを作成 | `exportfs -ra`後の`exportfs -v`を確認。`/etc/exports` SHA-256: `5639f51953049d980b62faa7745546f9a6364e8eaeb8ffebe306327369f118fe`。この時点ではAgent側mountは未検証 |
| 2026-10-18 16:49–16:58 JST | 運用者 | main `8e4bbbc`から初回`make ansible-apply-agent` | agent-vm ok=93 changed=58、runner-vm ok=54 changed=35、failed=0。6サービス起動、embedding/reranker/memory-db/hindsight healthy、`/srv/agent` ext4・`/mnt/agent-backups` nfs4。17:00健康確認all checks passed（gateway・Discord connected・Runner含む）。HindsightはDB準備待ちで3回失敗後restart policyで復帰 |
| 2026-10-18 17:06 JST以降 | 運用者 | 初回手動backup失敗をPR #106で修正（Runner tarの`./lost+found`除外、`sops set`でwebhookを数値IDからURLへ修正） | webhookのGETはVMから200。URL・IDは記録しない |
| 2026-10-18 約17:27 JST | 運用者 | main `f12d054`から2回目`make ansible-apply-agent` | agent-vm ok=80 changed=10、runner-vm ok=46 changed=2。PGDATAとmount rootの属性を再設定する不具合が判明 |
| 2026-10-18 約17:27–17:30 JST | 運用者 | `/srv/agent/postgres`がroot:root 0700へ戻り、運用者が`chown 999:999 /srv/agent/postgres`で復旧 | 新規DB接続は`global/pg_filenode.map` Permission denied（08:27:49–08:29:49 UTCに20件）、pg_dump失敗。既存pool接続は継続、Hindsight operations completed=20 / failed=0 / pending=0、記憶損失なし。復旧後健康確認成功。WS26で再適用時の所有権競合とmount root属性変更を修正（本番再適用は未実施） |
| 2026-10-18 17:30 JST | 運用者 | 手動backup set `20261018T083023Z`作成 | Hermes約24 MB、PostgreSQL約120 KB、agent-config、runner-workをage暗号化。`sha256sum -c SHA256SUMS`全件OK。`hindsight_version=unknown`は軽微な残件 |
| 2026-10-18 17:30 JST | 運用者 | `homelab-agent-restore 20261018T083023Z --identity <tmpfs file> --scratch` | total_nodes=5、recall 5 results、Hermes archive 667 entries、state.db integrity_check ok（2 DB）。scratch project削除、本番無変更。復旧identityはSSH stdinから`/run` tmpfsへ0600で一時配置し、EXIT trapでshred、終了後不在を確認 |
