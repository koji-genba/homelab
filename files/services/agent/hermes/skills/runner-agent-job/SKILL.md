---
name: runner-agent-job
description: Runnerで長時間・放置する開発を計画ファイルから起動し、状態確認と最後のレビューを行う。
platforms: [linux]
---

# 長い作業を Runner に任せる

長時間・ブラウザを閉じて放置する作業に使う。短い作業は `runner-claude`、
`runner-codex`、`runner-dsh` を使う。`runner-coding` の承認済みコードと秘密の扱いを守る。
Hermes は計画を作って起動し、必要なときに状態を調べ、最後にレビューする。
段階をつなぐのは Runner の driver。Webapp の note や background 完了通知で次段階を起動しない。

計画と対象 checkout は Runner に置く。同じ checkout で別 worker を起動しない。
開始時は clean な repo が必要。driver が base から新しい `agent/` branch を作るので、
既存 branch は再利用しない。id は英数字で始まる英数字・`_`・`-` の64文字以内。

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
dsh に重い実装やレビューを任せてもよい。本人の希望、必要な能力、利用枠から選び、
DGX は Hermes 本体と共用なので dsh の並列使用による待ち時間にも注意する。
`network` は必須のboolで Codex の sandbox ネットワークだけを制御する。
`model` は任意。dsh の model は管理済み local-glm provider 内のモデル名。
段階の timeout は既定45分・最大120分、期限は既定・最大6時間。
初回計画は起動30回・連続失敗3回まで、段階数は1〜30。
計画にも資格情報や機密コードを書かない。公開本文には実際の検証結果と未検証事項を書く。

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
公開を有効にしても PR ② の credential helper が無ければ `ready_to_publish` で止まる。
helper 導入後の再開は draft PR を作る。main への push・merge はしない。

完了後は Hermes 自身で `git diff <base>...<branch>` と commit 一覧、テスト結果、
各 run の result.json・stdout・stderr を読む。秘密や無関係なファイルがないか確認し、
受入条件を照合する。通知や done だけで成功と判断しない。
本人に使用CLI・変更内容・テスト結果・残件・PRまたは公開待ちを報告する。
ログは資格情報らしい文字列をマスクするが完全な漏えい防止境界ではない。
実機の成功実行・通知・公開は未検証。
