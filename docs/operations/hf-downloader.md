# HF downloader運用

- 状態: ローカルのbrowser・queue・重み取得・停止/再投入を検証済み。公開imageのdigest反映待ち。実機での初回反映・NFS上の動作は未検証
- 対象: `hf-downloader` Compose project（`https://hf-downloader.kojigenba-srv.com`）
- 関連: [アプリ更新・promotion・rollback](application-lifecycle.md)、[NFS export契約](nfs-export.md)、
  [DGX Sparkストレージ運用](dgx-storage.md)

ブラウザのDagu UIからmodel / datasetをEnqueueし、AI共有へ1件ずつ取得する。

## 構成

```text
browser -> Caddy (TLS, admin_networksと同じ到達元制限)
        -> hf-downloader:8080 (Dagu UI / builtin認証)
Dagu scheduler -> hf-download queue (max_concurrency=1)
               -> Python helper -> ローカルflock -> hf download --local-dir
named volume: /var/lib/dagu (認証・履歴・ログ・キュー・HF_HOME・lock)
NFS ai: /srv/homelab/nfs/ai -> /data/ai (ro、marker確認)
  models   -> /data/ai/models   (rw)
  datasets -> /data/ai/datasets (rw)
```

Host portは公開しない。実行UID/GIDは`10002:10002`、capabilityなし、rootfsはread-only。
volumeはimageから`10002:10002 0700`を引き継ぐ。DAG・設定・helperはcheckoutからread-only bindする。
共通DAG設定もcheckoutの`base.yaml`を`/etc/dagu/base.yaml`へread-only bindする。
Daguは`2.22.4`、huggingface_hubは`2.3.0`。image tagは`2.22.4-hf2.3.0`。
Dagu coordinator、terminal、git sync、Cloud report / remote accessは無効。
`permissions.write_dags: false`でUIからDAGを変更できない。healthは`/api/v1/health`。

## 登録・確認・停止・再実行

1. 初回は反映直後に`/setup`を開き、管理者を作る。到達元制限は初期設定中も有効にする。
   認証情報はローカルvolumeに保存される。初期管理者作成以外のユーザー管理には上流のlicense条件がある。
2. ログイン後、`hf-download` DAGの起動フォームで**Enqueue**を選ぶ。Run IDは空欄のまま自動生成する。
3. 次のパラメータを入力しEnqueueする。パラメータを変えて何件でも追加できる。
4. queue画面でrunningが1件、残りがqueuedになることを確認する。run詳細の`download` stepでログを見る。
5. 実行中runはStopで停止する。待機中runの取り消しはDequeueを使う。
6. 失敗・停止runは**DAG全体のRetry**を使う。同じRun IDで再度queueへ入る。
   パラメータを変えたいときは新しくEnqueueする。

上記のbrowser操作は試験用Caddy越しのheadless Chromiumで確認済み。実機での受け入れは未検証。

| パラメータ | 既定値 | 意味 |
| --- | --- | --- |
| `repo_id` | 必須 | `namespace/name`。各部分1〜96文字。英数字・`_`・`-`・`.`のみ。`--`、`..`、先頭末尾の`-`/`.`、末尾`.git`は禁止 |
| `repo_type` | `model` | `model` / `dataset` |
| `revision` | `main` | branch / tag / commit / `refs/pr/N`。空欄もmain。128文字以内、英数字・`_`・`.`・`/`・`-`。先頭`-`、`--`、`..`、`//`、先頭末尾`/`は禁止。`--`を含むbranchはcommit SHAを指定 |
| `include` | 空 | カンマ区切りの取得glob。例`*.json,*.safetensors` |
| `exclude` | 空 | カンマ区切りの除外glob |
| `max_workers` | `1` | 1〜4。1ジョブ内の並列取得数。HDD向けには1を維持 |

globは前後の空白を除去する。各256文字、32件、入力全体4096文字まで。
先頭`-`/`/`、`..` segment、制御文字、空の要素は禁止。保存ルートや実行ファイルはUIで指定できない。

例:

- GGUF: `repo_id=unsloth/Qwen3-8B-GGUF`、`include=*Q4_K_M*`。量子化名がファイル直下でも
  subdirectory名でも一致する。大きいrepoは更新時にCLIの`--dry-run`で対象を先に確認する。
