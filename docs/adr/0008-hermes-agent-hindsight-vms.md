# ADR-0008: Hermes常駐エージェントとHindsight記憶を2台のVMへ分離して追加する

- 状態: 実装済み（repo定義済み、2026-10-17）。実機では未検証（初回構築は未実施）
- 日付: 2026-10-17

## 背景

長期記憶と実行能力を持つ個人用の常駐エージェントをhomelabへ追加する。主な窓口はDiscordで、
次の性質が要件になった。

- 本人が明示した事実と、会話から推測したことを区別して長期記憶へ保存し、根拠付きで想起する。日本語が主。
- 任意のコマンド実行とブラウザ操作を、記憶DB・Discord token・homelabの管理credentialから分離する。
- 記憶providerを将来差し替えられるよう、provider非依存のエクスポート手段を持つ。
- 既存Apps VMの「mainマージ=15分reconcile」境界（[ADR-0002](0002-iac-and-deployment-boundaries.md)）と、
  [ADR-0001](0001-single-apps-vm-compose.md)で単一VMへ集約した資源を崩さない。
- 推論は既存のDGXエンドポイント（OpenAI互換API、`tensorfold serve`）を共用し、新しいGPUを要求しない。

## 決定

上流はHermes `v2026.9.24`（Hermes 0.21.5）を採用し、`nousresearch/hermes-agent`をbaseにした自前イメージへ
HindsightのHermes統合を固定revisionで同梱する。実行時にcatalogからproviderを取得しない。

機能を2台のVMへ分離する。どちらもVLAN 10（`192.168.10.0/24`）に置き、tailnetには参加させない。
TailscaleのTerraform root・ACLは変更しない。

| VM | VMID / LAN IP | 役割 | 主な内容 |
| --- | --- | --- | --- |
| Agent VM | 104 / `192.168.10.104` | 常駐エージェントと記憶 | Hermes gateway、Hindsight、記憶DB、TEI embedding/rerank、CDPトンネル |
| Runner VM | 105 / `192.168.10.105` | 実行と隔離ブラウザ | `hermes-runner`実行account、ヘッドレスChromium、coding toolchain。Discord token・記憶DB・管理鍵を置かない |

VM定義はTerraform root `files/infrastructure/terraform/{agent-vm,runner-vm}/`、OS設定はAnsible root
`files/infrastructure/ansible/agent/`（group `agent` / `runner`）が持つ。Agent VMのComposeは
`files/services/agent/stack/compose.yaml`（project名`agent`）に置き、**`files/services/compose/`の外**に
出す。これによりApps VMの15分reconcile、起動helper、digest gate、`scripts/compose-config.sh`の探索対象から
外れる。CIの静的検証は`make agent-compose-config`等で別途効かせる。

Agent系の反映は**Ansibleの手動適用**（`make ansible-apply-agent`）とする。mainマージでは自動反映しない。
Composeは5サービス（`memory-db` / `embedding` / `reranker` / `hindsight` / `hermes`）に加え、
ChromiumのCDPをSSHで転送する`cdp-tunnel`を既定で起動する。全イメージはdigestで固定し、
自前の`homelab-hermes-agent` / `homelab-memory-db` / `homelab-tei-reranker-onnx`はCI → GHCRでbuild・公開する
（2026-10-18に初回公開し、digestは`compose.yaml`へ転記済み）。起動helper（`homelab-agent-compose-up`）は
ALL-ZERO placeholderや未固定imageを検出すると起動を拒否する（安全策）。

記憶はHindsightの`local_external`モード、固定bank`personal`で持つ。全文検索にPostgreSQL 17 + PGroonga、
embeddingに`cl-nagoya/ruri-v3-310m`、rerankerに`cl-nagoya/ruri-v3-reranker-310m`をTEI CPUで自前配信する。
ruri-v3は非対称retrieverのため、query側とpassage側のtask prefix（`検索クエリ: ` / `検索文書: `）を
クライアント側で付与する。明示/推測の区別はbankのmission/dispositionと`SOUL.md`で行い、providerをラップする
独自実装は作らない。「覚えないで」「消して」「何を覚えている？」の自前機能は今回作らない。代わりに
(a) 明示と推測の区別、(b) 週次振り返り（Hermes cron + Skill）、(c) エクスポート/再構築を用意する。

