---
name: runner-codex
description: RunnerのSSH backendからCodex execをworkspace-writeで起動し、難しい実装・テストの結果を受け取る。
platforms: [linux]
---

# Codex on Runner

`runner-coding` の作業場所・秘密の扱いを守る。初回device loginは本人がRunnerで行う。
既定モデルはAnsible管理のgpt-6.1-sol、reasoning effortはmedium。

terminalで `mkdir -p /srv/agent-work/results/<task-id>` を先に実行する。
`-o` はsandboxのworkspace内にある一意な未追跡ファイルを指定する。
事前に同名ファイルが存在しないことを確認し、公開処理でstageしない。

```text
terminal(command="timeout --signal=TERM --kill-after=30s 45m codex exec --json -s workspace-write -o .codex-result-<task-id>.md '指定の変更とテストまで。commit・push・PR作成と資格情報の読み取りは禁止。変更点・テスト結果・残件を報告する。' > /srv/agent-work/results/<task-id>/codex.jsonl 2> /srv/agent-work/results/<task-id>/codex.stderr", workdir="/srv/agent-work/repos/<owner>/<repo>", background=true, notify=true)
```

依存取得などネットワークが必要な仕事には
`-c sandbox_workspace_write.network_access=true` を追加する。
PTY、`--full-auto`、対話的な承認待ちは使わない。
完了通知後 `process_manage(action="poll", session_id="...")` で終了コードを確認し、
`process_manage(action="log", session_id="...")`、JSONLのエラーと最終回答ファイル、
実際の差分・テスト結果を照合する。本人へ使ったCLIと結果を短く報告する。
最終回答ファイルは結果dirへ移し、作業treeから除いて公開前に確認する。

sandboxがnamespace・bwrap・seccompで起動できなければ再試行を止め、エラーを報告する。
本人にRunner側のuser namespace・bwrap・サービス制限の確認を依頼し、修復後に再試行する。
急ぐ場合は承認された同じタスクをrunner-claudeへ回すか、読み取りだけならrunner-dshへ回す。
`danger-full-access` やsandboxを無効化するフラグへ自動で切り替えない。