- dataset: `repo_id=lhoestq/demo1`、`repo_type=dataset`、`include=*.csv`。
- revision指定: `repo_id=org/repo`、`revision=refs/pr/42`なら
  `models/huggingface/org/repo@refs--pr--42/`に保存する。

## Startを使わない理由と排他

Startはqueueを通らないため、ブラウザ経由では403になる。CaddyはGET系の閲覧と、認証・Enqueue・
停止・Dequeue・runのRetryだけをDaguへ直接通す。start-sync、任意spec実行/Enqueue、edit-retry、
reschedule等の更新API、`/mcp`、terminal、`/api/v1`以外のAPIも拒否する。

v2.22.4ではDAG全体Retryとステップ単位Retryが同じURLを使う。CaddyはJSON本文を検査しないため、
ステップ単位Retryも通る。Enqueue時のqueueなどの上書きもDaguへ渡る。これらの操作は名前付きqueueの
順番や同時実行枠を迂回し得るため、通常はEnqueueの既定queueとDAG全体Retryを使う。

helperはvolume内の共通flockを取得し、`hf`終了まで保持する。ステップ単位Retryやqueue上書き、
backendへの直接Startがあっても、`Waiting for download lock`で待ち、hfが2本同時に走ることはない。
Daguの表示上はlock待ちのrunもrunningになり得る。lockの取得順はqueueの投入順を保証しない。
上流更新時はUI clientとserver routeの両方を確認する。

## 保存先・権限・token

modelは`models/huggingface/<namespace>/<name>/`、datasetは`datasets/huggingface/<namespace>/<name>/`。
main以外は`<name>@<revision>`に分離し、revision内の`/`は`--`へ置き換える。
markerが`ai`で、aiルートと対象subtreeが別mountとして見え、filesystemがnfs/nfs4でなければ開始しない。
`create_host_path: false`でmodels / datasetsが無い場合の自動作成を禁止する。
Linux Docker（DinD）で欠落pathの作成拒否を確認済み。Docker Desktopでは欠落pathが自動作成されたため、
Desktopだけではこの契約を検証できない。
保存先のsymlinkとルート外への逸脱も拒否する。

helperは共通lockを持ったまま、hf起動前と子プロセス回収後（成功・失敗・停止）に、
その保存先の`.cache/huggingface/download/`配下の通常file `*.incomplete`だけを削除する。
symlinkはたどらず、`.metadata`・`.lock`や他の保存先は触らない。削除件数とbytesを1行でログへ出し、
削除できなかった場合は警告だけで取得を継続する。directoryが無ければ何もしない。

hf子プロセスだけumask `0000`。新規directoryは0777、fileは0666、所有者は10002:10002となる。
既存fileのmodeを一括変更しない。HF_HOME（xet cache含む）はローカルvolumeへ置き、NFSには
local-dir本体とその`.cache/huggingface/`だけを書く。helperはargvと保存先をログに出す。

HF tokenは任意。運用者が暗号化runtime bundleへ`hf_downloader.token`を追加し、通常のsecret更新手順を使う。
Ansibleが`/etc/homelab/secrets/hf-downloader/hf-token`（10002:10002、0400）を作る。
directoryは10002:10002、0500で、directory全体をro bindする。bundleに値が無ければ空fileになる。
空fileなら匿名取得する。tokenをDaguのparams・argv・ログへ入力しない。
`HF_TOKEN_PATH`で読むためtokenの値を環境変数へ展開しない。bundle追加を含むsecret変更は
**全projectを再作成する**ので、実行中ジョブを終えてから行う。

## 初回反映（実機では未検証）

1. imageだけのPRを作る。Dockerfile、requirements、公開workflow、Dependabot設定を含める。
   PRのbuild成功を確認してmergeし、GHCRへの公開とjob summaryの実在するdigestを確認する。
   認証情報を持たない別環境で`docker pull ghcr.io/koji-genba/dagu-hf@<確認したdigest>`を実行し、
   匿名pullが成功することを確認する（この公開確認手順は未検証）。privateならGitHubのpackage設定で
   `ghcr.io/koji-genba/dagu-hf`をpublicにする。repoにはvisibilityを設定する仕組みが無い。
2. 別のCompose/連携PRにそのdigestを反映する。現在のtag参照とTODOを残した状態ではmergeしない。
3. Compose PRをmergeし、reconcileでApps VMのcheckoutを進める。
4. 運用者の承認を得て通常の`make ansible-apply`を行い、新projectのhelper、token directory、
   DNS等を反映する。全projectが再作成され、実行中の取得も停止する。