LLMはDGXの単一エンドポイント`http://192.168.10.51:8000/v1`（モデル`glm-5.3-flash`）を共用する。
fallback providerは置かず、テキスト専用として扱う。tensorfoldに優先度機構が無い前提に立ち、
背景処理（記憶抽出・統合・振り返り）の同時実行数を1へ絞り、会話ターンを塞がないよう
`context_length`と出力上限を実用値でpinする。

Runnerのegressは、VM内nftablesでLAN・`100.64.0.0/10`・link-local宛の新規接続を遮断し、インターネットだけを
許可する。例外は変数で明示する。長命サービスは`restart: unless-stopped`を使う。Agent stackには
reconcilerもsystemd unit orderingも無く、状態はローカルデータディスク（NFSではない）に置き、bind mountは
`create_host_path: false`で欠落時に起動失敗させる。`unless-stopped`は再起動後にサービスを復帰させ、
operatorが明示停止したものは停止のまま保つ。

モデルの事前取得だけは、AdGuardがHugging Faceのxet CDNをNXDOMAIN化するためresolver `1.1.1.1`と
`HF_HUB_DISABLE_XET=1`を使うdownload-onlyコンテナで行う。AdGuardの設定は変更しない。取得後はTEIを
HFオフラインで起動する。

## 検討した代替案

- **Apps VMの追加Compose projectとして同居**は採用しない。単一VMの資源をエージェントの常駐プロセス
  （CPU推論・Chromium）が奪い、reconcile・digest gate・mount guardの対象へ混入する。記憶DBや管理鍵を
  既存アプリと同じhostへ置くことにもなる。
- **Runnerを別VMにせずコンテナ／Agent VM内で実行**は採用しない。任意コマンド実行とブラウザを記憶DB・
  Discord token・管理credentialから分離する要件に反する。Runnerをtailnetへ参加させる案も、Tailscale ACL
  変更を伴うため採用しない（宅外からはgatewayのsubnet routeで管理する）。
- **記憶をHermes組込みの`USER.md`/`MEMORY.md`のみで持つ**は採用しない。日本語の検索・統合・根拠付け、
  provider差し替え、世代管理されたバックアップが要件に届かない。
- **embeddingに`BAAI/bge-m3`単体、rerankerに`BAAI/bge-reranker-v2-m3`**（当初の仮置き）は採用しない。
  日本語の架空記憶145件・問い98件（正解あり85件）のベンチで、embedding単体のnDCG@10は
  `ruri-v3-310m` 0.873 > `bge-m3` 0.859 ≈ `qwen3-embedding-0.6b` 0.855 > `multilingual-e5-large` 0.823 >
  `ruri-v3-130m` 0.816だった。最良ペア`ruri-v3-310m` + `ruri-v3-reranker-310m`はnDCG@10 0.923 /
  R@1 0.737 / MRR@10 0.912で、embedding単体から+0.051。rerankはCPUで1クエリあたりp50約2.7〜3.2秒。
  `bge-m3`単体（0.859、43.5文/秒、query p50 40ms）は速度重視の代替候補として残すが、差0.014は
  誤差範囲の可能性がある。
- **providerをラップして推測を排除**は採用しない。providerの契約から外れた独自層は保守負担が大きく、
  効果も限定的である。bank missionと`SOUL.md`で方針を与える。
- **`restart`をApps VMと同じく未設定**は採用しない。Agent stackにはreconcilerが無く、再起動後に
  復帰させる仕組みが必要である。

## 影響

