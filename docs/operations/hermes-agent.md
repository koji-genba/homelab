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
  実体は`tensorfold serve`）を共用する。fallback providerは無い。画像入力も同じDGXへ送る
  （2026-10-18に画像を送って動作を確認）。
- Agent stackは`files/services/compose/`の外にあるため、Apps VMの15分reconcile・起動helper・digest gate・
  `scripts/compose-config.sh`の対象にならない。変更は`make ansible-apply-agent`で人が反映する。
- 両VMとも`192.168.10.0/24`（Server VLAN）にあり、IPはTerraform変数と`group_vars/{agent,runner}.yml`が正。
  宅外からは既存gatewayのsubnet route（`192.168.10.0/24`）で到達する。Tailscale ACLは変更しない。

### 外部へ出る経路

Discordへの応答・添付、SearXNG経由のWeb検索（検索語は公開エンジンへ渡る）、MCPの`web_url_read`（ページ本文の取得）、
Runnerの閲覧・コマンド、監視通知・任意のdead-man通知は意図した外部通信として残す。
モデルカタログ等の定期取得、tirith、必要な依存のlazy install（TTS以外）も維持する。
TTS・STT・画像生成は使わず、組み込み`web_extract`は検索専用の`searxng`を指定して抽出を失敗させ、外部SaaSへ切り替えない。
TTSはツール非公開に加え、command型providerを`/bin/false`へ向けて保存済みvoice modeでも送信を防ぐ。
`voice.auto_tts: false`も明示する。command型providerはEdgeの利用可否チェックを通らないため、Edgeのlazy installも起きない。
画像添付は`image_input_mode: native`でmainのGLMへ直接渡し、`vision_analyze`用の`auxiliary.vision`もDGXへ固定する。
shared metricsの収集・送信、skill sync、Nous guest、connectors、外部monitoring exportは明示的に無効にする。
最初のメッセージでのプロフィール作り（同意後に`web_search`で本人の公開情報を調べる流れ）は`onboarding.profile_build: "off"`で止める。
Hermesは一度きりの案内を出すと`config.yaml`の`onboarding.seen`へ印を書き込み、次のapplyで描画し直されて差分になるため、Gatewayの印は最初からseenにしておく。
これは機能設定による制限であり、Agent全体のnetwork egress遮断ではない。

[Hermes 共有](hermes-share.md)（2026-11-05反映・共有利用を確認済み）は Runner に NFS の内容を直接見せる。
置かれたファイルはコマンドの公開インターネット通信や Agent の MEDIA 配送で外へ出得る。
共有への配置はアップロードの許可ではない。skill は外部サービスへの送信を禁じるが、強制境界ではない。
唯一のコピーや機密は置かない。Runner の LAN 遮断には pve1:2049/tcp の例外が一つ加わる
（[ADR-0014](../adr/0014-hermes-share-nfs.md)）。先に ai export を3 clientの `/32` へ絞る。

コーディングCLIの追加では、DGX `.51:8000/tcp` をさらに例外とし、Claude Code/Codexによる
承認済みrepoの非機密コードの外部推論送信を認める（[ADR-0015](../adr/0015-hermes-coding-agents.md)、
実機は未検証）。資格情報の明示的読み取り・送信や任意のファイルuploadはこの許可に含めない。

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
   VMID 104 / 105 と `192.168.10.104` / `.105` が空いていることを確認し、全6 Proxmox root共通の
   API token `terraform@pve!terraform`（`privsep=0`）と、`/vms/104`・`/vms/105`および
   image importに必要なdatastore権限のACLを用意する。`terraform-*`のrootは重複確認のためのpingを行わない。
   対象datastore `local`のcontent typeに`Import`と`snippets`が含まれることを確認する。
   最初のAnsible接続前に、Proxmox console等のout-of-band経路で各VMのSSH host-key fingerprintを確認し、
   管理端末の`known_hosts`へ追加する。詳細は各rootのREADMEを正とする。
   実測: tokenとユーザーACLを追加済み。`privsep=0`の3 tokenは同じユーザーACLを継承し、VM別には分離されない。host keyは手順3のout-of-band経路で登録した。
   2026-10-25に共通tokenへ移行済み。確認結果と旧token削除は[実施記録](apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)を参照する。
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
   user/channel ID、運用通知webhook、任意のdead-man ping URLを用意する。Webapp用の3キーは
   下記「Webapp 認証キーの登録」のexampleと手順に従う。PostgreSQL passwordとSSH鍵は
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
   実測: 16:49–16:58に初回適用（failed=0）、6サービス起動、ext4/nfs4 mount、17:00健康確認成功。約17:27の再適用でPGDATA所有権障害が発生し、運用者が復旧した。その後PR #107・#108の修正と一度限りの調整を経て、6回目はagent-vm / runner-vmともchanged=0、PGDATA 999:999 0700・export root 0700を維持し、健康確認all checks passed（末尾の記録参照）。
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

Hermesの設定を再読込する場合は、同じ引数で末尾を
`up -d --no-deps --force-recreate --wait --wait-timeout 600 hermes cdp-tunnel`にする
（実行中の会話に影響するため保守時に行う）。待機上限を変更している場合は600をその値に合わせる。

長命サービスは`restart: unless-stopped`のため、VM再起動後は自動で復帰する。operatorが`stop`した
サービスは停止のままになる。

### 設定変更

Hermesの`config.yaml`、`SOUL.md`（初回のみ`force: false`）、Hindsight `config.json`、bank policyは
role `agent_stack`がテンプレートから描画する。週次振り返りcronは同名ジョブが無い場合だけ登録する。
変更はrepoで`group_vars`や
`roles/agent_stack/templates/`を編集し、`make ansible-apply-agent`で反映する。`config.yaml`は毎回上書きされる
ため、VM上で直接編集しない。同じ内容・属性ならtemplate taskは`ok`となる。Hermesにも設定を保存する経路があり、
runtime側で変わった内容は次回applyで戻る。Webappの設定画面でcontext等を変更しても、次の
`make ansible-apply-agent`で上書きされる。「コンテキストウィンドウ」に0（自動検出）を保存しても、
上流の不具合で既存値が復活して元の値に戻る（2026-11-05確認）。DGXの`/v1/models`は長さを返さないため、
自動検出には頼れない。`config.yaml` / `hindsight/config.json`の変更時はhandler
`Recreate Hermes and the CDP tunnel`が`up -d --no-deps --force-recreate --wait`で両サービスを再作成する。
Hermesのimageは起動のたびに`config.yaml`を`chmod 640`するため、Ansibleも0640で置く（0600だと再起動のたびに差分になる）。待機上限は起動helperと同じ`agent_stack_compose_wait_timeout`（既定600秒）。`cdp-tunnel`はHermesの
network namespaceを共有するため、必ず一緒に再作成する。SSH鍵の生成・Runnerのknown_hostsの変更と、
`SOUL.md` / 同梱skillsの不足分をseedした場合も同じhandlerへ通知する。SSHは新規接続時に鍵とknown_hostsを
読むが、CDP tunnelは認証済み接続を保持するため、変更時に接続を張り直す。
Compose定義・非secret環境の変更用handler `Restart the Agent stack`（通常の`up -d --wait`）は先に実行する。
両方が通知されるとHermesが二度再作成される場合があるが、bind先の永続データ・SSH鍵は保持する。
再作成は実行中の会話に影響するため、設定変更のapplyは保守時に行う。同じ内容・属性なら再作成は通知されない。
Hindsight本体は設定ファイルをbind mountせず、環境変数の変更は通常の`up`で反映する。embeddingのbind mountは
revision固定のモデルcacheで、モデル変更はComposeの引数へ反映される。rerankerのモデルはimage同梱である。
`SOUL.md`以降に蓄積するデータ（`USER.md`/`MEMORY.md`、sessions、ユーザーが追加したskills/cron）は
Ansibleが上書きしない。同梱skillsも`force: false`で初回のみ配置されるため、既存ファイルの変更は
`make ansible-apply-agent`だけでは反映されない。週次振り返りの更新手順は「記憶の運用」を参照する。

Discordのchannel IDはsecret bundle（`hermes.env`）由来で、`config.yaml`のroutingとnotification channelへ
描画される。変更時はbundleを更新してからapplyする。

Discordのスラッシュコマンドは、Hermesが起動時に登録する。既定の`safe`方式は約100個を4.5秒間隔で1つずつ作るため、
2026-10-18〜19は毎回600秒の上限で打ち切られて同期が一度も完了せず、`/new`などが使えなかった。Composeで
`DISCORD_COMMAND_SYNC_POLICY: bulk`を指定し、起動のたびに1回の要求でまとめて置き換える。登録後もDiscordの
クライアントに出ないときは、クライアントを再読み込みする（PCはCtrl+R）。

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

Runnerで作ったファイルは、最終返答に`MEDIA:/srv/agent-work/x.png`のように書くとDiscordへ添付される。
上流のリモートMEDIA取得処理はhandler終了後にsession keyを失うため、自前imageの
`patches/0001-remote-media-session-key.patch`で配信時のsession keyを渡す。上流で修正されたimageへ
更新したら、このpatchとDockerfileの適用処理を外す。

