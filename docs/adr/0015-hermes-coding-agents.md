# ADR-0015: Runner のコーディング CLI と DGX 推論接続

- 日付: 2026-11-12
- 状態: 採用。repo 定義済み、実機は未検証
- 背景と決定: [issue #207](https://github.com/koji-genba/homelab/issues/207) の PR ①
- 更新する前提: [ADR-0008](0008-hermes-agent-hindsight-vms.md) の Runner の隔離・資格情報、
  [ADR-0014](0014-hermes-share-nfs.md) の LAN 接続例外。両 ADR の本文は保持する。

## 決定と理由

Hermes を開発の窓口にし、SSH backend から Runner 上の Claude Code・Codex・dsh を呼ぶ。
読むだけの調査や小さな仕事は dsh（DGX の glm-5.3-flash）、難しい仕事は Claude Code または
Codex に任せる。対象は homelab に限らない。CLI は変更・テストまで、Hermes は差分を確認して
作業 branch の commit・push・PR 作成までを行い、main の更新・merge は本人だけが行う。

Runner の egress に **192.168.10.51/32 の TCP/8000 のみ**を追加する。
pve1 の TCP/2049 は維持し、DGX の他ポート・他 LAN 宛新規接続は拒否する。
宛先ネットワーク全体の許可は使わない。DGX の HTTP 推論 endpoint にコードが渡り、
Hermes 本体と dsh が同じ計算資源を使うことを受け入れる。

CLI は root 所有の `/opt/coding-agents` に npm lockfile の integrity で固定し、`npm ci` で導入する。
`/usr/local/bin` へリンクし、実行ユーザーには導入先を書かせない。自動更新は止め、版変更は
repo の lockfile 更新と手動 Ansible apply で行う。OS の gh・bubblewrap・socat は Debian apt 管理とする。

Claude Code と Codex は本人のサブスクリプションでログインし、認証情報は
`/home/hermes-runner` 配下に置いて CLI 自身に更新させる。Ansible は認証ファイルを管理しない。
Runner-work のバックアップは `/srv/agent-work` が対象で、home は含めない。
再構築時は本人が再ログインする。Agent からの環境変数転送や Hermes の設定への token 保存は使わない。

外部の Anthropic/OpenAI モデルへ承認された repo の非機密コードを渡す。
Codex の ChatGPT ログインによる自動化について、公式文書は public repo での使用を推奨していないが、
issue #207 の明示的な決定により public repo にも使用する。API キーへ置き換えない。

## リスクと緩和

- 同じ UID の任意コマンドから home の認証情報を読める。VM は隔離境界だが、CLI sandbox や
  skill は資格情報の完全な保護境界ではない。Runner に管理鍵・Discord token・memory DB は置かず、
  明示的な資格情報の読み取り・送信は smart approvals でも引き続き ESCALATE する。
- Claude の `bypassPermissions` は非 root の Runner 内で使用する。Codex は workspace-write、
  dsh は workspace-write と approval-policy never。sandbox 不成立時は無制限実行へ自動変更しない。
- 通常の CLI 内部認証と承認済みコードの推論送信だけを smart policy の例外とする。
  任意のファイル送信、資格情報の抽出、インターネットコードの取得・実行を許可する例外ではない。
  smart policy は LLM の判断であり、毎回同じ判定になる保証はない。
- 漏えい時は Claude Settings で該当サインインを削除して `claude auth logout`、Codex は
  `codex logout`。表示だけでサーバー側の失効成功を断定しない。
  詳細は [運用手順](../operations/hermes-agent.md#runner-のコーディング-cliissue-207) に従う。
- dsh は preview 版。GLM の tool calling・推論履歴・画像、実機 sandbox、DGX の競合は未検証。
  firewall・認証維持・バックアップ除外を含め、反映後に小さな試験用 repo で受け入れる。

## skill と後続作業

使い分け・3 CLI・公開処理の5 skillを `runner-*` の固有名で repo 管理し、apply で上書きする。
Hermes の編集も次の apply で戻る。同梱 claude-code/codex は自動選択から外す。
既存 hermes-share・weekly-review は初回 seed のままにする。

GitHub App は **PR ②**。App の秘密鍵の SOPS 配布、別ユーザー gh-broker、短命 installation token
発行ラッパー、Git credential helper と gh の接続、repo 追加スクリプト・main ruleset をそこで実装する。
App 鍵を Runner に置く最終判断・失効運用も PR ② で具体化する。PR ① は鍵・helper を配らない。
本人だけを main 更新の bypass に入れ、App は入れない。必須レビュー ruleset は設けないという
issue #207 の決定に従う。PR ② 完了前は公開処理を利用開始しない。

## 根拠

- [Claude managed settings](https://code.claude.com/docs/en/managed-settings)、
  [自動更新停止](https://code.claude.com/docs/en/setup#disable-auto-updates)、
  [CLI reference](https://code.claude.com/docs/en/cli-reference)
- [Codex 設定](https://learn.chatgpt.com/docs/config-file/config-reference)、
  [自動化認証の留保](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
- [dsh 0.2.2-rc.1 の変更](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.1)
