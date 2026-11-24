# Hermes Agent 運用（バックアップ・リストア・エクスポート・記憶再構築・健康確認）

- 対象: Hermes Agent VM（`agent`、`192.168.10.104`）
- 実装: Ansible role `agent_ops`（`files/infrastructure/ansible/agent/roles/agent_ops`）
- 関連: [CODEBASE_MAP](../CODEBASE_MAP.md)、[NFS export契約](nfs-export.md)

このリポジトリは適用・実行を自動化するが、NFS export の新設や本番リストアは運用者が明示的に
実行する。`agent_ops` は `agent_stack` の後に適用され、Compose プロジェクト・生成済みシークレット・
Runner SSH鍵が存在する前提で動く。

## 1. 配置されるもの

role が Agent VM に配置するヘルパー（`/usr/local/sbin`、root 0755）:

| ヘルパー | 用途 |
| --- | --- |
| `homelab-agent-backup` | 日次バックアップ（`homelab-agent-backup.timer` が毎日 03:30、ホストのローカル時刻） |
| `homelab-agent-restore` | バックアップセットの本番／`--scratch` リストア |
| `homelab-agent-export` | セッション・記憶の portable エクスポート |
| `homelab-agent-rebuild-memory` | Hermes セッションから記憶を再構築 |
| `homelab-agent-rebuild-memory.py` | 上記のコンテナ内ワーカー |
| `homelab-agent-healthcheck` | 5分間隔の健康確認（`homelab-agent-healthcheck.timer`） |

状態・作業ディレクトリは `/var/lib/homelab-agent`（状態ファイル）と `/srv/agent/{exports,restore-scratch,restore-safety,rebuild,tmp}`。

## 2. バックアップ

日次で `/mnt/agent-backups`（pve1 の NFS export）配下に `<UTC タイムスタンプ>/` のセットを作る。
セットは `.incomplete-<ts>` として書き、全工程成功時のみ `<ts>` に rename する。途中で失敗した
セットはバックアップとして扱わない。

セットの中身（**すべて age 暗号化**、`.age`）:

| ファイル | 内容 |
| --- | --- |
| `hermes-backup.zip.age` | `hermes backup`（SQLite 整合。agent 自身の `.env`/`auth.json` を含むため暗号化必須） |
| `hindsight-postgres.dump.age` | Hindsight PostgreSQL の `pg_dump -Fc` |
| `agent-config.tar.gz.age` | `compose.env`・`config.yaml`・Hindsight `config.json`・`SOUL.md`（**非秘密のみ**） |
| `runner-work.tar.gz.age` | Runner の作業ツリー（キャッシュ・マウント直下の `./lost+found`・`./share` を除外、SSH 経由でストリーム） |
| `METADATA.txt` / `MANIFEST.txt` / `SHA256SUMS` | 非秘密のメタデータと破損検知用チェックサム |

### Hermes 共有の除外（2026-11-05反映済み）