自前image（`homelab-hermes-agent` / `homelab-memory-db` / `homelab-tei-reranker-onnx`）は`.github/workflows/`がbuild・公開し、digestを
job summaryへ出力する。上流baseや同梱するHindsight統合revisionを更新するときは、Dockerfile更新 → workflow実行 →
digest転記を**別の変更**で行う。転記後は`make ansible-apply-agent`で反映する。digestを変えない限り
同じimageが使われる。

### secret更新

`files/infrastructure/secrets/agent/runtime.sops.yaml`を編集してapplyする。`make secrets-encrypt-agent`は既存bundleの上書きを拒否するため、
編集はtoolboxの`sops set`で行い、編集後に`chmod 0600`して`make secrets-decrypt-check-agent`で復号を確認する。
Agent VM側の値はrole `agent_stack`が`/etc/homelab/secrets/*.env`へroot 0600で配置する。値は`no_log`で扱い、
ログやcommitに残さない。

## 上流 main / Webapp への更新

上流 `c7da41dd522dc19cc08bbfcfa69d4b078224b45d` への更新と Webapp 公開は、2026-11-02 JST に本番反映済み
（PR #179・#181・#182・#180）。確認済みの範囲と残る未検証事項は、下記「本番反映・確認結果」に記す。
採用理由と公開境界は [ADR-0013](../adr/0013-hermes-webapp-caddy.md) を参照。

- URL は `https://hermes.kojigenba-srv.com`。Apps VM Caddy が TLS を終端し、Agent の
  `192.168.10.104:9120` へ HTTP / WebSocket を中継する。Agent は tailnet 外を維持する。
- Caddy は `admin_networks` で接続元を制限し、Hermes 同梱の basic provider がフォームログインを提供する。
  Caddy の Basic Auth は重ねない。Apps の Caddy・AdGuard・Homepage・Gatus は PR #180 で反映済み。
- `dashboard.basic_auth.session_ttl_seconds` は 43200（12時間）。これは access token の更新間隔であり、
  12時間で必ず再ログインする設定ではない。上流 basic provider の refresh token は30日。
- `state.db` の schema は旧版の30から32へ進む。旧イメージへの差し戻しだけをロールバックにしない。
  更新前の Hermes データ・DB・設定・SSH identity を含む一式と、対応する旧イメージ・設定の組で復元する。
  [バックアップ・復元手順](hermes-agent-backup.md)に従う。
- ブラウザは従来の tool 群から `browser_exec` 中心へ変わる。廃止された `browser.backend` を削除し、
  Runner Chromium への `cdp_url` と同一 netns の cdp-tunnel を維持する。既存の操作手順・Skill は動作確認する。
- config は schema 52。sessions の自動 prune、Desktop onboarding、lazy install を明示的に停止する。
  上流 `hermes_cli/config_migrations.py` の v47（旧 compression 閾値）、v48（旧 sandbox image）、
  v49（旧 Vercel runtime）、v50（tirith）、v51（旧 cron timeout）はテンプレートに対象キーがない。
  v52（`config_migrations_browser.py`）の `browser.backend` / `extension_control` も持ち込まない。
  `scripts/docker_config_migrate.py` は stamp が現行52以上なら migration 前に return し、
  この起動時 migration による config 書き換えは発生しない（ソース確認）。UI の設定保存や Always Allow、
  複数 profile 時の multiplex 自動確定等による別の書き換えまでは防がない。管理項目は Ansible で変更する。

### terminal の扱い

選定ソースには Webapp の手動 terminal を設定だけで停止する項目がない。
`hermes_cli/web_server_surface.py` の Webapp policy は `host_terminal=True`、
`web_host_terminal.request_allowed()` は認証あり、または loopback なら許可し、
`web_host_terminal_sessions.py` が gateway の子 PTY を生成する。
これは Agent tool の `terminal.backend: ssh` と別で、Hermes コンテナ内で shell が動く。
ブラウザからの手動 terminal は、Apps 側 Caddy で遮断する。
9120 は nftables で Apps VM からの到達に限定するため、ブラウザからの経路は Caddy の1か所で遮断できる。
Apps VM 自身から backend へ直接接続する経路は残るが、Hermes の認証が必要になる。

Apps 側 Caddy では **`/api/host-terminal` とその配下（`/api/host-terminal/*`）**を、
WebSocket upgrade を含めて403で拒否する。クエリ付きも同じ path として遮断する。
`/api/ws`（会話・セッション）、`/api/webapp/socket-ticket`（会話や音声でも共用）、
`/api/files/*` や `/api/chat/file-upload` は遮断しない。チケット発行 API 全体を塞ぐ必要はない。
将来、Caddy を経由しない利用も止める場合の patch 箇所は
`hermes_cli/web_host_terminal.py` の `request_allowed()`（常に false を返す）、または
`hermes_cli/web_routers/webapp.py` の `host_terminal_ws()`（accept 前に4403で閉じる）。
Caddy の遮断は PR #180 で反映済み。上流 patch は将来の選択肢として残し、今回は適用しない。
UI の terminal pane 自体は残るが、Caddy 経由では接続できなくなる。

### 9120 の到達元と trusted_proxies

Agent の nftables は input と Docker DNAT の forward の両方で `.101/32` 以外の9120を drop する。
input では loopback を先に許可するため、ホスト内の loopback 通信は遮断しない。
forward は `ct original proto-dst` で公開ポートを照合し、広い trusted 範囲や established 許可より前に判定する。
返りのパケットにも当たるため、送信元はコンテナの IP ではなく接続開始時の `ct original ip saddr` で判定する。
Runner `.105`、他の LAN 機器、Trusted VLAN、tailnet からの直接接続は許可しない。
cdp-tunnel は Hermes と netns を共有するが、CDP の host 公開は追加しない。

Agent が再利用する Apps の Docker role の `daemon.json.j2` はログ設定だけで、
`userland-proxy` は明示しない。通常のリモート LAN→公開 bridge ポートは DNAT される。
`dashboard.trusted_proxies` は **`192.168.10.101/32` のみ**にする。bridge gateway や広い CIDR は信頼しない。
2026-11-02 JST、Caddy 越しのログインが成功し `__Host-` cookie が使えたことから、
`.101` の trusted proxy 設定で HTTPS の転送ヘッダーが信頼され、Hermes から見た接続元は Apps の LAN IP のままと判断できる。
これはログイン成功を根拠とした判断であり、HTTP peer の直接観測ではない。
Apps VM からの `/api/status` 成功と、作業端末（Trusted VLAN）から9120へ届かないことも同日確認済み。

### Webapp 認証キーの登録（運用者の端末で実施）

既存 bundle の Discord / monitoring に、次の文字列キーを追加する。
bundle の example は `files/infrastructure/secrets/agent/runtime.yaml.example` を参照する。

| bundle キー | Hermes env |
| --- | --- |
| `dashboard_basic_auth.username` | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` |
| `dashboard_basic_auth.password_hash` | `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` |
| `dashboard_basic_auth.secret` | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` |

既存の必須キー検査と同じく、欠落・空・文字列以外・改行入りは apply を停止する。
password_hash の scrypt 形式と secret の形式も検査する。Webapp を黙って無効化して進めない。
復号・検査・root 0600 の `hermes.env` 描画は `no_log`、Compose は `format: raw` で `$` をそのまま渡す。

上流の公開関数 `plugins.dashboard_auth.basic.hash_password()` の形式は
`scrypt$n$r$p$<salt_base64>$<derived_key_base64>`。
選定版は n=16384、r=8、p=1、salt=16 bytes、derived key=32 bytes。
独立した hash 生成 CLI は見つからない。`hermes dashboard` の対話設定は getpass で入力し config を保存するため、
Ansible 管理 config には使わず、以下では同じ stdlib scrypt 処理で JSON 文字列を作って SOPS へ直接渡す。

次は **Bash の対話端末**で repo ルートから実行する手順。Docker と既存の age identity を用意し、
`AGE_IDENTITY_FILE` は既存の運用手順に従って設定する。値の表示・平文ファイルへの保存はしない。
SOPS の pin は `set --value-stdin` を持たないため、コンテナ内の Python が stdin を読み `sops set` を呼ぶ。
パスワードは stdin、ハッシュ・secret の JSON はコンテナ内の sops プロセスの引数にのみ渡る。
`HOME` / `USER` / `LOGNAME` は toolbox の任意 UID 実行のため必須。

