---
name: runner-omp
description: RunnerのSSH backendからompを起動し、DGXのglm-5.3-flashで調査・小さな変更とテストを行う。
platforms: [linux]
---

# omp on Runner

`runner-coding` の作業場所と秘密の扱いを守る。隔離境界は Runner VM。管理済みの
`dgx/glm-5.3-flash` を使う。DGX は Hermes 本体と共用なので同時起動を避ける。

短い作業では先に `mkdir -p /srv/agent-work/results/<task-id>` を実行する。
stdin は `</dev/null` で閉じ、PTY は付けない。

```text
terminal(command="umask 077; timeout --signal=TERM --kill-after=30s 45m omp --mode json '指定の調査または小さな変更とテストまで。commit・push・PR作成と資格情報の読み取りは禁止。結果と残件を報告する。' </dev/null > /srv/agent-work/results/<task-id>/omp.jsonl 2> /srv/agent-work/results/<task-id>/omp.stderr", workdir="/srv/agent-work/repos/<owner>/<repo>", background=true, notify=true)
```

完了通知後は `process_manage(action="poll", session_id="...")` で終了コードを確認する。
ログは上記の `omp.jsonl` と `omp.stderr` から必要な範囲を回収する。JSONL の
`agent_end.isTerminal` が true の完了イベントと、最後の assistant の `message_end.message.content`
にある text を確認する。失敗時は stderr と assistant の `stopReason` を調べ、タイムアウト時は
途中のログと差分を確認する。必要なら `process_manage(action="kill", session_id="...")` で中止する。
本人には使った CLI・モデル、差分とテストの結果、残件を報告する。
