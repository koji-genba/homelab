---
name: runner-coding
description: Runnerで開発を依頼されたとき、dsh・Claude Code・Codexを選び、作業とテストの結果を本人へ報告する。
platforms: [linux]
---

# Runner のコーディング窓口

実行先は terminal の SSH backend（hermes-runner）、作業場所は
`/srv/agent-work/repos/<owner>/<repo>`。このtreeはRunner上にあり、Agentのローカルではない。

- 長時間または放置する作業は `runner-agent-job` を読み、計画から driver を起動する。
  dsh を含む3 CLIをどの段階にも選べる。以下の直接起動は短い作業に使う。
- 安い作業、読むだけの調査、小さな変更は `runner-dsh`（DGX glm-5.3-flash）。
- 複雑な実装、設計、難しい不具合は `runner-claude` または `runner-codex`。
  本人の指定があれば優先する。失敗を無限に別CLIへ回さず、原因と制限を伝える。
- 同じcheckoutを複数workerで同時編集しない。DGXはHermes本体と共用なので、
  dshの同時起動を避け、遅いときは負荷を本人へ伝える。
- CLIには変更とテストまでを依頼する。commit・push・PRは `runner-publish` を読み、
  Hermesが結果を確認してから行う。GitHub credentialの発行・注入はworkerに依頼しない。

CLIごとのskillを読んで `terminal(background=true, notify=true)` で起動する。
PTYや対話stdinは使わず、質問に答えられない場合は停止して本人へ伝える。
完了通知後は `process_manage(action="poll", session_id="...")` で終了と終了コードを確認し、
`process_manage(action="log", session_id="...")` と構造化出力を確認する。
通知が来ない有限セッションではpollして完了を待つ。Hermes子エージェントから起動した場合は
完了を待つかprocess_manageのhandoffで親へ所有権を移す。PIDを返すだけでは引き継げない。
終了124は時間切れ、137は強制終了の場合があり、どちらも成功扱いしない。

各実行の出力は衝突しない `/srv/agent-work/results/<task-id>/` に置く。
ログはhome・shareに置かず、公開前に秘密が含まれないか確認する。
外部モデルへ渡すのは承認されたrepoの非機密コードだけ。認証情報、.env、鍵、Hermes状態、
無関係なローカルファイルの読み取り・送信は承認へ上げ、プロンプトにも含めない。
RunnerはVMが隔離境界で、同じUIDのhome内credentialをCLIから読めることに注意する。

本人には「使ったCLI（モデル）・変更の要点・テスト結果・残る問題」を短く報告する。
実機で確認していない性質は「未検証」と書く。実行しただけで成功と報告しない。
同梱のclaude-code/codex skillはSSH環境と不整合なので使わない。