```bash
(
  set -euo pipefail
  set +x
  : "${AGE_IDENTITY_FILE:?既存の age identity のパスを設定する}"
  TOOLBOX_IMAGE=$(awk '
    /^TOOLBOX_IMAGE_REPO \?=/ {repo=$3}
    /^TOOLBOX_IMAGE_DIGEST \?=/ {digest=$3}
    END {print repo "@" digest}' Makefile)

  agent_json() {
    docker run --rm --memory 6g --network none -i \
      --user "$(id -u):$(id -g)" \
      -e HOME=/tmp/homelab-toolbox -e USER=homelab-toolbox -e LOGNAME=homelab-toolbox \
      "$TOOLBOX_IMAGE" python3 -c "$1"
  }
  agent_sops_set() {
    docker run --rm --memory 6g --network none -i \
      --user "$(id -u):$(id -g)" -v "$PWD:/workspace" -w /workspace \
      -v "$AGE_IDENTITY_FILE:/run/secrets/age-identity:ro" \
      -e SOPS_AGE_KEY_FILE=/run/secrets/age-identity \
      -e HOME=/tmp/homelab-toolbox -e USER=homelab-toolbox -e LOGNAME=homelab-toolbox \
      "$TOOLBOX_IMAGE" python3 -c '
import subprocess, sys
raise SystemExit(subprocess.call(["sops", "set", sys.argv[1], sys.argv[2], sys.stdin.read()]))
' files/infrastructure/secrets/agent/runtime.sops.yaml "$1"
  }

  IFS= read -r -p 'Webapp username: ' webapp_username
  test -n "$webapp_username"
  printf '%s' "$webapp_username" |
    agent_json 'import json,sys; print(json.dumps(sys.stdin.read()))' |
    agent_sops_set '["dashboard_basic_auth"]["username"]'
  IFS= read -rs -p 'Webapp password: ' webapp_password
  printf '\n' >&2
  IFS= read -rs -p 'Confirm password: ' webapp_confirm
  printf '\n' >&2
  if [[ -z "$webapp_password" || "$webapp_password" != "$webapp_confirm" ]]; then
    printf '%s\n' 'パスワードが空、または確認入力が一致しません。' >&2
    exit 1
  fi
  printf '%s' "$webapp_password" | agent_json '
import base64, hashlib, json, secrets, sys
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(sys.stdin.read().encode("utf-8"), salt=salt, n=16384, r=8, p=1, dklen=32, maxmem=0)
print(json.dumps("scrypt$16384$8$1$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(dk).decode()))
' | agent_sops_set '["dashboard_basic_auth"]["password_hash"]'
  unset webapp_password webapp_confirm webapp_username
  agent_json 'import json,secrets; print(json.dumps(secrets.token_hex(32)))' </dev/null |
    agent_sops_set '["dashboard_basic_auth"]["secret"]'
  chmod 0600 files/infrastructure/secrets/agent/runtime.sops.yaml
)
make secrets-decrypt-check-agent
```

この手順は生成値を画面や shell 履歴へ出さない。共有端末ではプロセス引数の参照権限にも注意する。
署名 secret の再生成は既存セッションを無効化するため、通常の apply ごとには行わない。

### 反映と確認（明示承認を得て別途実施）

1. Compose の Hermes と cdp-tunnel が公開済みの新しい自前イメージへ固定されていることを確認し、上記キー登録とローカル検査を終える。
   Apps 側 PR の Caddy/DNS 等を揃える。旧イメージ・旧設定の復元先も記録する。
2. 更新前に[バックアップ手順](hermes-agent-backup.md)の整合した一式を取得し、復元に必要な artifact が揃っていることを確認する。
3. `make ansible-apply-agent` で反映する。Hermes と netns を共有する cdp-tunnel の再作成を確認する。
4. Apps から9120への接続成功、Runner・他 LAN 端末からの拒否を確認する。上記の peer 確認と、
   Webapp の未ログイン時拒否、ログイン・ログアウト、会話・セッション再開、ファイル upload/download、
   WebSocket、既存 Discord thread、Runner SSH・CDP、Hindsight の recall/retain を確認する。
   Caddy 経由の `/api/host-terminal` とその配下が、クエリ付き・WebSocket upgrade を含め403になることを確認する。
   terminal の遮断後も会話・セッション・ファイルなど他の機能が動くことを確認する。
5. 起動時 migration が config を書き換えていないことを確認後、2回目の `make ansible-apply-agent` で **changed=0** を確認する。
   Webapp の設定画面で Ansible 管理項目を変更しない。失敗時は更新前バックアップから復元する。

### ローカル結合試験の結果（2026-11-02）

以下は本番反映前のローカル試験記録である。本番での確認結果は次節に記す。
新イメージ、この PR の config テンプレート、Apps 側 PR の Caddy を組み合わせた隔離コンテナ試験で、次を確認した。
試験用の proxy IP・ダミー認証情報と内部 CA を使い、Hermes/Caddy はそれぞれメモリ6GiBで実行した。

- config.yaml は描画直後、Webapp 応答後、ログイン/API 後、会話後、再起動1回目後・2回目後の6段階すべてで内容が一致した。
  起動時 migration による書き換えは観測されなかった。Ansible の changed=0 を確認した結果ではない。
- gateway 起動、basic ログイン成功・誤パスワード拒否、未ログインの sessions API の401、ログイン後の API・SPA 配信を確認した。
  発行された4種の cookie は `__Host-` prefix と `Secure; HttpOnly; Path=/; SameSite=lax` を持ち、
  試験用 proxy の /32 から HTTPS forwarded 情報が信頼された。再起動2回後も既存 cookie で sessions API は200だった。
- Caddy 経由の会話 WebSocket は101で接続でき、`gateway.ready` と `gateway.ping` の応答を確認した。
  `/api/host-terminal` の通常 GET・正規チケット付き WebSocket は403で、クエリ・大小文字・重複 slash・
  percent encoding 等の候補も403だった。配下 `/api/host-terminal/sub` の GET も403（同 path の WebSocket は未検証）。
- DGX との会話は CLI で1往復し、指定した短い応答を得た。Webapp の WebSocket 上での実会話送信は未検証。
  DGX 中継が SSE をバッファするため、逐次ストリーミング遅延も未検証。
- 実際の sessions export を rebuild の `iter_sessions → build_turns → build_item` へ通し、
  1 session / 1 turn / 2 messages の replace 用 item を構築できた。
  非 active・非 compacted 行は除外し、compacted 行は保持することも確認した。実 Hindsight への再投入は行っていない。
  Hindsight の即時接続拒否でも会話は継続したが、正常な recall/retain や120秒の無応答 timeout は未検証。

### 本番反映・確認結果（2026-11-02 JST）

以下は運用者・利用者が本番で確認した結果（PR #179・#181・#182・#180）。

- **更新前バックアップ: 確認済み。** 07:04、旧版のまま `homelab-agent-backup` で更新前のバックアップセットを取得し、成功した。
- **新イメージ起動・冪等性: 確認済み。** `make ansible-apply-agent` の1回目は agent changed=9、
  2回目は agent・runner とも changed=0。Hermes は `c7da41dd` の新イメージで起動し、healthcheck は成功。
  メモリ使用量は約288MiB / 1.5GiBだった。
- **9120 の到達性と修正: 確認済み。** 反映直後は Apps VM から9120がタイムアウトした。
  forward の Webapp ルールが `ip saddr` で判定し、DNAT の返りのパケットまで落としていたため、
  PR #182 で `ct original ip saddr` に修正した。apply は changed=2、2回目は changed=0で、Hermes は再作成されなかった。
  修正後は Apps VM から `/api/status` が `overall: ok` を返し、作業端末（Trusted VLAN）から9120へは届かなかった。
- **Apps 側反映: 確認済み。** PR #180 のマージ後、reconcile を手動起動し、`edge`・`homepage`・`monitoring` が再作成された。
  AdGuard rewrite の `make ansible-apply` は changed=4で、Apps の全 project が再作成された。
- **tailnet からの公開経路・認証境界: 確認済み。** 名前は Apps の tailnet IP に解決され、`/login` は200、`/` は302、
  `/api/host-terminal` は403、未ログインの `/api/sessions` は401だった。Gatus の Hermes Webapp 監視も成功した。
- **ブラウザでの利用: 確認済み。** 利用者が Webapp にログインし、会話できた。
  Caddy 越しのログインが成功し `__Host-` cookie が使えたことから、`dashboard.trusted_proxies` の `.101` で
  HTTPS の転送ヘッダーが信頼されている（Hermes から見た接続元が Apps の LAN IP のまま）と判断できる。
- **Discord での利用: 確認済み。** 利用者が記憶の recall、`browser_exec` による Runner Chromium の操作
  （サイトのボット確認画面に当たるところまで）、Runner からの画像配送（MEDIA）、既登録スラッシュコマンドの表示を確認した。
  新版の最初の起動（07:07）では、スラッシュコマンド同期が rate limit によりタイムアウトした。
  同期は次の再接続で再試行する。既登録コマンドの表示を、同期成功とは扱わない。

**未検証:** Webapp でのファイル upload/download、UI での会話の継続・undo・compaction、
更新前バックアップからの復元による旧版への切り戻し、正常な Hindsight での120秒の timeout。
上記の確認済み範囲を超える受入完了とは扱わない。

既知の警告として `TERMINAL_CWD does not exist: /srv/agent-work` がある。
Hermes の `agent/runtime_cwd.py` が Runner 側のパスをコンテナ内の `Path.is_dir()` で検査するために出るもので、
Runner の疎通失敗を直接示すものではない。運用者の確認では旧版本番にも出ており、Webapp 接続中は約2秒ごとに出る。
ローカル結合試験では認証・会話を阻害しなかった。

## 記憶の運用

