---
name: runner-agent-job
description: Runnerで長時間・放置する開発を計画ファイルから起動し、状態確認と最後のレビューを行う。
platforms: [linux]
---

# 長い作業を Runner に任せる

長時間・ブラウザを閉じて放置する作業に使う。短い作業は `runner-claude`、
`runner-codex`、`runner-dsh` を使う。`runner-coding` の承認済みコードと秘密の扱いを守る。
Hermes は計画を作って起動し、必要なときに状態を調べる。無人の最終レビューは計画の段階に含める。
段階をつなぐのは Runner の driver。Webapp の note や background 完了通知で次段階を起動しない。

計画と対象 checkout は Runner に置く。同じ checkout で別 worker を起動しない。
開始時は clean な repo が必要。driver が base から新しい `agent/` branch を作るので、
既存 branch は再利用しない。id は英数字で始まる英数字・`_`・`-` の64文字以内。
実行中・resume 前にその clone で別 branch へ切り替えない。切り替わっていても、作業ツリーが clean なら
driver が job の branch へ戻す。未コミットの変更があれば切り替えず、`working tree changed outside the job`
で blocked になる。変更を片付けてから resume する。

```json
{
  "id": "feature-01",
  "repo": "/srv/agent-work/repos/owner/repo",
  "branch": "agent/feature-01",
  "base": "main",
  "deadline_hours": 6,
  "max_launches": 30,
  "max_consecutive_failures": 3,
  "stages": [
    {"name": "implement", "cli": "dsh", "prompt": "機能を実装して関連テストを実行する",
     "acceptance": "要求を満たし、関連テストが成功する。未解決はblockedとして報告する",
     "timeout_minutes": 45, "network": false},
    {"name": "review", "cli": "codex", "prompt": "変更とテストをレビューし必要な修正を行う",
     "acceptance": "差分を確認し、テストの結果と残る制約を報告する",
     "timeout_minutes": 45, "network": false}
  ],
  "publish": {"enabled": true, "title": "機能の追加", "body": "変更理由と検証結果"}
}
```

各段階は、目的と検証可能な受入条件を持つ。cli はどの段階も claude / codex / dsh を選べる。
dsh（GLM）に重い段階を任せる計画では、最後に claude か codex のレビュー段階を置く。
実装した CLI とは別のものを選ぶ。claude / codex が実装する場合も、規模が大きければ
別 CLI の最終レビューを置くのが望ましい。本人の希望、必要な能力、利用枠から選び、
DGX は Hermes 本体と共用なので dsh の並列使用による待ち時間にも注意する。
`network` は必須のboolで Codex の sandbox ネットワークだけを制御する。
`model` は任意。dsh の model は管理済み local-glm provider 内のモデル名。
段階の timeout は既定45分・最大120分、期限は既定・最大6時間。
初回計画は起動30回・連続失敗3回まで、段階数は1〜30。
計画にも資格情報や機密コードを書かない。公開本文には実際の検証結果と未検証事項を書く。

レビュー段階の prompt 雛形（`<base>` は計画の base に置き換える）:

```text
git diff <base>...HEAD と commit 一覧・内容を読み、要求と照合する。
テストを全部流し直し、実装とは別の観点（境界値、エラー経路、仕様との差）で検証する。
小さな不具合は修正してテストを通す。重大な問題が残れば、最終行を
AGENT_JOB_STATUS: blocked 理由と残件
として止める。問題が解消したら、最終行を
AGENT_JOB_STATUS: done 検証したこと・結果、見つけた問題と修正、残る制約の要約
とする。要約だけでも検証内容と発見した問題が分かるように書く。
```

acceptance にも「全テスト再実行・独立した検証・小修正後の成功、重大な未解決は blocked」を書く。
blocked なら公開せず停止し、見張りの通知対象になる。Webapp の完了から Hermes が自動で
起きる前提にはしない。レビューの timeout は45分を目安に、全テストの所要時間に応じて
最大120分まで確保し、job 全体の期限・起動予算にも含める。
network は原則 false。依存取得など検証に必要で許可済みの場合だけ true にする。
これは Codex の sandbox の設定であり、claude / dsh や Runner の通信制限を変えるものではない。

SSH terminal で通常の短いコマンドとして実行する（PTY・background追跡は不要）:

```sh
agent-job start /srv/agent-work/plans/feature-01.json
agent-job status feature-01 --json
agent-job list
agent-job stop feature-01
agent-job resume feature-01
# 人が原因と予算を確認した場合だけ、累積起動上限・連続失敗上限を増やす
agent-job resume feature-01 --deadline-hours 6 --max-launches 60 --max-consecutive-failures 5
```

`stop` は停止フラグを書き、systemd user service の cgroup 全体を停止する。
通常の `/stop` は Hermes の会話を止めるもので、Runner job の停止には上記コマンドを使う。
`resume` は同じ段階・CLI session を再開する。期限は指定時から最大6時間、
起動上限は累積値。上限を増やすのは本人の判断を得た場合だけ。
失敗理由と残件を確かめず自動再開や別CLIへの無限回送をしない。

状態・ログの正は `/srv/agent-work/tasks/<id>/` の plan.json、state.json、runs/<n>/。
done の段階ごとに driver が bot 名義の checkpoint commit を作る。
公開を有効にしてもAppの鍵・credential helperが未導入なら `ready_to_publish` で止まる。
導入後にresumeすると、対象HTTPS originの `agent/<topic>` へpushし、
`gh-agent <owner>/<repo> pr create --draft ...` でdraft PRを作る。
PR本文は publish.body を先頭に残し、末尾の「agent-job の記録」に段階名・CLI・起動回数と
最後の成功 done の要約を付ける。要約は伏せ字処理後に各1,000文字まで、本文全体は65,536文字まで。
表の領域を確保して計画の本文を切り詰める。stage のない古い run は集計しない。
checkpointの名義はAnsible管理のApp bot、未設定時はAgent Job Bot。
repoのonboardingが必要。mainへのpush・mergeはしない。
`.github/workflows` を変更したpushが拒否されたら、本人に対応を頼む。
公開失敗後はremote branchと既存PRを確認してから再開し、重複PRを作らない。
失敗したコマンド（push・pr create）と終了コードはstateのsummaryに出る。標準出力・標準エラーは
資格情報らしい文字列を伏せて `runs/publish-<n>/` の stdout・stderr・result.json に残るので、原因はそこで読む。

完了後に Hermes が報告するときは `git diff <base>...<branch>` と commit 一覧、テスト結果、
各 run の result.json・stdout・stderr を読む。秘密や無関係なファイルがないか確認し、
受入条件を照合する。通知や done だけで成功と判断しない。
本人に使用CLI・変更内容・テスト結果・残件・PRまたは公開待ちを報告する。
ログは資格情報らしい文字列をマスクするが完全な漏えい防止境界ではない。
PR ①のCLI成功・resume・通知は受入済み。Appによる公開は反映後の受入が必要。

repoの追加は本人が先にonboardスクリプトでmainのrulesetを付け、次にGitHubのApp設定画面の
Repository accessでインストール先へ追加する。checkスクリプトはrulesetだけを確認し、
Appへの登録状況は確認しない。Hermesから設定変更を行わない。

GitHub Freeのprivate repoはruleset保護が使えない。publicだけを対象にするか、Proにするか、
保護できないリスクを承知で追加するかは本人が決める。個人repoでGitHub Actionsをbypassにできない。
homelabは毎時staging更新をdeploy key（Actions secret、main限定environment）へ移す別PRと、
`--allow-deploy-key-bypass`でのonboardingが終わるまで、Appの対象から外しておく。