`agent_ops_runner_excludes` に `./share` を指定する（末尾 slash 無し）。
Runner の `tar -C /srv/agent-work ... .` が NFS の directory 自体を除外し、中へ降りない。
`--one-file-system` も付けるが、これだけでは automount へのアクセス防止にならないため明示除外を維持する。
ローカル fixture で非 mount の share directory も archive に入らないことを確認する。
2026-11-05 10:23 JSTの`make ansible-apply-agent`で反映し、Agentのbackup除外設定に
`./share`が含まれることを確認した。成果物の検査など今回の確認に含まれない範囲は
[共有運用の未検証事項](hermes-share.md#未検証の項目)を参照する。
共有の snapshot・backup は無く、復旧は空の dataset と権限・marker の再作成で行う。
共有から他のローカル directory へコピーしたファイルはこの除外では消えない。

### 暗号化

- 宛先は `group_vars/agent.yml` の `agent_backup_age_recipients`（age 公開鍵）。
  SOPS/state backup と同じ homelab 復旧用 age key を設定済み。
- 復号用の秘密鍵（identity）は **この VM にも git にも置かない**。本リポジトリの復旧用 age key を使う。
- 未設定（空）の間はバックアップは **fail closed**（平文を書かずに失敗する）。

### マウントガード

バックアップは `/mnt/agent-backups` が次の条件を満たさない限り失敗する（ローカルディスクへの
誤書き込みを防ぐ）:

- `findmnt` で source が `192.168.10.11:/mnt/tank-gen2/data/agent-backups`、fstype が `nfs4`
- export marker `.homelab-export-agent-backups` が存在し内容が `agent-backups`

### 世代管理

完成セットのみを対象に、直近 `agent_ops_backup_daily_keep`（既定 14）個と、週次
（`agent_ops_backup_weekly_dow`、既定 7=日曜, UTC）の直近 `agent_ops_backup_weekly_keep`（既定 8）個を保持する。
`.incomplete-*` は作成 1 日超で削除する。

### 通知

`/etc/homelab/secrets/agent-monitoring.env` の `OPERATOR_WEBHOOK_URL` に失敗を通知、
`DEADMAN_PING_URL` に成功 ping を送る（任意）。URL はログに出力しない。

## 3. リストア

```
homelab-agent-restore <set> --identity <age-identity-file> [--scratch] [--yes]
```

`<set>` はセット名（`20260101T033000Z`）またはフルパス。`--identity` は必須で、VMに常設しない。
復元時だけ運用者がtmpfs等へ一時提供し、終了後に撤去する。
ADR-0017以後、この鍵をAgent VMへ置く間はProxmox/Tailscaleのoperator認証情報も読める状態になる。
実行前に `SHA256SUMS` を検証し、`mktemp` に復号（終了時に平文を削除）する。

### 本番リストア（`--yes` 必須、破壊的）

1. `--yes`と起動・健康確認helperの存在を確認し、復号したHermes zipとSQLiteの整合性を検査する。
2. `hermes`/`hindsight`を停止して書き込みを止める。
3. `/srv/agent/restore-safety/<ts>/`へ`pg_dump`とHermesデータtarを保存する。
   tarはexit 1も失敗とし、安全コピーができなければDBを変更しない。安全コピーはroot専用の平文なので、
   復旧確認後に運用者が暗号化・保管または削除する。
4. Hindsight DBを`DROP ... WITH (FORCE)` → `CREATE`し、container内の`POSTGRES_USER`で
   `pg_restore --exit-on-error -U "$POSTGRES_USER" --no-owner --role "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists`。
5. `hermes import --force`。importは既存ファイルへの上書きで、バックアップに無い追加ファイルを削除しない。
6. `homelab-agent-compose-up`で再起動する。健康確認は最大6回（10秒間隔）の通知無し検査後、
   通常の`homelab-agent-healthcheck`で最終確認・通知する。

失敗時に自動rollbackはしない。停止後の失敗ではサービスが停止したままの場合がある。journalと安全コピーを
確認して復元を再実行するか、安全コピーを戻してから起動helperを実行する。復号した作業コピーと
`hermes/.restore/restore.zip`は成功・失敗とも終了時に削除する（SIGKILL・電源断は除く）。

**helperが自動復元するのはHermesとHindsight DBのみ**。`agent-config.tar.gz.age`と
`runner-work.tar.gz.age`も検証・復号するが、自動展開しない。VM再作成時は先にGit/AnsibleとSOPSから
設定・secret・専用SSH鍵を再配置する。旧設定が必要なら管理端末の非公開作業領域でconfig archiveを復号し、
Gitの現行設定との差分を確認して反映する。Runner作業は同様にarchiveを復号・内容確認し、Runnerの
`/srv/agent-work`へ`hermes-runner`所有で戻す。`.git`・venv・キャッシュ等は取得対象外なので別途clone・再生成する。
この手動部分を含む本番DRは未検証。scratchの停止・削除に失敗した場合は、そのdata/overrideを残して
手動cleanupを促す。稼働したままのDBの保存先は削除しない。

### イメージ更新と旧版への切り戻し

Hindsightのイメージを更新して反映するときは、反映前に稼働中の旧版で`homelab-agent-backup`を実行し、
更新前のバックアップセットを識別して保持する。Hindsightは起動時にDB migrationを自動で実行し、
逆migrationでは元に戻せない変更もある（例: 1.1.0はダミーの日付をNULLに補正する）。旧版へ戻す場合は、
旧版のCompose定義を起動させずに配置してから、更新前のセットをrestoreする。restore helperは配置済みの
Compose定義で再起動し、Composeや設定は復元しないため、イメージを戻す操作とDBの復元の順序に注意する。
通常のAnsibleの反映は途中でスタックを起動するので、旧版に戻す前処理には使わない。

### 試験リストア（`--scratch`、本番無変更）

本番スタックを止めずに別プロジェクト `<project>-restore-<ts>` を一時起動し、スクラッチ DB に
復元して検証後に破棄する。override で memory-db をスクラッチデータディレクトリへ向け、Hindsight は
本番の **ステートレスな TEI サーバ**（embedding/reranker）を本番ネットワーク経由で共有する。
scratch DBはimage初期化後に明示再作成し、Hindsightはprivate networkの専用aliasへ接続する。
検証は Hindsight `stats`（`total_nodes > 0`）と固定日本語クエリの非空 recall、Hermes アーカイブの
zip 整合と `state.db` の `PRAGMA integrity_check`。事前に本番スタック（ネットワークと TEI）が
起動していること。`!reset`/`!override` を使うため Compose 2.24.4 以上が必要。

## 4. エクスポート

```
homelab-agent-export
```

`/srv/agent/exports/<ts>/` に次を出力する（非破壊）:

- `sessions.jsonl` — Hermes セッション（`hermes sessions export --format jsonl`）
- `hindsight-bank.zip` — `hindsight-admin export-bank`（ネイティブ、再 import 可能）
- `memories.jsonl` / `documents.jsonl` — Hindsight HTTP API から読む **provider 非依存** JSONL
- `METADATA.txt` / `SHA256SUMS`

read-only containerのtmpfs `/tmp` にあるbank archiveは `docker cp` で取得できないため、helperは
`compose exec -T hindsight cat` でホスト側の一時ファイルへ流し、非空確認後にrenameする。

`agent_ops_export_encrypt: true`のとき、backupと同じsource/fstype/marker検査を通したNFSへ
セット全体のage暗号化コピーを書く。検査失敗時は失敗する。ローカル出力はroot専用の平文で、
`.incomplete-<ts>`から全工程成功時だけrenameする。raw document取得失敗も成功扱いしない。
`memories.jsonl`は`occurred_start`/`occurred_end`/`mentioned_at`を保持する。
稼働中のページング取得なので、同時更新に対するトランザクション整合性は保証しない。完全復旧にはbackupを使う。

### 完全 DR と bank 移行の方針

- **完全 DR の標準は `pg_dump -Fc`**（バックアップの `hindsight-postgres.dump.age`）。
  `hindsight-admin backup/restore` はテーブル単位のバイナリ COPY ダンプでスキーマ版に結合するため、
  バージョン跨ぎの復旧には使わない。
- **bank の移行・監査には `export-bank` + provider 非依存 JSONL** を使う。

## 5. 記憶の再構築

```
homelab-agent-rebuild-memory --from <sessions.jsonl> [--bank <id>] [--rate-limit <sec>] [--dry-run] [--fresh]
```

HermesセッションJSONLをHindsightへretainする。別providerへの投入には、そのprovider用の変換・投入処理が別途必要。

- 1セッションを1item・1リクエストとして送る。`document_id`はsession id、`update_mode="replace"`を明示し、
  同じ本文の再投入によるdocument重複を防ぐ。元のbankを保全するため、通常は新しいbankを指定して検証する。
  bank idは`[A-Za-z0-9][A-Za-z0-9_.-]*`に制限する（進捗pathの逸脱を防ぐ）。
- 新しいbankにも、投入前に`homelab-agent-bank-config.py <bank>`で本番と同じ管理方針（custom抽出等）を適用する。
  既存bankもこの方針へ合わせる。方針が異なるbankへ投入したい場合はhelperを流用しない。
- `content`はpluginの話者ラベルに合わせた平坦なJSON配列。要素は
  `{"role":"user"|"assistant","content":"User: …"|"Assistant: …","timestamp":…}`。
  `context="conversation between Hermes Agent and the User"`、`observation_scopes="shared"`、
  `session:<id>`と必要なら`parent:<id>`のtags、session属性のmetadataを付ける。
- exportから各userの次に続く最後のassistant本文（tool_callsを持たないもの）を選ぶ。
  system/tool・tool-callのassistantは除外し、assistantが無いuserターンは落とす。
  plugin自体はHermesから完成したuser/final responseの組を受け取り、履歴から最後のassistantを探すわけではない。
  exportには中断・sync境界が無いため、連続したassistant本文や中断した本文の厳密な再現は保証しない。
  元の全メッセージは`sessions.jsonl`に残る。
- ターン時刻はuserのexport timestamp、無ければ`started_at`（互換入力は`created_at`/`start_time`）。
  最終活動時刻`last_activity_at`は代用しない。Hermes exportのepoch秒は絶対時刻として読み、
  `agent_stack_timezone`（既定`Asia/Tokyo`、Hermes config/TZと同じ）へ変換する。
  offsetの無いISO日時もこの設定時刻として扱う。user/assistantには同一時刻、itemには先頭ターン時刻を付け、
  UTCの監査時刻`retained_at`とは分ける。開始時刻fallbackは長期sessionの各ターン時刻を復元するものではない。
- 時刻の無いターンは実投入を失敗させる。`--allow-missing-timestamp`を明示した場合だけ実行時刻を使う。
  不正JSONやsession id欠落も失敗とし、黙って飛ばさない。
- `async:true`のoperation idを保存して完了を待つ。中断後は同じoperationの待機を再開し、完了後だけlineを進める。
  `failed`/`cancelled`は停止。`--timeout`は既定1800秒、`--poll-interval`は既定5秒、
  `--rate-limit`はセッション間の待ち（既定0.5秒）で、いずれもwrapperへ渡せる。

進捗は`/srv/agent/rebuild/<bank>-<sha16>/progress.json`に保存する。bank・入力SHA-256・時刻設定・
処理版が一致すると再開する。古い処理版のcheckpointは`--fresh`で作り直す。
`--fresh`はcheckpointを捨てるだけでbankを消さない。ただしpending operationが残る間は拒否するため、
まず通常resumeで完了・失敗を確定する。POST応答を受け取る直前の通信断・電源断はoperation idを保存できず、
再投入し得る。完全なexactly-once処理ではないので、bankのoperationsを確認してから再開する。

ワーカーの実行uid/gidは稼働中のHindsightから取得し、進捗は0700、staged `input.jsonl`は0600とする。
元exportがroot 0600でも投入できる。staged copyは成功・失敗とも終了時に削除し、進捗は保持する。
rebuild同士は排他制御する。`--dry-run`は投入・bank設定・checkpoint更新をせず、残りセッション/ターン数・
最大itemサイズ・時刻欠落数を表示する（`--fresh`併用でも既存checkpointは消さない）。

旧WS7dの試験値（架空データ）: 15ターン/4.6 KBの1セッションで初回約25秒・GLM 4回。
WS8の時刻・再開・bank方針修正はネットワーク不要fixtureで確認した。本番規模の所要時間と抽出品質は
[会話exportの本番投入の記録](#本番投入の記録2026-11-2324-jst)を参照。

### Claude.ai / ChatGPT の会話export

作業端末で各サービスの `conversations.json` を個別に変換する。変換はPython 3標準ライブラリのみで動作し、
通信しない。元exportと変換後のJSONLは個人データとしてrepo外に保管する。集計reportにも会話IDが入る。

```sh
python3 -I scripts/hermes-import-chat-exports.py --source chatgpt \
  --input /path/to/private/chatgpt/conversations.json \
  --output /path/to/private/chatgpt-sessions.jsonl \
  --report /path/to/private/chatgpt-report.json \
  --sample 10 --seed 42
```

Claude.aiでは `--source claude` を指定する。予備検証は `--sample N --seed S`、元の会話IDを
1行に1件書いた `--ids-file FILE`、または作成日（UTC、両端を含む）の `--since YYYY-MM-DD` /
`--until YYYY-MM-DD` で絞れる。サンプルは絞り込み後、ターン変換前に選ぶ。全件の変換ではこれらの指定を外す。

- ChatGPTは現在の枝、Claude.aiは親リンクがあれば末尾メッセージの枝をたどる。親がexport内に無ければそこで止める
  （Claude.aiのルートを示す固定UUIDを含む）。枝から外れた件数はreportに記録する。
  可視のuser/assistant本文を使い、連続するassistant本文は結合する。未回答や、userにも会話開始にも時刻のないターンは除外する。
- 添付は短い表示に置き換える。Claude.aiの抽出済み添付本文は `--include-attachment-text` 指定時だけ含める。
  ChatGPTの記憶対象外の会話は `--include-do-not-remember` 指定時だけ含める。既知の形式の認証情報は
  本文・タイトルなどから常に伏せる。reportには本文・タイトルを出さず、除外理由、文字数、伏せた箇所の件数などを出す。
- `--assistant-max-chars N` は結合済みの返答の先頭と末尾を省略マーカー付きで残す。
  `--split-max-chars N` は本文の合計文字数を目安にターン境界で分ける。単独のターンが上限を超える場合は
  そのまま出力し、reportに数える。分割した部分は `-p01` からの枝番を持ち、それぞれ独立したdocumentとしてretainされる。
  `parent:<id>` は元会話を示すtag。再投入時は同じ分割設定を使う。分割設定を変えると旧IDのdocumentが残り得る。

ChatGPTの添付を含めるには `--attachments-dir DIR` に展開済みexportのディレクトリを指定する。
`conversation_asset_file_names.json` があれば元のファイル名を表示する。添付本文は
`--include-attachment-text` 指定時だけ、ユーザーの発話に追記する。`--attachment-text-dir DIR` に
`<添付ID>.txt` として用意したUTF-8本文（PDFから別途抽出した本文など）を優先し、次にexport内の
`<添付ID>.dat` がUTF-8のテキストなら使う。画像・PDFのバイナリや本文を利用できない添付はファイル名だけ表示する。
1ファイルの読込上限は4 MiB。本文は伏字処理の後に `--attachment-max-chars N`（既定64,000文字）で
先頭と末尾を残して短縮する。reportの `attachments` は出力したターンの `metadata.attachments` について
本文あり（`inlined`）、名前のみ（`placeholder_only`）、本文を短縮した内数（`truncated`）を集計する。

### Claude.ai Projects のexport

```sh
python3 -I scripts/hermes-import-chat-exports.py --source claude-projects \
  --input /path/to/private/claude-export \
  --output /path/to/private/claude-projects.jsonl \
  --report /path/to/private/claude-projects-report.json
```

展開先の `projects/*.json` を読む。`projects` ディレクトリ自体も指定できる。空でない概要・プロンプトテンプレート・
資料本文をユーザー提供の資料として取り込み、資料ごとの作成時刻を使う（欠落時はプロジェクトの作成時刻）。
通常は1プロジェクトを `import-claude-project-<uuid>` とし、`--split-max-chars` 指定時は資料の境界で分割できる。
抽出対象の発話はユーザーの資料のみとし、helperはこの出典に限りassistant発話が無くてもretainする。
reportの `conversations_*` はこのモードではプロジェクトの集計。

変換したJSONLをAgent VMの非公開パスに置き、`homelab-agent-rebuild-memory --from <sessions.jsonl> --bank <検証用bank> --dry-run`
で形状を確認する。helperは `import-claude-…` / `import-claude-project-…` / `import-chatgpt-…` と `source` の組から出典を判定し、
サービス別の `context`、`source:<source>` のtag、元のタイトル・作成時刻を付ける。投入時も引数は既存のものを使う。

### 本番投入の記録（2026-11-23〜24 JST）

ユーザーの判断で、Claude.ai・ChatGPTの全会話を本番bank `personal` に投入した。雑談も含め、本文の短縮はしていない。
センシティブな話題も除外していない（Hermes上で同じ会話をしていれば記録されていた内容、という判断）。

- 入力: Claude.ai 258、ChatGPT 83、Claude.ai Projects 4の計345 document（5,395,880文字、11.0 MB）。
  作成順（2025-06-26〜2026-11-01）に1ファイルへ連結した。変換オプションは `--include-attachment-text` と
  `--split-max-chars 100000` で、ChatGPTには `--attachments-dir` / `--attachment-text-dir` も指定した。
  上限を超えた単独ターンは1件（約23万文字、CMakeのログを添付したもの）で、抽出された事実はビルド実施の1件程度だった。
- 事前準備: 本番へ反映する前に、手動バックアップを2回取った（`20261123T061935Z`、`20261123T112829Z`）。
  組み込み記憶（`USER.md` / `MEMORY.md`）の旧版は `/srv/agent/memory-pre-import-20261123T082443Z/` に退避した。
  #246（変換・投入helper）と #247（主語・時制の抽出指示）はそれぞれ `make ansible-apply-agent` で反映した。
- 試験投入（試験用bankは確認後に削除）: 並列度1で117k文字を投入し、retainに862秒かかった。
  並列度4では142k文字で591秒だった。この試験で第三者の意見が本人の意見に、予定が完了済みに変わる誤りが見つかり、
  #247で直したあと再試験で解消を確認した。
- 本投入: DGXの枠を1つ空けておくため、並列度を3にした。`compose.env` の `HINDSIGHT_LLM_MAX_CONCURRENT` を
  一時的に書き換えてHindsightだけを再作成し、終了後は `make ansible-apply-agent` で1に戻した。
  投入にかかったのは20:29〜03:09（24,009秒、平均約225文字/秒）で、失敗は0件だった。
  その後の統合処理（待ち最大約2,800件）は12:21に終わり、1時間あたり約300件のペースだった。
  完了時点で world 4,881、observation 4,557、document 554。
- 律速: 実際に同時に走る生成は2〜3本で、並列度の上限まではほぼ使われない。helperは1 documentずつ完了を待つ。
  documentの中でもsub-batchは既定どおり1つずつ処理される。統合処理は同じtag群のbatchを順番に処理する
  （`consolidator.py` の `_process_tag_group`）。並列度を上げても、統合処理の時間は大きくは縮まない。
- 抜き取り確認: 予定・趣味・家族・機材の4つの話題で検索した。予定は予定のまま記録され、家族の意見は家族を主語にしていた。
  ただし本人の呼び方は「ユーザー」「s-satoさん」と実名とで揺れていた。後から変わった事実の旧状態（例: 以前はK8sを使っていた）も
  その時点の事実として残る。こうした古い状態は、最新の状態を組み込み記憶とGitHubのリポジトリで補う。

## 6. 健康確認

5 分間隔で次を確認し、失敗が **状態変化したときだけ** 通知（継続失敗は 6 時間ごとに再通知、
復旧は 1 回通知）。全項目 OK なら dead-man ping を送る。状態は
`/var/lib/homelab-agent/healthcheck.state`。手動実行も可能（失敗時 exit 1）。

- 6 コンテナ（`memory-db`/`embedding`/`reranker`/`hindsight`/`hermes`/`cdp-tunnel`）が running
- Hindsight `/health/ready`、TEI の `/health`、推論 `/v1/models`
- Runner への SSH、CDP エンドポイント
- Hermes gateway（`gateway_state.json` が `running` かつ全 platform が `connected`）
- Hermes cronのopen incident（`detected`/`alerted`）、固定bank `personal`のHindsight failed/pending operations

stats取得失敗・不正応答も異常とし、稼働中でもcontainerの`unhealthy`を検知する。
`failed_operations > 0`または`pending_operations > agent_ops_health_pending_ops_threshold`（既定1000）が異常。
failed数は履歴も含むため、原因解消だけでは回復しない場合がある。件数増減ごとには通知せず、
同じ検査の障害継続として最大6時間間隔で知らせる。失敗operationの調査・扱いは運用者が判断する。
`--no-notify`は一時検査用で、通知・dead-man・状態ファイル更新を行わない。

## 7. pve1 側の事前準備（手動・自動化しない）

2026-10-18にpve1で専用dataset `tank-gen2/data/agent-backups` とexportを作成済み。
mountpointは `/mnt/tank-gen2/data/agent-backups`、`quota=300G`、`recordsize=1M`、
`compression=lz4`（継承）、owner / modeの契約値は `root:root` / `0700`。
export直下のmarker `.homelab-export-agent-backups` の内容は `agent-backups`。
バックアップ自体が世代管理・暗号化されているため、snapshotは取らない（作成時もなし）。

既存exportと同じ **`/etc/exports`** に次の行を追加した（`/etc/exports.d/` は空）。
clientは `192.168.10.104/32` へ限定し、`fsid` は指定しない。

```text
/mnt/tank-gen2/data/agent-backups 192.168.10.104/32(rw,sync,no_subtree_check,sec=sys,secure,no_root_squash,no_all_squash)
```

`exportfs -ra` 後の `exportfs -v` で、clientと有効option
`sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` を確認した。
変更後の `/etc/exports` のSHA-256は
`5639f51953049d980b62faa7745546f9a6364e8eaeb8ffebe306327369f118fe`。
Agent VMの `/mnt/agent-backups` へのnfs4 mountとbackupは2026-10-18に確認済み。
同日の再適用でexport rootが`0750`へ変わったが、運用者がAgent VMのrootから
`chmod 0700 /mnt/agent-backups`を実行し、`no_root_squash`経由で`root:root 0700`へ復旧済み。
6回目のAnsible適用はagent-vm / runner-vmともchanged=0、export root 0700を維持し、健康確認all checks passed（[NFS export契約](nfs-export.md#agentバックアップ用export2026-10-18作成)）。
本リポジトリは NFS server 設定を変更しない。

## 8. セキュリティ

- 復号 identity は **VMに常設しない**。リストア時にのみ運用者が与える。元のDB・会話データはVMのデータdiskにある。
- `hermes backup`のzipはHermes自身の`.env`/`auth.json`や会話を含み得るので、セットはage暗号化して保存する。
  別配置の`/etc/homelab/secrets/*.env`、Runner/CDPのSSH秘密鍵、age identityはhelperのarchive対象外。
  それらの秘密はSOPSから復旧するかAnsibleで再生成する。
- 通知 URL・identity のパスをログやコミットに残さない。

## 9. 検証範囲（2026-10-18更新）

過去の試験証跡をWS8でコードと照合した。ローカルの成功を本番DR完了とはしない。

| 範囲 | 確認したこと / 限界 |
| --- | --- |
| WS7a/WS7c（架空会話） | export、暗号化scratch restore、bank消去→DB復元→recall。修正後52記憶で一致。会話品質・速度は[主運用文書](hermes-agent.md#サービスの資源上限) |
| WS7b-ops/ops2（修正前helper） | backup 4成果物・世代管理・mount guard、本番モードを使ったローカル復元、resume、root 0600入力、failed_operations検知。NFSはbind + findmnt double、ageは試験鍵、digest gateは省略 |
| WS7d（修正前rebuild） | 15ターンの架空sessionから1document、前後の本人事実の想起、assistantの未確認事実を抽出しない、再実行でdocument増加無し。試験bankのcustom方針は試験側が別途設定。ローカルexportの先頭3sessionも投入済みで、本番会話データの試験ではない |
| WS7b（模擬Runner） | 保存stdoutでterminal実行・ファイル内容・browserのSSRF拒否・公開ページ取得・healthcheck/backup成功を照合。鍵制約・egress・再接続は報告と描画物で確認したが、全ての生の実行証跡は残っていない |
| WS8（現行helper） | タイムゾーン/JST日付境界、tool-callだけの未完了ターン、pending operationのresume、bank方針適用順、明示失敗時の通知と平文掃除、tar exit 1/2で破壊処理前に停止、stats異常・unhealthy検知、6時間後の通知間隔をfixtureで再検証 |

2026-10-18の実VMではAnsible適用、公開imageのpull/起動、実NFS mount、健康確認（Discord connected・Runner含む）、
通知webhookのGET 200を確認した。17:06のbackup失敗（Runner `lost+found`とwebhook値）をPR #106で修正し、
再適用のPGDATA所有権障害を運用者が復旧後、17:30 JSTのbackup set `20261018T083023Z`は成功した。
Hermes約24 MB、PostgreSQL約120 KB、agent-config、runner-workの暗号化成果物を保存し、`sha256sum -c SHA256SUMS`は全件OK。
`hindsight_version=unknown`は軽微な残件。続く`--scratch`はtotal_nodes=5、recall 5 results、Hermes archive 667 entries、
state.db integrity_check ok（2 DB）を確認し、scratch projectを削除、本番は無変更だった。
復旧age identityはSSH stdin経由で`/run`（tmpfs、0600）の一時ファイルへ渡し、EXIT trapでshred、終了後の不在を確認した。

本番DR、OS reboot、実NFSの容量/障害、Discordの本受入、SearXNG/MCPの網羅的な確認は未実施。
Runnerのコンテナ試験はsystemdの制限を再現していない。特に`RestrictNamespaces`の制限下でChromium sandboxが
動くかは実VM受入に残す。helperはroot専用平文作業領域をumask 077で作り、backup/restore/exportを排他制御する。