- 2026-10-17のユーザー決定で`memory.write_approval: false`とし、組み込み`MEMORY.md`/`USER.md`への
  書き込みは即時反映する。無人実行で保留をレビューする手間を減らすためで、`skills.write_approval: true`は維持する。
  誤った組み込み記憶は`/memory`で確認・削除する。無人background_review由来のreplace/removeは上流の
  別ゲートによりfalseでも保留され、`/memory pending`から確認する。
  この承認ゲートはHindsightのretain/自動retainを止めない。Hindsight側はcustom抽出とSOULの方針で守り、
  誤記憶があれば元発話と照合してbank修復・再構築を判断する。
- 2026-10-25: コマンド承認を`approvals.mode: smart`へ変更し、ローカルGLM guard（thinking off）で一次判定する。
  manualでは無害な`python -c`・heredoc・`bash -lc`や全`execute_code`も承認対象となり、
  2026-10-19〜2026-10-25にDiscord承認ボタンが33回押された。thinking offは判定が約0.5秒と速く、運用者の出力上限なしの直接リプレイでは
  thinking onは1.5〜9秒かかり、offでESCALATEとなる`curl | bash`をAPPROVEし、SSH鍵POSTもDENYではなく
  ESCALATEとしたためoffにする。上流guardは16 tokensを指定するが、pinned imageのcustom経路は
  `max_tokens`を送信しないため、本番で16 tokensを推論に使い切ることが理由ではない。
  明確に安全な操作は通し、危険な操作は拒否する。認証情報・Hermes状態の読み取り/送信、ローカルデータの外部送信、
  インターネットから取得したコードの実行は`smart_policy`で人へ回す方針とし、不確実・失敗時もDiscordで確認する。
  この方針は上流detectorがフラグを立てたコマンドに対するもので、全コマンドの検査を保証しない。cron・無人実行は自動承認しない。
  上流detectorが検出しない操作（`curl -d "$(cat ...)"`でのSSH鍵POST、`cat ~/.hermes/.env`、tarからuploadへのpipe等）は
  manualでも承認へ届かず、modeや`smart_policy`では保護されないため、その保護はRunnerの隔離（非rootユーザー・LAN遮断）とRunnerに何を置くかに依存する。
  Discordの「Always Allow」は使わない。危険カテゴリ全体を`config.yaml`へ保存するため、次回Ansible applyで
  差し戻され、applyの冪等性も崩れる。永続的な例外はテンプレートへ記述する。
- 記憶はHindsightの固定bank `personal`に保存し、全Discordチャンネルで共有する。明示された事実と推測の
  区別はbankのmission/disposition、custom抽出、`SOUL.md`の方針で促す。LLMの出力をコードで保証するものではない。
  `retain_extraction_mode=custom` / `retain_custom_instructions`で本人の明示発話だけを個人の事実として抽出し、
  assistantの回答を本人の確認済み情報へ昇格させない。`observations_mission`は統合時の出典・不確実性の保持を促す。
  B1回答の再投入ではmission追加だけは誤名を保存し、custom抽出は0件にできたが、一般的な保証にはならない。
- 週次振り返りはHermes cron（`agent_stack_weekly_review_schedule`、既定で毎週月曜9時）からSkill
  `weekly-review`を実行し、結果を通知チャンネルへ配信する。前日までの7日間（Asia/Tokyo）について
  `hindsight_recall`を4観点で各1回、必要なら根拠確認を追加1回行い、Hermes自身が統合する。
  queryには具体的な開始日・終了日を書くが、厳密な期間フィルタではない。Hindsight 1.1.0の
  日付解析では範囲の片方だけを検出する場合もあるため、返った記憶の日付を本文で照合する。
  既定の取得量は1回4096 tokensで、全記憶やmental modelを網羅するものではない。
  変化が無い週は`[SILENT]`のみを出力する。
  2026-11-04の判断でreflectから切り替えた。10/19・10/26・11/02の3週ともreflectは
  各2回が120秒で失敗した。11/04の直接測定でもHindsightのwall timeout 300秒で504となり、
  内部LLM呼び出し7回すべてが各30秒で打ち切られた。この構成ではreflectが完了しないため、
  LLMの高速化やtimeout変更は行わずrecallを使う。