- VMが2台増え、CPU推論（TEI）がAgent VMの主な負荷になる。マシン資源はTerraform変数で増設できる。
- 推論は単一のDGXエンドポイントをOpen WebUIと共用する。背景処理の同時実行を1へ絞ることで会話への
  影響を抑えるが、構造的な優先度制御は持たない。将来エンドポイントが増えたらfallbackや優先度を再検討する。
- バックアップは日次でAgent VMからpve1の専用NFS exportへage暗号化して書き、復号identityはVMに置かない。
  provider移行は完全復旧（backup）ではなくエクスポート（`export-bank` + provider非依存JSONL）と再構築で行う。
- 実機では初回構築を通しで実行していない。手順は実装から導いたもので、各運用手順に検証状態を付す。
- 未決事項として、context_length・出力上限等のその他ユーザー確認項目と、embedding変更時の再構築手順の実地確認が残る。
  `memory.write_approval`・vCPU・rerank候補数は下記WS12補足のユーザー決定による。

## 2026-10-17補足: WS7a/WS7cローカル結合試験

架空データ35会話とexport・暗号化scratch restore・bank消去後のDB復元をローカルで実施した。実機での
初回構築・Discord・Runner・NFSは未検証。計測値と受入範囲は
[運用文書](../operations/hermes-agent.md#サービスの資源上限)を参照する。

**1回目（修正前、WS7a）**: 総合受入は未達。Bの完全正答60% / 正答+部分70%、Iの分離失敗、F3の想起漏れがあり、
会話p95は76.24秒、診断rerank p50は7.03秒だった。

**2回目（WS7c、WS12変更前の設定）**: Aを除く全群が受入閾値を満たした（B 100%/100%、Dの旧情報誤提示0、Eの創作0・不明100%、
Iの事実/推測分離、Fの完全正答100%）。Aは87.5%で1件の創作が残る。会話p95は50.39秒へ短縮し暫定目標を
達成したが、20候補rerankはp50 4.24秒で3秒目標は未達。質問だけの群（B・D・E・I・F）で記憶は増えず、
assistant由来語句の混入は0件だった。速度は候補の順位を変えず（最大スコア差約3.1e-8）本文を切らない設定で
改善し、品質ベンチはnDCG@10 0.923（rerank後）でWS4のベストペア値に一致した。

- rerankerはCPU推論プールを明示する。`cpus: 4`、`RAYON/OMP/MKL` threads 4、tokenization workers 2、
  `--max-batch-requests 1`を指定（実際はCandle CPUの4で上書き。下記WS16で訂正）、`max-batch-tokens` 2048。2スレッドは遅く、batch512は本文を
  切るため、より小型のrerankerは品質または対応の面で採れなかった。この時点ではVMのvCPU増設は変更案だった。
  現在の資源配分は下記WS14補足に従い、applyはしていない。
- 候補数はLOW 8 / MID 20 / HIGH 30。MID 12は一部の検索で根拠が落ちるため採用しない。
  複合質問は20でも落ちるため、質問の分割だけで完全に直ったとはしない。2回目のF群は4/4正答だった。
- 低いreranker絶対スコアは同じ固定モデルをtransformersの分類経路で照合して一致した。
  絶対スコアで正解を消さないよう、recall_min_reranker_scoreは0.0を維持する。WS4の短文ベンチと
  実会話の長い記憶候補では速度が異なるため、WS4の数秒を結合試験のSLOとはしない。
- assistantの誤回答が自動retainで本人の事実になり、observationへ伝播した。mission追加だけでは防げず、
  custom抽出で本人の明示発話だけを採る方針を設定した。2回目の35問では誤名・変更理由の混入は0件だったが、
  1回目で伝播した既存bankの修復は未実施。SOULの固有名詞・日付・検索の指示もLLMへの方針であり、コード上の強制ではない。
- 事前取得は固定Pythonのdownload-only helperに全推移依存のhash付きrequirementsを添付する。
  実行時のTEIはlocal snapshotを読む。exportはtmpfsのarchiveをexecで取り出し、restoreは接続ユーザーを
  明示する。2回目は52記憶とrecallを確認したが、本番restore全体は実機未検証。

## 2026-10-17補足: WS8運用レビュー

WS7bの模擬Runner試験ではterminal・CDP・healthcheck/backupを部分確認した。実VMのsystemd制限と
Chromium sandboxの組み合わせは未検証である。WS8では安全snapshot前の書き込み停止、失敗通知・平文掃除、
healthcheckの再通知間隔とstats失敗検知、rebuildのHermesタイムゾーン・pending operation再開・新bankへの
custom方針適用を修正し、ローカルfixtureで確認した。修正後の実LLM通し試験と本番DRは未検証。
現行の正確な手順と検証範囲は[運用helper文書](../operations/hermes-agent-backup.md)を正とする。

## 2026-10-17補足: WS12ユーザー決定

この節は当時の決定を保存する。CPU・メモリ配分と再計測対象は後述のWS14補足で更新した。

- Agent VMを6 → **8 vCPU**へ増やす。メモリは16 GiBのまま。rerankerを6 CPU、
  `RAYON/OMP/MKL` threadsとtokenization workersを各6、embeddingを1 CPUにする。
  両TEIの上限合計を7 CPUとして、同時稼働時もOS・Hermes・Hindsight・DB用に1 CPU相当の余地を残す。
  他サービスにCPU上限はなく、これは各サービスのCPU予約ではない。
  WS7cのF3再生では4 CPUで約6.23秒、6 CPUで約5.07秒だったが、この8-vCPU配分は未計測である。
- **品質優先でMID 20 / HIGH 30を維持**する（LOW 8・本文上限2048も維持）。20候補rerank p50の
  3秒目標は未達のまま受け入れる。既存の会話p95 50.39秒は6-vCPU設定の結果であり、
  8 vCPUの速度・embedding併走時の応答性は本番で再計測する。
- **`memory.write_approval: false`、`skills.write_approval: true`**とする。WS11調査で、このゲートは
  組み込み`MEMORY.md`/`USER.md`への書き込みだけに作用し、Hindsightのretain/自動retainを止めないと確認した。
  無人時の保留レビューの手間を減らすため、組み込み記憶は即時書き込みとする。
  無人background_reviewのreplace/removeは上流の別ゲートで引き続き保留になる。
  誤った組み込み記憶は`/memory`で確認・削除し、Hindsight側はcustom抽出とSOULの方針で守る
  （LLMへの指示であり、誤記憶を完全に防ぐ保証ではない）。運用は[記憶の運用](../operations/hermes-agent.md#記憶の運用)を参照する。

いずれも2026-10-17のユーザー決定をrepoへ反映したもので、本番適用は未実施。他の未決事項は継続する。

## 2026-10-17補足: WS13計測とWS14資源配分

対話の快適性を優先するユーザー判断で、Agent VMを**12 vCPU / 24 GiB**とする（WS12の資源配分を更新）。
pve1はRyzen 9 5900X（12C/24T）で普段の負荷が低く、ユーザー観測ではメモリも約60 GB空いている。
embeddingを**4 CPU / 8 GiB**、rerankerを**6 CPU / 4 GiB**とし、rerankerのthreads・workersは各6を維持する。
CPU上限の合計10で他サービスとOSに2 CPU相当の余地を残す。上限は予約ではない。
memory-db 2 GiB、Hindsight 1 GiB、Hermes 1.5 GiB、CDP 128 MiBは据え置く。
全サービスのメモリ上限合計16.625 GiBに対し、OS・Docker・page cacheへ7.375 GiBを残す。
モデル事前取得は1 GiBでTEI起動前に完了する。本番適用・新配分の会話応答性の測定は未実施。

WS13のローカル計測要旨:

- embeddingは1 → 2 → 4 CPUでほぼ比例して速くなる（query p50 0.90 → 0.41 → 0.21秒）。
  swapなしの4096-token warm-upは約5.4〜5.8 GiBを使い、4 GiBではOOMKilled（137）となった。
  定常1.5〜1.9 GiB・負荷時ピーク2.74 GiBより起動スパイクが支配的なため、余裕を持って8 GiBにする。
- rerankerは6 / 8 / 10 CPUで20候補p50が約3.40 / 3.29 / 3.49秒とほぼ不変（10 CPU時のworkersは6）。
  Candle ModernBert backendのbatch size上限4で20候補が直列の小バッチになるため、CPU追加では3秒目標に届かない。
  swapなしのwarm-upピークは約2.8〜2.9 GiBで3 GiB上限に張り付き、threads/workers各10ではOOMとなったため4 GiBにする。
- 手元のRyzen 7 9800X3Dは本番5900Xより速い見込みで、絶対時間を本番性能と同一視しない。
  **WS7cの4.24秒も`itest/r2`のローカルstack（`http://reranker:8080`）の値であり、pve1実測ではない。**
  本番との速度差の割合は未計測。品質優先のMID 20 / HIGH 30と、3秒目標未達の受け入れは継続する。
- WS13bでretainがembeddingするのは日付・entity付きの抽出factと確認した。chunk本文は
  `retain_extraction_mode=chunks`（LLM providerがnoneのとき）だけである。4096は長いfact・observationの余裕として維持する。


### 2026-10-17補足: WS16 TEIのキュー対策と入力同時数

WS13cでcpu-1.8.3の`queue.rs`が`Full(..)`をpanicにして終了139となる既知問題を確認した。
embeddingも同じキューを通るため、両モデルを上流#726の対策入り**cpu-1.9.4**へ更新する。
registryで確認したindex digestは`sha256:2538ea1c9640d3763b15af668039d24172d063b42337b0c27796fc2be180c78d`。
amd64 manifestの`8419f533…`と区別し、従来どおりindexを固定する。モデルrevision・Candle backend・token上限・候補数は維持する。

新版は入力ごとのpermitを即時取得するため、旧C=16では20/30候補でも429になる。
固定Hindsightのembeddingは32入力/HTTP、既定共通8枠（CoalescingEmbedderの4枠はこの内側）で、recall queryも同じ枠を通る。
8同時のローカル負荷でqueryの待ち時間がclient既定timeoutの30秒を超えたため、
1 API worker・batch 32・同時数**2**（既定8）をComposeで明示し、embeddingのCを**128=2×32+64**にする。
2HTTPでも64入力ありCandleのbatch 4を供給でき、CPUの待ち行列を抑えられる。
rerankerは全recall共通同時数1・client batch最大32に対し**C=64=32+32**とする。
TEI clientは429/5xxを3回retryするが、使い切ればquery embeddingもrerankもrecallを失敗にし、rerankなしで続行しないため、
通常の送り方でpermitを枯渇させない値に合わせる。worker/replica数やbatch・同時数を変える際は再計算する。
Cを増やすとセマフォ・入力待ち行列とCommand用2Cバッファが増え、待機入力のメモリと待ち時間は増え得る。
推論batch 4と4096/2048-token上限は変わらない。`try_send(...).expect(...)`は残るため、すべての負荷でpanicしないという保証ではない。

`--max-batch-requests 1`はCandle CPUの4で上書きされ、batch 1という従来説明は誤りだった。
1.9.4のCPU warm-upも1 sequenceに限られるため、この指定とAnsible/env knobを削除する。
embeddingのthreadsは未設定と4をWS13bのquery/32-fact入力で比較し、4を採用する（Ansible knob）。
WS16のswapなし・本番同等上限で、warm-up/負荷peakはembedding 5.383 GiB / reranker 2.789 GiB。
最終embedding負荷（32件×2並列+query 0.5秒おき3分）とrerank20/30候補各60回は全200、429/panic/OOMなし。
20候補p50/p95 3.503/4.701秒はWS15の旧版3.492/4.718秒と同等。詳細はrunbookに記載する。本番適用はしていない。

### 2026-10-18補足: WS18 rerankerをORTへ変更

ユーザー判断により、初回本番構築前にrerankerだけをTEI **ONNX Runtime backend**へ切り替える。
embeddingはcpu-1.9.4のCandleを維持する。WS16のキュー対策・C=64・token2048・候補MID20/HIGH30も維持する。
この補足はWS12/WS14のCandle速度評価を更新するもので、過去の測定結果はそのまま残す。

WS15では同じ元重み・revision `bb46934ee9ed09f850b9fcff17501b3ef7ddb2b3`からFP32、opset17、
動的batch/sequence軸のONNXを自前exportし、6 CPUで20候補p50がCandle 3.49秒からORT約1.07秒へ短縮した。
通常のerf GELUでは24クエリ中1件の下位順位が入れ替わったため、hidden層と分類headをともに
`gelu_pytorch_tanh`にする。TEI Candleの`HiddenAct::Gelu`がtanh近似を使うためで、
元Transformers経路との数学的同一性を主張するものではない。互換版は24クエリ・連続96回で全順位一致、
最大スコア差2.21e-6だった。重み・tokenizerの変更、量子化、追加学習は行わない。

`files/services/images/tei-reranker-onnx/`のmulti-stage buildで、digest固定Python、CPU torch 2.10.0、
transformers 5.12.0、onnx 1.19.0と全推移依存のwheel hashを固定する。
`trust_remote_code=False`・safetensors限定で取得し、TEI cpu-1.9.4のindex digestを最終baseに使う。
ONNX・config・tokenizerは`/model`へ同梱し、safetensorsは最終imageへ入れないためCandleへfallbackできない。
ONNX SHA-256とexport条件は`/model/export.json`・`SHA256SUMS`とbuild logに残す。
モデルカードはApache-2.0を明記しており、ライセンス本文、元カード、出典と変換内容のNOTICEを同梱して再配布する。

6 CPU / 4 GiB、swap禁止、tokenization workers=6を採用する。ORTの実行batch上限は8。
TEI 1.9.4 `backends/ort/src/lib.rs:130`は`num_cpus::get()`でintra-op threadsを設定し、
Cargo.lockのnum_cpus 1.17.0はLinux cgroup v1/v2のquotaを読むため、quota 6で6 threadsになる。
`RAYON/OMP/MKL=6`は周辺プール用に残すが、ORTのintra-op制御と混同しない。
VMの12コアへ広がる前提でenvだけを設定する方法は採らない。

`tei-reranker-onnx-image.yml`はPRでbuildと一致検査のみ、mainでは同じ検証済みimageをGHCRへ公開する。
固定の架空入力24件×20候補について同じTEIの元safetensors/Candleと比較し、全順位一致かつsigmoidスコアの
最大絶対差1e-4以下を必須にする。CIは2 CPUで逐次起動し、同じscriptをローカル6 CPUの20/30候補試験にも使う。
2026-10-18時点で3つの自前image（Hermes・memory-db・reranker ONNX）は公開・digest転記済み。
既存の汎用gateはplaceholderを拒否し、
fixtureは新imageだけがplaceholderの場合にも拒否することを実行検査する。
Ansibleの事前取得はembeddingだけとし、rerankerのhost cache mount・model/revision envを削除する。

WS18のrepo image実ビルド後、同一6 CPU / 4g / swapなし / C64 / workers6で20/30候補を各60回検証した。
ORT p50/p95は20候補1.134/1.524秒、30候補1.657/2.259秒（同時のCandle基準3.513/4.759秒、4.962/6.951秒）。
120回の全順位一致、3,000スコアの最大差2.21e-6、429/panic/OOMなし。ORT起動peak 2.756 GiB、
全負荷後2.762 GiBで4gを維持する。本番と会話全体の応答性は別途確認する。
