---
name: runner-publish
description: Runnerでworkerの差分とテストを確認し、agentブランチのcommit・push・GitHub PR作成まで行う。main更新とmergeは禁止。
platforms: [linux]
---

# Runner から公開する

作業場所は `/srv/agent-work/repos/<owner>/<repo>`。新しいrepoの作成・App登録・ruleset設定は本人が行う。
GitHub認証は `/usr/local/libexec/agent-job-github-credential` を使う。
helper/鍵が未導入、またはrepoがAppにonboardingされていなければtokenを取れない。
push/PR作成を止め、ローカルの変更とテスト結果を報告する。
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
   `git push origin HEAD:refs/heads/agent/<topic>` でそのbranchだけpushする。
6. 変更内容・検証・未検証事項を書いたPR本文を一時ファイルに作り、
   `gh-agent <owner>/<repo> pr create --draft --base <base> --head agent/<topic> --title '<件名>' --body-file <本文ファイル>`。
   baseは対象repoのdefault branchなど作業の起点を指定し、headと異なる有効なgit refを使う。
   本文は実際の改行を保存し、シェルへの直接補間を避ける。
7. PR URL、使ったCLI、テスト結果を本人へ短く報告する。

commit名義はAnsible管理のglobal git設定のApp botを使う。未設定時はAgent Job Bot。
PR確認は `gh-agent <owner>/<repo> pr view <番号>` / `pr list`、本文修正は
`gh-agent <owner>/<repo> pr edit <番号> --body-file <本文ファイル>`（draftのみ）。
mainへのpush、force push、PRのmerge、branch保護の変更は行わない。
`.github/workflows` を変えたpushはAppの権限で拒否される。その場合は本人に対応を頼む。
homelabではmainのmergeが本番deployになる。mergeは本人だけが行う。
権限エラー時は別の個人tokenへ切り替えず停止する。

repoの追加は本人が先にonboardスクリプトでmainのrulesetを付け、次にGitHubのApp設定画面の
Repository accessでインストール先へ追加する。checkスクリプトはrulesetだけを確認し、
Appへの登録状況は確認しない。Hermesから設定変更を行わない。