- 既存環境の`weekly-review`更新手順（**未検証**）:
  repoの`files/services/agent/hermes/skills/weekly-review/SKILL.md`と
  VMの`/srv/agent/hermes/skills/weekly-review/SKILL.md`のsha256を比較し、稼働側に独自変更が
  あれば差分をレビューする。保守作業として承認を得て、この1ファイルをrepo版で置き換え、
  所有者・グループは`agent_stack_uid` / `agent_stack_gid`、modeは0644を維持し、sha256を再確認する。
  `force: false`は変更しない。`pending/skills/`に対象skillの保留変更があれば、古い指示へ
  戻さないよう承認前にレビューする。`skills.write_approval: true`ではHermesからのskill変更は
  保留され、cron自体はbackground reviewを起動しない。
  cronは実行時にskill本文を読み込むため、skill更新だけならジョブ再登録やコンテナ再作成は不要。
  skill一覧には30秒のcacheがあるが、本文をジョブへ固定保存する仕組みではない。
  現在のcron promptと`skills: [weekly-review]`はreflectを指定しておらず、変更は不要。
  将来promptやskill名を変える場合は、同名ジョブをapplyで更新できないため、Hermes cronの
  編集機能で既存ジョブを別途更新する（この手順も未検証）。
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
[バックアップ文書の検証範囲](hermes-agent-backup.md#9-検証範囲2026-10-18更新)を正とする。rebuild-memoryの
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
  2026-10-25のコマンド承認は`smart`（GLM guard、thinking off）へ変更。方針・Always Allow禁止は「記憶の運用」を参照。
- 2026-11-05に`context_length: 1048576`、圧縮開始`262144`トークン、要約は`reasoning_effort: high`・出力上限`32768`と決定した。
  サーバーの実際の窓を伝え、1ターンの作業量は26〜28万トークンの実績がある範囲で圧縮の閾値により絞る。
  要約は指定なし（サーバー既定、maxとみられる）でthinkingを含む出力合計が21,127トークンとなり、継承した上限`16384`で`finish_reason=length`になっていた。
  highは出力合計7,432トークン・189秒で、指定なしの487秒とほぼ同等の詳しさだったため、highに下げて要約専用の出力枠に余裕を持たせる。
  比較は1会話で各設定1回ずつ、キャッシュなしで実施し、thinking off（118秒・出力合計4,050トークン）は詳細が欠けた。
  DGX側の文書（edgexpert-ai-stack）もGLM-5.3-Flashのthinking offは品質が落ちるとして勧めず、強さは`reasoning_effort`で調整する方針としている。
  会話の出力上限`16384`は据え置く。本番反映は未実施で、highの要約が本番でtruncateしなくなるかは未検証。
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
| 2026-10-18 約17:27–17:30 JST | 運用者 | `/srv/agent/postgres`がroot:root 0700へ戻り、運用者が`chown 999:999 /srv/agent/postgres`で復旧 | 新規DB接続は`global/pg_filenode.map` Permission denied（08:27:49–08:29:49 UTCに20件）、pg_dump失敗。既存pool接続は継続、Hindsight operations completed=20 / failed=0 / pending=0、記憶損失なし。復旧後健康確認成功。WS26で再適用時の所有権競合とmount root属性変更を修正（後続の3〜6回目の記録参照） |
| 2026-10-18 17:30 JST | 運用者 | 手動backup set `20261018T083023Z`作成 | Hermes約24 MB、PostgreSQL約120 KB、agent-config、runner-workをage暗号化。`sha256sum -c SHA256SUMS`全件OK。`hindsight_version=unknown`は軽微な残件 |
| 2026-10-18 17:30 JST | 運用者 | `homelab-agent-restore 20261018T083023Z --identity <tmpfs file> --scratch` | total_nodes=5、recall 5 results、Hermes archive 667 entries、state.db integrity_check ok（2 DB）。scratch project削除、本番無変更。復旧identityはSSH stdinから`/run` tmpfsへ0600で一時配置し、EXIT trapでshred、終了後不在を確認 |
| 2026-10-18 JST | 運用者 | PR #107（`204f0f5`）反映後のmainから3回目`make ansible-apply-agent` | agent-vm changed=2、runner-vm changed=1。一度限りのRunner host-key pin形式とRunner `/etc/homelab/secrets`の0750→0700を反映。PGDATA 999:999 0700、`/srv/agent`・`/mnt/agent-backups`・secrets・SSH鍵directoryの属性は前後で不変。健康確認all checks passed |
| 2026-10-18 JST | 運用者 | Agent VMのrootから`chmod 0700 /mnt/agent-backups`でexport rootのmodeを復旧（`no_root_squash`） | export rootは契約値のroot:root 0700へ復旧。復旧待ちを解消 |
| 2026-10-18 JST | 運用者 | mainから4回目`make ansible-apply-agent` | runner-vm changed=0、agent-vm changed=1。ssh-keyscanのbanner commentを鍵に含めたためHermesのknown_hosts pinが毎回追記される不具合が判明。PR #108（`1d8b89c`）で単一の`<runner> ssh-ed25519 <base64>`行だけをpinするよう修正 |
| 2026-10-18 JST | 運用者 | Agent VMの`/srv/agent/hermes/.ssh/known_hosts`を一度限りの手動整理 | 5行（banner comment 2行、同じRunner鍵3行、うち1行はbannerが鍵に連結した不正形式）を正しい鍵1行へ整理。鍵は`qm guest exec`でout-of-band取得したものと一致、owner 10000:10000・0600 |
| 2026-10-18 JST | 運用者 | PR #108反映後のmainから5回目`make ansible-apply-agent` | agent-vm changed=1。bannerを除いたCDP known_hostsのcopyを一度限りで反映 |
| 2026-10-18 JST | 運用者 | mainから6回目`make ansible-apply-agent` | agent-vm changed=0、runner-vm changed=0。PGDATA 999:999 0700、export root 0700を維持。健康確認all checks passed、再適用の冪等性を確認 |

## ファイルの受け渡し（issue #194、2026-11-05反映済み）

大きいファイルは `\\samba.kojigenba-srv.com\hermes\inbox\` に置き、Hermes にファイル名を伝える。
成果物は `outbox/…` と Windows の `\\samba.kojigenba-srv.com\hermes\outbox\…` で受け取る。
Runner の実体は `/srv/agent-work/share`。inbox/outbox は約束で、権限分離ではない。
共有が空・目印無し・接続先不一致なら Hermes は書かずに利用者へ知らせる。
小さい画像等の MEDIA は共有パスからも利用できる（元パスと realpath の denylist 検査は維持）。
大きい成果物を Runner ローカルへ置いたままにしない。詳細は [共有運用](hermes-share.md)。

新 `hermes-share` skill は既存の skills tree の再帰 copy で配布される。`force: false` は
既存ファイルを保護し、新ファイルは追加する。初回追加で Hermes と CDP tunnel の再作成 handler が走る。
会話中を避けて `make ansible-apply-agent` を実施する。既存 skill 改訂は自動上書きされない。
2026-11-05 10:23 JSTにPR branchからapplyし、Agentはok=87 changed=4、Runnerはok=57 changed=5、
どちらもfailed=0。新skillの配布でHermesとCDP tunnelを再作成し、Hermesはrunningを確認した。
運用者がWindows・AndroidでSMB共有を利用し、Hermesのoutboxへのdirectory作成と
`10002:10004`・`2775`の継承を確認した。詳細と残る確認事項は[共有運用](hermes-share.md)。

## Runner のコーディング CLI（issue #207）

[ADR-0015](../adr/0015-hermes-coding-agents.md) の PR ①。
実機での導入・ログイン・推論実行・再 apply の changed=0 は未検証。
反映は本人が `make ansible-apply-agent` で行う。skill/config の変更は Hermes と
CDP tunnel を再作成するので会話中を避ける。GitHub 公開処理は PR ② 完了後に開始する。

### 導入と設定の所有者

`roles/runner/files/coding-agents/` の package.json と package-lock.json を
root 所有の `/opt/coding-agents` に置き、成功時の lockfile と SHA-256 を比較して、
変更時だけ `npm ci` を実行する。失敗した install は成功記録を更新せず、次回に再試行する。
`/usr/local/bin/{claude,codex,dsh}` はその `.bin` への symlink。
hermes-runner に導入先への書き込み権限は与えない。

2026-11-12 の npm registry latest を調べ、次へ固定した。

| package | 固定版 |
| --- | --- |
| @anthropic-ai/claude-code | 2.1.322 |
| @openai/codex | 0.167.1 |
| @deepseek-ai/dsh | 0.2.2-rc.1 |

gh は [Debian 13 の 2.46.0-3](https://packages.debian.org/trixie/gh) を apt で入れる。
必要な `pr create --base --head --body-file --repo` は
[その版のソース](https://github.com/cli/cli/blob/v2.46.0/pkg/cmd/pr/create/create.go) にあり、
外部 apt repository は不要。bubblewrap と socat も Debian apt 管理とし、OS の更新経路を使う。

[dsh rc.1 の changelog](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.1)
は 0.2.1-rc.5 以降をまとめている。
[旧 rc.5](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.1-rc.5) は thinking 表示改善が中心。
rc.1 は Node >=24.9、Cordis Core 4.1・Loader/Include 1.1、pi-ai 1.3 へ更新し、
PTC tool 実行の分割、tools.mode/DSH_TOOLS_MODE の移行、Node PTC の SSH protocol 2→3、
plugin の tools.resolve/executable・prompt assembly、SDK・Session API などに互換性変更がある。
また read-before-write/external-change 検査が既定で無効になり、Web Fetch は private address も
扱えるため、Runner の firewall 制限を維持する。
今回は独自 plugin/PTC helper を使わず、採用版の home patch・headless を確認できたこと、
pi-ai・model 切替・approval 保存などの修正を理由に rc.1 を選んだ。preview の互換性保証はない。

自動更新と設定の管理は次の契約とする。

- Claude は root 管理の `/etc/claude-code/managed-settings.json` の
  `env.DISABLE_AUTOUPDATER="1"` で停止する。
  [公式の managed settings](https://code.claude.com/docs/en/managed-settings) と
  [自動更新停止](https://code.claude.com/docs/en/setup#disable-auto-updates) の仕組みを使う。
  CLI が管理者設定を書き戻す経路ではなく、本人の `~/.claude` 設定・認証には触れない。
- Codex の `~/.codex/config.toml` は model=`gpt-6.1-sol`、effort=`medium`、
  `check_for_update_on_startup=false`。model 未指定で起動時の確認画面に止まる問題を避ける。
  [設定リファレンス](https://learn.chatgpt.com/docs/config-file/config-reference) に従う。
  [採用版の config writer](https://github.com/openai/codex/blob/rust-v0.167.1/codex-rs/core/src/config/edit.rs)
  はモデル等を保存できるため、対話操作で変えた値は次の apply で戻る。
- dsh の `~/.dsh/cordis.patch.yml` は作業端末と同じ DGX provider・ダミー Authorization を使う。
  glm-5.3-flash、context 1048576、output 65536、developer role 無効、max_tokens、
  bash timeout 600000ms。DeepSeek の API/account/web search と session telemetry を止める。
  desktop の telemetry/analytics は headless に存在しないため、その2 entryのpatchは含めない。
  [採用版 profile-boot](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/apps/cli/src/profile-boot.ts)
  は home patch を全 profile に重ね、通常起動では別の profile root config を書く。
  設定編集/plugin 操作には永続化経路があるので、ローカル設定変更も apply で戻す。
  CLI/headless に自動本体更新の経路・停止スイッチは確認されず、Desktop updater は使わない。
  plugin の追加・更新を worker に行わせず、必要なら repo の固定依存として見直す。

`.codex` と `.dsh` は hermes-runner 所有0700、設定は0600。
ディレクトリを再帰変更せず、`.claude/.credentials.json` と `.codex/auth.json` は
読み取り・配置・削除・属性変更の対象にしない。ログイン後も token refresh 用の書き込みを残す。
通常の headless 実行での設定の不変性、認証更新との併用、2回目 apply の changed=0 は実機で未検証。
対話設定の変更や Hermes の skill 編集があれば、その復元分は changed になる。

### 初回ログイン（本人が行う）

管理端末から deploy で Runner に入り、実行ユーザーへ切り替える。
以下は反映後の手順であり、今回の実装作業から本番接続はしていない。

```sh
ssh deploy@192.168.10.105
sudo -iu hermes-runner
claude auth login
codex login --device-auth
```

Claude は表示された URL を本人のブラウザで開く。サブスクリプションの Claude アカウントを選び、
Console/API 課金に切り替えない。Codex は本人の ChatGPT アカウントで device code を認証する。
必要なら先に ChatGPT の Security 設定で device code を有効化する。
URL/code/token を Hermes の会話・ログや repo に貼らず、CLI の保存に任せる。
Claude の認証は `~/.claude/.credentials.json`、Codex は `~/.codex/auth.json`。
認証ファイルを cat して確認しない。API キーや別の認証環境変数を注入しない。

### 失効と再構築

漏えいが疑われる場合は進行中の worker と Hermes の新規起動を止め、本人が対応する。
Claude は Claude の **Settings で該当サインインを削除してから**、同じユーザーで
`claude auth logout`。Codex は同じユーザーで `codex logout`。
成功表示やローカルのファイル削除だけでサーバー側の失効成功を断定しない。
Codex CLI は ChatGPT Active sessions の対象外なので、Web の全端末ログアウトを代用にしない。
失効を確認できない場合はアカウント側のサポート/セキュリティ手順で確認し、未検証と記録する。

home は Runner-work のバックアップ対象外。資格情報を `/srv/agent-work`、share、Agent の環境へ
コピーしない。Runner 再構築後は本人が再ログインする。
受入時は backup tar のファイル名一覧で認証情報が含まれないことを確認し、内容は表示しない。

### skill と作業の流れ

repo の skills 直下に `runner-coding`（使い分け）、`runner-claude`、`runner-codex`、
`runner-dsh`、`runner-publish` の5本を置く。
[Hermes c7da41dd の loader](https://github.com/NousResearch/hermes-agent/blob/c7da41dd522dc19cc08bbfcfa69d4b078224b45d/tools/skills_tool.py)
で YAML frontmatter の name/description、name 64文字・description 1024文字の上限、
カテゴリが配置パスから決まること、同じtierの名前衝突が拒否されることを確認した。
直下配置なので category はなし。固有名を使い、旧同梱 claude-code/codex は
`skills.disabled` で一覧/自動選択から外す（ファイル削除やアクセス制御ではない）。
直接skill_viewで読める経路は残るので、使い分けskillでも旧2本を使わないよう指示する。

既存 `Seed the shipped skills when absent` は force=false のまま。
今回の5本だけ別の copy task（force=true）で同期する。
**Hermes がこの5本を書き換えても、次の apply で repo の内容に戻る。**
hermes-share と weekly-review の既存編集は上書きしない。

作業は Runner の `/srv/agent-work/repos/<owner>/<repo>` で `agent/<topic>` branch を作って行う。
3 CLI は PTY を使わず `terminal(background=true, notify=true)`、
`timeout --signal=TERM --kill-after=30s 45m`、完了は `process_manage` と JSON/最終回答で確かめる。
SSH foreground は `bash -c`（非login）、remote background は `nohup bash -lc`（login）。
[SSH backend](https://github.com/NousResearch/hermes-agent/blob/c7da41dd522dc19cc08bbfcfa69d4b078224b45d/tools/environments/ssh.py)
と process_registry の両方を確認した。Debian の既定 PATH にある `/usr/local/bin` を使い、
`.bashrc` に依存させない。実セッションでのPATH発見は反映後に確認する。

Claude の `--permission-mode bypassPermissions` は
[CLI reference](https://code.claude.com/docs/en/cli-reference) で
`--dangerously-skip-permissions` と等価。
[公式 devcontainer 手順](https://code.claude.com/docs/en/devcontainer) は非rootユーザーでの使用を示す。
Runner の非rootで使い、VMを隔離境界とする。`--bare` は使わない。
Codex は workspace-write、必要時だけ network_access=true。sandbox が不成立なら原因を報告し、
Runner 側の制限を直すか別CLIを選ぶ。danger-full-access へ自動変更しない。

smart_policy は通常のデータ処理規則だけでは外部推論送信により ESCALATE され得るため、
対象repo内で固定CLIを起動し非機密コードを送る場合だけ狭く許可した。
資格情報の明示的読み取り・送信、無関係なupload、インターネットコードの取得・実行は
ESCALATEを維持する。実際の判定・悪意あるpromptへの耐性は未検証。
CLIには変更とテストまで、Hermesが確認後に commit・push・gh pr create。
GitHub認証は下記「GitHub App による公開」のcredential helperとgh-agentを使う。
main へのpush・mergeは禁止。本人への報告は使ったCLI・結果・テスト・残件を短くまとめる。

### 版の更新と反映前後の確認

package.json の3依存を exact version へ更新し、そのディレクトリで
`npm install --package-lock-only --no-audit --no-fund` を実行して lockfile を生成する。
差分の版・resolved・integrity・install scripts と changelog をレビューし、
一時ディレクトリで `npm ci` を検証してから、本人が `make ansible-apply-agent` を行う。
CLI自身の update/install コマンドは使わない。rollbackも以前のmanifest/lockへ戻してapplyする。
Nodeの最低版と設定schema・skillのフラグも更新ごとに確認する。

反映前にroot管理の導入先、既存ログインへの影響、再作成のタイミング、DGXの稼働endpointと
モデル容量、送るrepoの機密性を確認する。適用後の受入は次のとおり（いずれも実機では未検証）。

- Hermes の実 SSH session で `command -v claude codex dsh gh`、版、導入先の書き込み不可を確認。
- 初回ログイン後に小さな試験用 repo で3 CLIの変更・テスト・終了通知・構造化結果を確認。
- Codex/dsh の sandbox、dsh のbwrap選択、GLM tool calling、DGXの競合を確認。
- RunnerからDGX TCP/8000だけが通り、同hostの他port・他LAN宛は拒否されることを確認。
- 通常実行後の設定と認証維持、連続2回目 apply の changed=0、backupのhome除外を確認。
- smart approvalで通常CLI起動を許可し、資格情報読み取り/送信をESCALATEするか確認。

PR ②のApp設定・鍵登録・repo onboarding・公開受入は下記「GitHub App による公開」に従う。

## 長時間作業: agent-job（PR ①.5）

長時間・放置する作業は `runner-agent-job` skill を使う。計画と状態の正は Runner、
Hermes は計画して起動したあと短いターンに戻る。Webapp を閉じても段階は driver が進める。
以下は Runner の hermes-runner で使うコマンド。**実機は未検証**。

```sh
agent-job start /srv/agent-work/plans/task-01.json
agent-job status task-01 --json
agent-job list
agent-job stop task-01
agent-job resume task-01
# 本人が原因を確認し、追加の時間・予算を承認した場合
agent-job resume task-01 --deadline-hours 6 --max-launches 60 --max-consecutive-failures 5
```

計画例と必須項目は [runner-agent-job skill](../../files/services/agent/hermes/skills/runner-agent-job/SKILL.md)。
対象は `/srv/agent-work/repos/<owner>/<repo>` の clean な checkout。初回は base から新しい
`agent/` branch を作る。id の再利用、既存 branch への初回起動、同じrepoでの二重起動は拒否する。
外部の直接CLIも同じcheckoutで走らせない。排他の対象はこのdriver経由のjobである。

| 制限 | 初回 | 再開 |
| --- | --- | --- |
| 全体の期限 | 既定・最大6時間 | `--deadline-hours` 指定時点から最大6時間 |
| CLI起動 | 既定・最大30回 | `--max-launches` で累積上限を増やす |
| 連続失敗 | 既定・最大3回 | 再開で回数をリセット、上限は明示した場合に増やす |
| 1段階のtimeout | 既定45分・最大120分 | 既存計画を使う |
| 同時実行 | 同じrepoは1、全体2 | 同じ |
| メモリ | serviceごと6GiB（Runner 15GiB・swapなしで、2件合計12GiB） | 同じ |

`continue` と、正常終了したが状態行のない出力は、同じ段階・CLI session へ「続けて」を送る。
終了コード非0・timeout・不正JSON等は失敗として記録し、session ID が得られた場合はresumeする。
CLIがsessionを作る前に失敗した場合だけ、次回も新規起動になる。成功応答で連続失敗回数を戻す。
`blocked` は理由を state.json に残す。受入条件の自動実行判定はCLIに依存するため、
`done` の表示だけで本人への完了報告を済ませない。

`/srv/agent-work/tasks/<id>/` には plan.json、atomic更新のstate.json、
runs/<累積起動番号>/stdout・stderr・result.json・exit-code がある。
state.json の stage は0始まり、sessionsは段階ごと、cli_sessionsは各CLIの直近のID。
launches、consecutive_failures、deadline_at（Unix時刻）、summaryを確認する。
CLI出力は既知のcredential文字列をマスクする。ログ・計画は0700のtask配下に置き、公開しない。
マスクは完全な秘密検出ではない。資格情報を読む依頼は禁止し、公開前に差分を点検する。
資格情報らしいファイル名が変更されると checkpoint を作らず blocked にする。

| 状態 | 対処 |
| --- | --- |
| queued / running | 起動待ち / 実行中。状態と直近runを確認 |
| done | 公開無効の計画を完了。差分・テスト・ログをレビュー |
| ready_to_publish | 段階は完了、App鍵/helper未導入。登録・導入後にresume |
| published | draft PR作成済み。本人がレビューしmergeを判断 |
| blocked / failed | 理由とrun結果を確認し、必要な修復後にresume |
| stopped | 停止済み。再開前に部分変更を確認 |
| deadline | 期限到達。本人の判断で時間・予算を追加してresume |

`start` は `systemd-run --user` の起動後すぐ戻る。linger と `user@<uid>.service` をAnsibleで用意する。
`systemctl --user status agent-job-task-01.service`、`journalctl --user -u agent-job-task-01.service`
も使える。`stop` は停止フラグを置いてserviceのcgroupを停止する（15秒後に強制終了）。
Hermes会話の `/stop` だけではRunner jobは止まらない。ホスト再起動後にjobは自動再開しない。
状態がrunningのままserviceがない場合は、通知後、人が差分を確認してresumeする。
古いtaskを消す前に必要な結果を保存する。自動削除は設けていない。

見張りはAgentコンテナの `$HERMES_HOME/scripts/runner-agent-job-alerts.py`。
weekly-reviewと同じcron list/createの経路で、名前 `runner-agent-job-alerts`、`*/10 * * * *`、
`--no-agent --deliver discord:<home_channel>` を登録する。既存同名jobは保持するので、設定を
変える場合は登録内容も本人が確認する。cron一覧取得に失敗したapplyでは登録を進めない。
固定版のベースimageにはopenssh-clientがあり、terminalと同じ鍵・known_hosts・ユーザーを使う。
no_agentはLLMを呼ばずstdoutをそのまま配送する。空stdoutは無通知。
通知対象は完了・公開待ち・公開済み・blocked・失敗・停止・期限切れ・driver消失。
明示的なstopだけでなく、Runner再起動時のSIGTERMによるstoppedも一度だけ通知する。
通知文はIDと状態だけなので、Webappで詳細を調べる。SSH失敗は復旧するまで1回だけ通知する。
通知済み記録後の配送失敗には自動再送がないため、状態確認も併用する。

PR ② のhelper契約は `/usr/local/libexec/agent-job-github-credential`（root所有・group/other書込不可）。
Git credential protocolで短命App tokenを返し、CLIの環境には渡さない。
公開時だけdriverがhelperを使い、対象owner/repoと一致するGitHub HTTPS originへ
`agent/...` をpushし、`gh-agent <owner/repo> pr create --draft --base <planのbase>` を実行する。
失敗後はpushまたはPRが既に作られていないかを本人が確認してから再開する。
公開失敗後の自動復旧は冪等ではない。helper/wrapperのローカル統合はfixtureで検証し、実GitHub受入は別途行う。

apply前には `make agent-job-fixture` と既存Runner・Agent fixtureを実行し、
Dockerを使う `make ansible-lint-agent ansible-check-agent shellcheck` は管理端末で行う。
apply後の試験用repoで、user manager・MemoryMax・子孫を含むstop・3 CLIの認証とresume・
DGX競合・gateway再起動中の継続・空出力の無通知・SSH障害の抑制と復旧・Discord配送を確かめる。
これら実機受け入れとPR ②の公開試験は **未検証**。

### 固定版CLIのローカル確認（2026-11-12）

PR ①と同じ package-lock.json を scratchpad にコピーして `npm ci` した。
Claude Code 2.1.322、Codex 0.167.1、dsh 0.2.2-rc.1 の実体でhelpを確認した。
Node 24.20.0と資格情報のない一時HOMEで、存在しないsessionをresumeするダミー実行も行い、
3 CLIともsession不存在のエラーになることを確認した。実際の認証情報・本番ホストは使っていない。

| CLI | 初回出力とresumeの確認 |
| --- | --- |
| Claude | `-p --output-format json` のresult/session_id/is_errorを読む。`-p --resume <id> --output-format json` はhelpと不存在sessionで確認。成功JSONの解析はfixtureで検証、認証済み成功は未検証 |
| Codex | JSONLのthread.started.thread_id、item.completedのagent_message、turn.completed/errorを読む。`exec resume <id> --json` はhelpと不存在sessionで確認。resumeに`--sandbox`はないためglobal `-c sandbox_mode="workspace-write"` と network_access、`-a never` を共通で渡す。成功JSONLはfixtureで検証、認証済み成功は未検証 |
| dsh | 固定npmパッケージのjson-stream実装でsession.sessionIdとfinal.sessionId/text/reason.kindを確認。初回はsession-idなし、再開時のみ`--session-id`。headlessに`--model`はなく、任意modelは`--patch`でlocal-glmのagent-default-modelを指定。helpと不存在sessionのJSONL errorを実行確認。成功・resumeの遷移はfixtureで検証、DGX成功実行は未検証 |

出力形式の変更はdriverの更新が必要。CLIの版を変える際はhelpと実出力を再確認し、
fixtureの成功・失敗・resumeを更新してから反映する。

ローカルの新fixture 24件と既存Runner・Agent系fixture、`git diff --check` は成功した。
実行環境はPython 3.12.3。driverはPython 3.13標準ライブラリで使えるAPIに限定しているが、
RunnerのPython 3.13上での実行は **未検証**。Dockerを使うmakeはこの作業では実行していない。

## GitHub App による公開（PR ②）

以下のGitHub設定変更・SOPS編集・applyは**本人が管理端末で行う**。
Runnerへ個人PATや本人のghログインを渡さない。既存bundleはこの実装作業では変更していない。

### 1. App の作成とインストール

1. GitHubの本人アイコン → Settings → Developer settings → GitHub Apps → New GitHub App。
   名前（以後slug）と本人管理のHomepage URLを入力する。OAuthのcallbackは使わず、
   WebhookのActiveをoffにする。
2. Repository permissionsを **Contents: Read and write、Pull requests: Read and write、
   Metadata: Read-only** にする。Workflows・Administration・Actions・SecretsはNo access。
   Organization/Account permissionsも追加しない。
3. Where can this GitHub App be installed? は **Only on this account** を選び、作成する。
   GeneralでApp IDを控え、Private keys → Generate a private keyでPEMを生成する。
   ダウンロードした鍵は暗号化された管理端末上で0600にし、会話・ログへ貼らない。
4. Install Appから本人アカウントへ **Only select repositories** でインストールする。
   最初は試験repoだけを選ぶ。Settings → Applications → Installed GitHub Apps → Configureの
   URLにあるinstallation IDを控える。All repositoriesを選ばない。
   初回に選んだrepoにも、利用開始前に次のonboardingでmain保護を付ける。

[App登録の公式手順](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
と[installation tokenの限定](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
を参照する。

### 2. SOPS への登録と公開 bot 名義

[secrets READMEの既存bundle編集](../../files/infrastructure/secrets/README.md#既存bundleの編集)
にあるpinned toolboxと`sops_toolbox`関数を使用する。既存bundleをexampleで置き換えない。
今回のtoolbox SOPS 3.10.2では既存の `sops set` でJSON値を渡す。
次は本人が行う例。`set -x`を無効にし、鍵の内容を表示しない。

```sh
# APP_ID / INSTALLATION_ID は画面で控えた数値、PEM_FILE は安全な保存先の絶対path。
# 値やPEMをshellのコマンド本文へ直接書かない。
export APP_ID INSTALLATION_ID PEM_FILE
github_app_json=$(python3 - <<'PY'
import json, os, pathlib
print(json.dumps({"app_id": os.environ["APP_ID"],
                  "installation_id": os.environ["INSTALLATION_ID"],
                  "private_key": pathlib.Path(os.environ["PEM_FILE"]).read_text()}))
PY
)
sops_toolbox set files/infrastructure/secrets/agent/runtime.sops.yaml '["github_app"]' "$github_app_json"
unset github_app_json
chmod 0600 files/infrastructure/secrets/agent/runtime.sops.yaml
AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make secrets-decrypt-check-agent
make secrets-scan
```

既存READMEと同じく `sops set` のJSON引数は短時間process listに現れる。共有端末・収録中は行わない。
初回bundle作成だけならexampleの3項目を埋め、既存の `make secrets-encrypt-agent` を使う。
既存bundleを上書きするために削除しない。平文の一時copyは残さず、安全な鍵の復旧copyは保管する。

slugとbot user IDは秘密ではない。本人のghで次を実行する。

```sh
gh api '/users/<slug>[bot]' --jq '{login, id}'
```

`files/infrastructure/ansible/agent/group_vars/runner.yml` の `runner_github_app_slug` と
`runner_github_bot_user_id` を**両方**埋める。commit名は`<slug>[bot]`、emailは
`<id>+<slug>[bot]@users.noreply.github.com`。未設定なら従来のAgent Job Botを使う。
PR作成者はcommit名義とは別にApp tokenで決まる。

bundleはcontrollerだけで復号し、Runner playへno_logのfactで渡す。
`/etc/homelab/secrets/github-app.pem` と `github-app.json` はgh-broker所有0400。
非ログインのgh-brokerだけが鍵を読み、root所有brokerがrepo限定の短命tokenを作る。
cacheは`/var/lib/gh-broker`（0700）のrepo別0600ファイル。残り5分未満なら更新する。
Agentコンテナのenv、share、runner-workには鍵を配らない。age鍵もVMへ配らない。

### 3. repo の onboarding と反映

本人の作業端末で `gh auth status --hostname github.com` を確認する。
rulesetを管理できる本人の認証が必要（App tokenは使わない）。
本人のgh OAuth token（gho_）ではinstallation APIを使えないため、スクリプトはrulesetだけを扱う。
新規repoは本人が作る。スクリプトはrepoを作成しない。

```sh
scripts/github-agent-repo-onboard.sh owner/repo --dry-run
scripts/github-agent-repo-onboard.sh owner/repo
scripts/github-agent-repo-check.sh owner/repo
# onboardingの案内URLは既定でinstallation 180956595。
# 他のAppでは第2引数 / --installation-id / GITHUB_APP_INSTALLATION_IDで案内先だけを変更できる。
# checkにinstallation IDは不要。
```

`--dry-run`はAPIを呼ばず予定を表示する。onboardは同名rulesetを作成/更新し、設定を表示する。
checkはrulesetの一覧・詳細を読むだけで、期待する設定との比較をmatchesに表示する。
未作成または不一致なら非0で終了する。GitHubが省略するupdateのfalse既定値や応答のメタデータは正規化する。
Appへのインストール状況は確認しない。重複した同名rulesetは停止して本人へ整理を求める。
途中失敗ならcheckで確認して再実行する。

**順番は「rulesetを付ける → 画面でインストール先に足す」**。
onboard完了後、表示されたrulesetを確認し、本人が
[Appの設定画面](https://github.com/settings/installations/180956595)の **Repository access** を開く。
**Only select repositories** のまま対象repoを追加してSaveする。
スクリプトの最後にもこの案内を表示する。APIによるinstallationの一覧取得・確認・追加は行わない。
既にAppへ追加済みのrepoの保護はretroactiveにはならない。

main保護は `agent-main-protection` 1本。active、対象`refs/heads/main`、update・deletion・
non_fast_forward、既定のbypassはRepository admin（RepositoryRole ID 5）のalwaysのみ。
Hermes Appはbypassへ入れず、必須レビューのrulesetは追加しない。
表示された設定を本人が確認する。既存の他rulesetはスクリプトで削除しない。
[Rulesets API](https://docs.github.com/en/rest/repos/rules)を参照する。

#### public/private と GitHub のプラン

**GitHub Freeのprivate repoはrulesetで守れない。** 実機でrulesets APIは
403「Upgrade to GitHub Pro or make this repository public」を返した。
[公式の提供範囲](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)
もFreeではpublic、Proではprivateを含む。
Appのインストール先はpublic repoだけにするか、Proにするか、mainを守れないリスクを承知して
private repoにも入れるかを本人が判断する。最後の選択ではAppがmainへpush・mergeできるため、
「main更新は本人だけ」の保証は成立しない。スクリプトは403で停止し、保護済みとは表示しない。
本人の実機結果ではagent-sandboxをpublicにしてonboardingし、ruleset IDは27049802となった。
公開化はコードや履歴の公開を伴うため、スクリプトはvisibilityを変更しない。

#### homelab の GitHub Actions による main 更新

**homelabは、下記の別PRによる移行とonboardingが完了するまでAppのインストール先から外しておく。**
現在の `.github/workflows/stashpad-staging-image.yml` は毎時、`GITHUB_TOKEN`でstagingのdigestを
mainへ直接pushする。adminだけのupdate制限ではこのpushも拒否される。
本人がhomelabへIntegration 15368をbypassに指定してPOSTした実機結果は422
「Actor GitHub Actions integration must be part of the ruleset source or owner organization」。
**個人のrepoでは組み込みGitHub Actionsをbypassにできない。** 旧Actions bypassオプションは削除した。

別PRで、このworkflowのpush認証をrepo専用の書込可能deploy keyへ変更する。
秘密鍵は**Actions secretとして、利用branchをmainだけに限定したenvironment**に保存し、
そのenvironmentを使うmain上のjobだけに渡す。Hermes App・Runnerには配らない。
workflow変更、鍵の生成/登録、environment/secret設定は今回行わない。
本人が移行を確認した後、次の順に進める。

```sh
scripts/github-agent-repo-onboard.sh koji-genba/homelab --allow-deploy-key-bypass --dry-run
# workflowとActions側の鍵/environmentの移行後、本人が設定変更を承認して実行する。
scripts/github-agent-repo-onboard.sh koji-genba/homelab --allow-deploy-key-bypass
scripts/github-agent-repo-check.sh koji-genba/homelab --allow-deploy-key-bypass
# ruleset確認・deploy keyによる毎時push確認後、画面でAppのインストール先へ戻す。
```

指定時は `actor_type: DeployKey`、`actor_id: null`、`bypass_mode: always` をadminに追加する。
[公式REST API仕様](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset)では
DeployKeyのactor_idはnullであり、特定の鍵IDを指定しない。これはrepoのdeploy keyに対する例外で、
単一workflow/単一鍵だけの例外ではない。書込可能deploy keyの一覧と保管先も本人が管理する。
再実行時にも同じオプションが必要で、省略するとadminのみへ戻る。Hermes Appはbypassへ入れない。
checkは同じオプションを付けて期待する設定を選択するだけで、設定変更は行わない。
update制限は維持し、workflowの更新専用認証だけを例外とする。

Hermes AppにはWorkflows権限がなく、workflowの追加・書き換えはpushできない。
現行の書込可能workflowはschedule/手動起動でmainをcheckoutし、固定のinline処理でstagingファイルだけをcommitする。
PRで動く他workflowのcontentsはreadで、Hermes AppにはActions操作権限もない。
別PRでもdeploy keyをmain限定environmentに隔離し、PRコードや作業branchで鍵を使わせない。
この構成を守る限り、Hermes AppがActions経由でmainへpushする経路は作れない。
将来write token/鍵でPRコード・repo内scriptを実行するworkflowを加える際は再レビューする。

必要なlintを実行し、本人が明示的に承認してから既存手順で `make ansible-apply-agent` を行う。
Agent playでcontroller復号したfactをRunner playが使うため、初回は`--limit runner`で省略しない。
3項目が未登録/空ならGitHub構成は導入せずjobは`ready_to_publish`。
後から項目を消してapplyした場合は鍵・設定・helper・sudoers・cacheを削除して公開を無効化する。
公開bot名義とglobal ignoreは鍵未登録でも管理する。

### 4. 公開と受け入れ

手動の短い作業は `runner-publish`、長時間は `runner-agent-job` skillに従う。
作業branchは`agent/<topic>`、`git push origin HEAD:refs/heads/agent/<topic>`、
`gh-agent owner/repo pr create --draft --base <base> --head agent/<topic> --title ... --body-file ...` の順。
`gh-agent`はpr create/view/list/editだけで、createはdraft必須、editは番号指定かつdraftを再確認する。
引数は長い形式を使う。baseは対象repo・planに合わせて指定し、有効なgit refでheadと異なることが必要。
main以外のdefault branchも利用できる。editはtitle/body/body-fileのみ。merge/ready/apiや別repoへの引数は拒否する。
Git helperはHTTPS github.comとowner/repo pathだけに応え、store/eraseは保存しない。
workerにtokenを発行・表示させない。CLI sandbox/skillは同一UIDの資格情報を隔離する境界ではない。

`agent-job`はチェックポイントにglobal bot名義を使い、公開時にhelper所有権とorigin/push URLを照合し、
上記wrapperでdraftを作る。失敗後はremoteと既存PRを確認してからresumeする。
公開復旧は自動で冪等化していない。push成功後のPR作成失敗や応答断では既存PRを本人が確認する。
`.github/workflows`の変更を含むpushはAppの権限で拒否されるので、本人に対応を頼む。
main更新・mergeも本人だけが行う。

`~/.config/git/ignore`はpyc、node_modules、.venv、各種cache、dist、buildを除外する。
追跡済みの生成物はignoreでは消えないので、既存checkpointに入ったものは別途レビューする。

反映後、**試験repoで本人の承認のもと**次を確認する（このPRの実装作業では未検証）。

- App名義の作業branch pushとdraft PR作成、draft編集・一覧・確認。
- Appによるmain push、PR merge、workflow変更pushの拒否。mainは保護を確認してから試験する。
- 未onboard repo/不一致ownerでtoken取得失敗、短命tokenや鍵がログ・backupに入らないこと。
- `sudo -l -U hermes-runner`がbroker1コマンドのみ、sudo/docker group無し。
  brokerの鍵/config 0400、cache 0600、helper/programがroot所有でgroup/other書込不可。
- controller以外で復号しないこと、連続2回目applyのchanged=0、鍵未登録時の公開待ち。

ローカルは `make runner-github-fixture agent-job-fixture runner-privilege-fixture
agent-runner-scope-fixture runner-firewall-fixture` と `git diff --check`。
Dockerの `make ansible-lint-agent ansible-check-agent shellcheck` は本人の端末で実施する。
2026-11-12のPR①受入はissue #207のコメントを正とし、過去節の「実機未検証」は採用時点の記録。
PR②の実機公開試験は別途必要である。

### 5. 失効・漏えい時

漏えいを疑ったら新規jobを止め、本人がGitHub AppのGeneral → Private keysで該当鍵を削除（revoke）する。
Settings → Applications → Installed GitHub Apps → ConfigureからinstallationをSuspendまたはUninstallし、
発行済みtokenによるアクセスも止める。鍵revokeだけで既存tokenの即時失効を仮定しない。
installationのSuspend解除/再インストールは原因を取り除いてから行う。
必要なら漏れたinstallation token自体もGitHubのtoken revoke APIで失効させる。

新しい鍵を生成してSOPSを更新し、本人承認のapplyで差し替える。brokerは鍵/configの変更時に旧cacheを
再利用しない。完全停止ならbundleのgithub_appを空にしてapplyする。
PEM・config・cacheはrunner-work backupに含まれないのでRunner再構築時はSOPSから再配置する。
秘密を表示せず、監査ログ・branch/PR差分と公開されたコードを確認する。

**App鍵が漏れるとインストール先の全repoへ、App権限内でpushでき、tokenを再発行され続ける。**
repo限定tokenが漏れた場合はそのrepoに限定され、通常1時間で失効する。
mainは設定したrulesetで守られるが、他branch・PR・コードの改変や読み取りは可能。
本人管理のworkflowが作業branchのコードを本番へ反映しないこともonboarding前に確認する。
