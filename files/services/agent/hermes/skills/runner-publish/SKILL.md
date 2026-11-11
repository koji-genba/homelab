---
name: runner-publish
description: Runnerでworkerの差分とテストを確認し、agentブランチのcommit・push・GitHub PR作成まで行う。main更新とmergeは禁止。
platforms: [linux]
---

# Runner から公開する

作業場所は `/srv/agent-work/repos/<owner>/<repo>`。新しいrepoの作成・App登録・ruleset設定は本人が行う。
GitHub認証は **PR ② で用意する credential helper を使う**。
未導入ならpush/PR作成は止め、ローカルの変更とテスト結果を報告する。
worker CLIにGitHub credentialの発行・注入を依頼しない。

1. terminalでremoteが対象repoであること、作業treeと現在branchを確認する。
   他の仕事の変更があれば混ぜず、本人へ伝える。
2. worker開始前に `git switch -c agent/<topic>` で仕事ごとのbranchを作る。
   同じcheckoutの並行編集を避ける。既存の別タスクbranchを再利用しない。
3. worker完了後、Hermesが `git diff --stat`、`git diff`、`git status --short`、
   テスト結果を確認する。資格情報や無関係なファイル、CLIの結果ファイルを含めない。
   失敗や未検証を成功と書かず、問題があれば公開前に直すか本人へ伝える。
4. 対象を明示して `git add -- <変更ファイル>`、`git diff --cached` を確認してcommitする。
   `git add .` は使わない。commitは変更理由がわかる件名とする。
5. 現在branchが `agent/<topic>` であることを再確認し、
   `git push --set-upstream origin HEAD:refs/heads/agent/<topic>` でそのbranchだけpushする。
6. 変更内容・検証・未検証事項を書いたPR本文を一時ファイルに作り、
   `gh pr create --repo <owner>/<repo> --base main --head agent/<topic> --title '<件名>' --body-file <本文ファイル>`。
   本文は実際の改行を保存し、シェルへの直接補間を避ける。
7. PR URL、使ったCLI、テスト結果を本人へ短く報告する。

mainへのpush、force push、PRのmerge、branch保護やworkflowの変更は行わない。
homelabではmainのmergeが本番deployになる。mergeは本人だけが行う。
権限エラー時は別の個人tokenへ切り替えず停止する。
