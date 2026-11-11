---
name: runner-dsh
description: RunnerのSSH backendからdsh headlessを起動し、DGXのglm-5.3-flashで調査・小さな変更とテストを行う。
platforms: [linux]
---

# dsh on Runner

`runner-coding` の作業場所・秘密の扱いを守る。home patchでDGXのglm-5.3-flashを選び、
DeepSeekアカウント連携・テレメトリを止めている。クラウドへのfallbackやログインはしない。

terminalで `mkdir -p /srv/agent-work/results/<task-id>` を先に実行する。

```text
terminal(command="timeout --signal=TERM --kill-after=30s 45m dsh headless --json --permission-mode workspace-write --approval-policy never '指定の調査または小さな変更とテストまで。commit・push・PR作成と資格情報の読み取りは禁止。結果と残件を報告する。' > /srv/agent-work/results/<task-id>/dsh.jsonl 2> /srv/agent-work/results/<task-id>/dsh.stderr", workdir="/srv/agent-work/repos/<owner>/<repo>", background=true, notify=true)
```

PTYは付けない。bashの既定timeoutはhome patchで600000msだが、全体の45分制限とは別。
完了通知後 `process_manage(action="poll", session_id="...")` で終了コードを確認し、
`process_manage(action="log", session_id="...")` とJSONLの `error`・`final.reason` を読む。
JSONが妥当でも失敗turnがあり得るので、終了コードと差分・テストを照合する。
必要なら `process_manage(action="kill", session_id="...")` で中止する。
DGX接続、GLMのtool calling、sandboxに失敗したら原因を本人へ報告し、full-accessに変更しない。
DGXはHermes本体と共用のため同時起動は避ける。使ったCLI・モデルと結果を短く報告する。
