---
name: runner-claude
description: RunnerのSSH backendからClaude Codeを非対話で起動し、難しい変更とテストのJSON結果を得る。
platforms: [linux]
---

# Claude Code on Runner

`runner-coding` の作業場所・秘密の扱いを守る。本人がRunnerで初回ログイン済みであることが前提。
URLログインや認証情報の読み取りをworkerに依頼しない。認証エラーなら本人へ伝える。

例のowner/repo・task-id・依頼文を対象に置き換える。terminalで先に
`mkdir -p /srv/agent-work/results/<task-id>` を実行し、出力先を用意する。

```text
terminal(command="timeout --signal=TERM --kill-after=30s 45m claude -p '指定の変更とテストまで。commit・push・PR作成と資格情報の読み取りは禁止。変更点・テスト結果・残件を報告する。' --output-format json --permission-mode bypassPermissions > /srv/agent-work/results/<task-id>/claude.json 2> /srv/agent-work/results/<task-id>/claude.stderr", workdir="/srv/agent-work/repos/<owner>/<repo>", background=true, notify=true)
```

PTYは付けない。`--bare` はサブスクリプションOAuthを読まないため使わない。
`bypassPermissions` は非rootのhermes-runnerで使い、Runner VMを隔離の境界とする。
これはClaude自身のbwrap sandboxを有効にする指定ではない。rootやAgent側で起動しない。

完了通知後、`process_manage(action="poll", session_id="...")` で終了コードを確認し、
`process_manage(action="log", session_id="...")` とterminalでJSONを読む。
JSONの `is_error`・結果を確認し、認証・利用枠・承認要求・時間切れは失敗として扱う。
必要なら `process_manage(action="kill", session_id="...")` で中止する。
結果が成功でも差分とテストをHermes自身で確認し、使ったCLIと結果を本人へ報告する。