5. `/setup`で管理者を作り、下の受け入れ確認を行う。先行する監視設定は起動までdownになり得る。

## 更新

Dagu / huggingface_hubを上げるときもimage PRとdigest反映PRを分ける。
[image README](../../files/services/images/dagu-hf/README.md)の手順で同じUbuntu/Python版のcontainer内で
推移依存のwheel hashを再生成する。Dagu baseはtagだけでなくregistryから取得したdigestも更新する。
Dockerfile label、workflow tag、本書の版を揃える。

Dagu更新ではconfig/DAG schema、UIのStart / Enqueue / Retry client、serverの全API versionとrouteを確認し、
Caddyの許可ルールを見直す。ローカルで認証・権限・3件queue・直接起動時のflock・停止・Retry・
実ダウンロードを再確認する。公開後にComposeのdigestを更新し、静かな時間帯にreconcileする。
helper/DAG/config変更もreconcileでcontainer再作成になる。image用directoryだけの変更では再作成しない。
公開後にComposeのdigestを変更して初めて新しいimageへ切り替わり、取得を中断する。

## 受け入れ確認（実機では未検証）

1. healthが200、未認証のDAG一覧が401、ログイン後に`hf-download`だけが表示されることを確認する。
2. `hf-internal-testing/tiny-random-bert`を`include=config.json`でEnqueueし、modelsの正しいpathへ保存されることを確認する。
3. 3件を続けて投入し、running 1件・残りqueuedになることを確認する。
4. fileの10002:10002 / 0666、directoryの0777を確認する。再投入後に完了fileのmtimeが不変であることを確認する。
5. 存在しないrepoを投入し、失敗ログを読んでDAG全体Retryがqueueへ戻ることを確認する。
6. 実行中runをStopし、次のrunが進むことを確認する。Caddy経由のStartが403になり、step Retryもlockで直列化されることを確認する。
7. GatusのhealthとHomepageリンクを確認する。

## ローカル検証（2026-10-26〜27）

Docker Desktop / WSL2の偽ai bindを使用し、mount種別だけ試験用overrideでext4を許可した。
本番Composeのnfs/nfs4、DNS設定は変更していない。

| 項目 | 結果 |
| --- | --- |
| image / DAG | Dagu 2.22.4、hf 2.3.0。validate成功、DAG errors空。フォームに型・enum・必須指定が表示される |
| browser | Playwright Python v1.58.0-nobleのChromiumから公式Caddy 2.11.2のHTTP site経由でsetup、login、3件Enqueue、queue確認、ログ閲覧、Stop、Retry、dequeue、logoutを確認 |
| queue | browserでrunning 1、queued 2を確認。mockの開始/終了記録でも取得の重複なし |
| Caddy | Startは403で、フォームに`Failed to start DAG execution.`と表示。通常操作のSSE購読更新に必要な`POST /api/v1/events/stream/topics`も許可。dequeueはv2.22.4ではGET。通常操作で必要な変更系APIの403は解消 |
| safetensors | `Qwen/Qwen2.5-0.5B-Instruct`のREADME/configと988,097,824 bytesのmodelを取得。途中Stop後に同じparamsを再Enqueueして完了。READMEと完了済みmodelのmtimeは再投入後も不変 |
| 迂回起動 | Caddy経由のstep Retry / queue overrideとbackend直接Startを受け付け、lock待機を確認。mock全区間でhf最大同時実行数1、終了後の残存プロセスなし |
| container停止 | 実行中hf PIDを確認してCompose stop。SIGTERM転送とhelperの`Download stopped`を確認、実取得は約0.53秒、最終90秒grace設定のmockは約0.43秒でexit 0、OOMなし |
| 一時file清掃 | SmolLM2-135M-Instructの269,060,552 bytesの重みで確認。Stop直後に`.incomplete`は0件、1件40,292,352 bytesの削除をログで確認。人工的な2件13 bytesも次の起動前に削除され、再Enqueueで完了。metadata / lock / 対象外fileは保持 |
| GGUF | 複数量子化を含む`bartowski/SmolLM2-135M-Instruct-GGUF`へ`include=*Q4_K_M*`。105,454,432 bytesの`SmolLM2-135M-Instruct-Q4_K_M.gguf`だけを実取得。GGUF magicも確認 |
| 所有者 / mode | 空tokenで取得。container内で10002:10002、file 0666 / directory 0777。safetensors headerも読み取り確認 |
| bind欠落 | privileged / 2GBの`docker:29.8.0-dind`内で同じlong syntaxを使用。createとupが欠落modelsをexit 1で拒否し、自動作成なし。directory作成後のcontrolは成功 |
| 事前拒否・失敗 | marker欠落/誤り、別mountでないpathをhelperが拒否。実在しないrepoのfailed、stderr閲覧、全体Retryでqueuedを確認 |

