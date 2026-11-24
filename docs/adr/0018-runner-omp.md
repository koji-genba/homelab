# ADR-0018: Runner のローカル推論 CLI を oh-my-pi に移行

- 日付: 2026-11-24
- 状態: 採用。repo 実装済み、実機は未検証
- [ADR-0015](0015-hermes-coding-agents.md) の dsh 採用と当該 CLI の隔離方針を置き換える。

## 決定と理由

dsh 0.2.2-rc.1 を廃止し、oh-my-pi 19.1.0 を `omp` として提供する。
dsh は開発途上のリリース候補であり、一般のベンチマークでの omp の評価を採用判断に使った。
Runner 上の GLM での比較試験は未実施。推論は DGX の OpenAI 互換 API
`http://192.168.10.51:8000/v1` と `glm-5.3-flash` を使い、既存の宛先 TCP/8000 許可を流用する。

Runner VM を omp の隔離境界とする。ADR-0015 では dsh の sandbox が成立しないときに
制限なしの実行へ自動で切り替えない方針だった。omp は当初から CLI 側の作業範囲を
制限せず、Claude Code と同様に非 root の `hermes-runner` が Runner 内でツールを使う。
公開や資格情報の扱いには既存の承認ルールを適用し、Codex は引き続き workspace-write を使う。

Ansible は root 管理の npm lockfile で omp と Linux amd64 glibc の Bun バイナリを導入する。
`@oven/bun-linux-x64` を直接固定することで、Bun のインストールスクリプトを介さず、
registry の整合性ハッシュでバイナリを検証できる。Bun 1.4.4 は 2026-10-22 公開で、
omp 19.1.0 が要求する Bun 1.4.4 以上を満たす。

## 運用上の影響とリスク

- repo やモデルからの指示により、omp は `hermes-runner` がアクセスできる他の checkout、
  home、共有領域も読み書きできる。送信を承認した repo を対象とし、Runner の権限と既存
  firewall で到達先を絞る。推論は LAN 上の HTTP で送信され、DGX は Hermes 本体と共用する。
- 版更新では provider schema、ツール呼び出し、JSONL の完了イベント、セッション再開を再検証する。
  agent-job は同じ段階の永続化済みセッションを再開し、新しい段階には別のセッションを作る。
  トランスクリプトは Runner の home に保存される。
- `cli=dsh` を持つ新規計画、または未完了の dsh 段階を持つ保存済み計画はエラーにする。
  CLI 間でセッション ID と履歴を引き継げないため、差分と checkpoint を確認し、
  `cli=omp` を選んだ新しい計画で続ける。完了済みの段階は実行履歴に残す。

## ロールバック

新規起動を止め、進行中の job を終えるか停止する。移行前の manifest・lockfile、Ansible 設定、
agent-job、Hermes skill・承認設定を一式に戻し、本人が apply する。旧 playbook の管理外になる
omp の launcher・管理設定・skill は必要に応じて撤去する。両 CLI のユーザーデータは保全する。
手順と受入項目は [Runner の運用手順](../operations/hermes-agent.md#omp-移行のロールバック) に記載する。