作業端末ではAdGuardのURL shortenerリストが`*.hf.co`をNXDOMAINにするため、試験用overrideだけに
`dns: [1.1.1.1, 8.8.8.8]`を指定した。通常設定のXetで重み取得が成功し、HTTP fallbackは使っていない。
本番Apps VMは既存のupstream DNSを使う。実機での名前解決・取得は未検証。
初回の実取得試験の受信量は停止前1.31GB、再起動後約1.46GBで、合計3GB以内。
清掃追加試験の受信量は504,488,197 bytesで1.5GB以内。いずれも取得物は試験後に削除済み。

## 制約・トラブルシュート

- container再作成・image更新・secret更新では実行中downloadが止まる。停止は最大30秒のhf終了待ち、
  DAG cleanup 45秒。`signal_handling.enable_propagation: true`でservice停止時にも実行中DAGへSIGTERMを転送する。
  Compose stop graceはDAG cleanup 45秒と上流service終了待ち30秒を収める90秒。
  DAGとstepのtimeoutはともに7日、履歴保持は30日。
- 途中fileはバイト単位では再開しない。再実行では完了済みfileとlocal-dirのmetadataを再利用する。
  通常の停止後はhelperが一時fileを清掃する。containerのSIGKILLやhost障害などで清掃が走らなかった場合も、
  次に同じ保存先を取得するときに、lock取得後・hf起動前に古い`.incomplete`を削除する。
  `Incomplete cleanup warning`が出る場合は、その保存先の権限・mountを確認する。
  branchの参照先が変われば更新対象fileは取得される。
- lock取得後・hf起動直前に、保存先配下全体（`.cache/huggingface/`を含む）のsymlinkと特殊fileを拒否する。
  終了後にも検査し、発見時は警告する。実行中に共有側から差し込まれる競合までは防げないため、
  ai共有に書ける機器を信頼する前提とする。
- volumeにqueue情報は残るが、再作成後のqueue復元・実行中runの自動再開は保証しない。履歴を確認して再投入する。
- marker / mountエラー: NFSとmodels / datasetsの存在を運用者が確認する。pathを自動作成して回避しない。
- `Waiting for download lock`: 別runが取得中。直接Startを送ったclientが無いか履歴を確認し、必要ならrunをStopする。
  lock fileの削除はしない（別inodeで排他が分かれる）。
- 401/403: builtin login、到達元制限、Enqueue / DAG全体Retryの選択を確認する。Startの403は仕様。
- private/gated repoの401/403: tokenの有無とHub側の利用承認を確認する。tokenをログへ表示しない。
- 起動時permissionエラー: named volumeの所有者を確認する。volume削除は管理者情報・履歴も失う。
- health成功はNFSの健全性を保証しない。download開始前のhelper検査と既存mount guardが別に必要。
- 事前検査で拒否したrunは`Download refused: <理由>`をstderrへ出し、hfを起動しない（`Executing:`行が無い）。UIのstepログはstderr側を開いて理由を確認する。

ローカル試験でmetadataだけ取れて本体の取得が止まる場合はDNSを確認する。homelabのAdGuardは
HaGeZi URL Shortenerリストの`||hf.co^`により`*.hf.co`をNXDOMAINにする。
Xetの`cas-server.xethub.hf.co`・`transfer.xethub.hf.co`、`cdn-lfs.hf.co`なども対象になる。
Apps VMはhost resolverに公開DNS（`apps_upstream_dns_servers`）を使いtailnet DNSも受けないため影響しない。
AdGuardをDNSに使う端末での試験では、試験用overrideだけに`dns: [1.1.1.1, 8.8.8.8]`を指定する。
この変更では本番ComposeのDNSやAdGuard設定は変更しない。
