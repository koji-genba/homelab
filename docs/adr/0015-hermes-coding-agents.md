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

## 2026-11-12 補足: 長時間作業の進行役（PR ①.5）

[issue #207 の方針変更](https://github.com/koji-genba/homelab/issues/207#issuecomment-6800944788)
に従い、長時間作業を進める役は Runner の root 所有 Python driver `agent-job` に置く。
固定版 c7da41dd の Webapp は platform=local で、閲覧者不在時の background 完了は履歴の
note になり、次のターンを起こさない。gateway 再起動時も SSH background の追跡・通知は復元されない。
Hermes の通知を次の段階の起点にすると、ブラウザや gateway の寿命で作業が止まるためである。
Hermes は計画・起動・問い合わせへの回答・最後のレビューを担う。busy_input_mode は変えない。

Runner の `systemd --user` と linger を使い、SSH セッションから切り離す。
service は MemoryMax=6G、KillMode=control-group、RuntimeMaxSec=6h とし、stop で子孫も止める。
状態の正は `/srv/agent-work/tasks/<id>/`。repo ごとの flock と起動受付ロックで同一 repo を排他し、
全体は2件まで。初回計画は期限6時間・CLI起動30回・連続失敗3回、段階のtimeout最大120分。
人の明示的な resume で期限を最大6時間更新し、累積起動・連続失敗の上限を増やせる。
3 CLI は同じ状態遷移を使い、dsh にも重い段階を任せられる。DGX は Hermes と共用する。

CLI の `done` は driver が固定 bot 名義で checkpoint commit する。
公開を有効にしても PR ② の root 所有 credential helper が無ければ `ready_to_publish`。
helper の契約は `/usr/local/libexec/agent-job-github-credential` の Git credential protocol
（get/store/erase）とする。導入後は対象 repo と一致する HTTPS origin の `agent/` branch だけを
push し、`gh pr create --draft` を実行する。main push・force push・merge はしない。
この補足は長時間作業での checkpoint・draft公開を driver に移す例外で、短い直接実行のレビュー手順は維持する。

Agent は10分ごとの `no_agent` script cron で同じ鍵・ユーザーから `agent-job alerts` を読む。
停止（明示的なstop・Runner再起動時のSIGTERMを含む）も通知する。
空のstdoutは通知しない。届け先は SOPS の Discord home channel を変数で渡し、local は使わない。
SSH失敗は状態ファイルで復旧まで抑制する。通知済みの記録は送信確認より前なので、配送は厳密な
exactly-once ではない。状態ファイルを正とし、通知がなくても問い合わせで確認する。
CLI出力は既知のcredential形式をマスクし、通知には要約を含めない。ただし同じUIDのCLIと
home credential の境界は変わらず、任意の秘密文字列の完全な検出は保証しない。

ローカル fixture で制御フローを検証する。実機の user manager・cgroup・sandbox・サブスクリプション
認証での成功とresume・Discord配送・GitHub公開は **未検証**。PR ② と実機受け入れ後に利用開始する。


## 2026-11-12 補足: GitHub App と main 保護（PR ②）

PR ①/①.5 の採用時記述を保持し、issue #207 の確定設計を具体化する。
本人のアカウントに private GitHub App を作り、Only on this account、webhook off、
Contents write・Pull requests write・Metadata read のみ、選択した repo のみにインストールする。
Workflows・Administration・Actions・Secrets は渡さない。
Contents write は merge にも使えるので、token 権限だけで main 更新を防げない。

repo ごとに `agent-main-protection` ruleset **1本**を active で作る。
対象は `refs/heads/main`、update・deletion・non_fast_forward を制限し、
bypass は Repository admin（RepositoryRole ID 5）の always のみ。App は bypass に入れない。
必須レビューの ruleset は付けない。本人作成の PR を本人が承認できず詰まるためである。
調査レポートの2本案より、この確定設計を優先する。
本人用 onboarding は保護を先に作り、その後本人がApp設定画面のRepository accessで対象repoを追加する。
ghのOAuth tokenではinstallation APIが使えない実機結果により、スクリプトはrulesetの作成・更新・確認だけを行う。
GitHub 管理操作はRunnerに渡さない。

App 鍵は既存 Agent SOPS bundle の任意 `github_app`（app_id、installation_id、private_key）へ保存する。
復号は controller の既存タスクだけ。host facts 経由で Runner play へ渡し、no_log で配置する。
Runner に初めて置く App 鍵は非ログイン system user `gh-broker` 所有0400、設定も0400。
Agent のコンテナ環境・share・runner-work バックアップには置かない。
hermes-runner は sudo/docker group に入れず、sudo は次の1行だけ許す。

```sudoers
hermes-runner ALL=(gh-broker) NOPASSWD: /usr/local/libexec/agent-job-github-token
```

root所有のbrokerがowner/repoを検査し、installationのowner一致を確認したうえで、
`repositories=[repo]` と上記3権限に絞るinstallation tokenを発行する。
JWT RS256 はPython標準ライブラリとopensslで作る。repoごとに0600でcacheし、残り5分以上なら再利用する。
helperはgetだけに応え、tokenはGitのpipeまたはgh-agentのGH_TOKENへ短時間渡す。
root所有gh-agentはdraft作成・確認・一覧・draft本文編集に限る。main保護の強制境界はGitHub rulesetである。
workerとHermesは同じUIDなので短命tokenの発行能力は共有する。skill/wrapperは任意コマンドの完全な隔離ではない。
App鍵が漏れるとインストール先全repoの権限内でtokenを再発行できる。
mainはrulesetで守るが、他branch・コード・PRは改変され得る。鍵revoke、suspend/uninstallで失効する。

未登録・空のbundleではGitHubを導入せず `ready_to_publish` を維持する。
後から項目を消してapplyした場合は配置済み鍵・helper・sudoers・cacheも削除して無効化する。
bot slug/user IDは公開変数として管理し、未設定時はAgent Job Botへfallbackする。
global ignoreでpyc等をcheckpointに含めない（既に追跡済みの生成物は別途取り除く）。

ローカルfixtureはJWT署名・repo限定要求・cache/期限・protocol・wrapper拒否・公開接続を検証する。
実際のAppによるbranch push/draft作成とmain push/merge/workflow push拒否、sudoの実効権限、
連続applyの冪等性は反映後の受入対象。手順は[運用書](../operations/hermes-agent.md#github-app-による公開pr-②)。


## 2026-11-12 補足: 実機結果と deploy key による毎時 staging 更新

本人の実機でIntegration 15368のbypass登録は422。個人のrepoでは組み込みGitHub Actionsをbypassにできない。
旧Actions bypassオプションは削除し、`--allow-deploy-key-bypass`を導入する。
指定時のみDeployKey/alwaysをadminに追加する。actor_idは公式REST APIに従いnullで、特定鍵IDではない。
update・deletion・non_fast_forwardは維持し、Hermes Appはbypassへ入れない。

homelabはStashPad stagingのworkflowがGITHUB_TOKENでmainに直接pushするため、
別PRでそのpush認証をdeploy keyへ変える。鍵はActions secretとしてmain限定environmentに保存する。
workflowの移行と同オプションでのonboardingが済むまでhomelabをAppのインストール先から外しておく。
今回workflow・GitHub設定は変更しない。詳細と公式根拠は[運用書](../operations/hermes-agent.md#homelab-の-github-actions-による-main-更新)。

GitHub Freeのprivate repoはrulesetで保護できず、実機APIも403。public repoだけをAppへ追加するか、
Proへ移行するか、main保護が無いリスクを承知して追加するかは本人が判断する。
最後の場合は「main更新は本人だけ」の保証はない。agent-sandboxは本人がpublic化してonboarding済み
（ruleset 27049802）。スクリプトは公開化・課金変更を行わない。
GitHub応答はupdateのfalse parametersを省略するため比較時に正規化し、応答メタデータは比較から除く。


## 2026-11-12 補足: broker専用ディレクトリとtoken形式

App鍵・設定は `/etc/gh-broker/github-app.{pem,json}`（gh-broker所有0400）へ配置し、
親 `/etc/gh-broker` はgh-broker所有0700とする。旧配置の2ファイルはapply時に削除し、
無効化時は新ディレクトリも削除する。common roleがroot:root 0700で管理する
`/etc/homelab/secrets` の属性をbroker taskで変更しない。
installation tokenはドット・ハイフンを含む形式に対応し、許可文字を `[A-Za-z0-9_.-]`、
長さを1〜2048文字としてbroker・credential helper・gh-agentで検査する。


## 2026-11-12 補足: 公開前の branch 復帰、公開ログ、Codex の既定設定

issue #207 の受け入れ試験で見つかった3点を直す。

**branch の復帰**: 同じ clone で別 branch へ切り替えたあとの resume は、公開の直前に branch 不一致の
例外になり `driver error` の failed だった。driver は起動時、各段階の CLI 起動前、checkpoint の前、
公開の前に branch を確かめる。作業ツリーが clean なら job の branch へ `git switch` で戻して続け、
未コミットの変更があれば切り替えずに blocked で止める（summary は
`working tree changed outside the job`）。変更を失う操作はしない。

**公開ログ**: 公開の標準出力・標準エラーを捨てていたため、失敗の原因を追えなかった。
試行ごとに `runs/publish-<n>/` へ stdout・stderr・result.json を残し、保存前に既存の伏せ字処理で
マスクする。`ghs_`・`ghu_` 等の新しい token 形式（「.」「-」を含む）と URL の `user:password@` を
伏せ字の対象に加えた。credential helper の標準出力は token なので保存しない。
state の summary には失敗したコマンド（push / pr create）と終了コードを示す。
伏せ字は既知の形式の検出で、完全な秘密検出ではない（前節と同じ）。

**Codex の既定設定**: Ansible が `~/.codex/config.toml` を毎回置換していたため、Codex が user 設定へ
書く状態（trust、通知の確認済み、対話で選んだ model）と衝突し、apply のたびに消えて changed になり得た。
採用版 0.167.1 は `/etc/codex/config.toml` を system 層として読み、user 層（`~/.codex/config.toml`）が
上書きする（[公式](https://developers.openai.com/codex/config-basic)、
[loader](https://github.com/openai/codex/blob/rust-v0.167.1/codex-rs/config/src/loader/mod.rs)、
[層の優先度](https://github.com/openai/codex/blob/rust-v0.167.1/codex-rs/config/src/config_layer_source.rs)）。
そこで model=`gpt-6.1-sol`、effort=`medium`、`check_for_update_on_startup=false` を root 所有の
`/etc/codex/config.toml` へ移し、`~/.codex/config.toml` は Ansible が作らず触らない。
`managed_config.toml` / `requirements.toml` は強制と制約の仕組みで、既定値の置き場ではないため使わない。
既存 Runner に残る旧版の `~/.codex/config.toml`（同じ値）は、既定を変えるときに本人が消す。
dsh の `~/.dsh/cordis.patch.yml` は従来どおり apply で戻す。
実機で `/etc/codex/config.toml` の既定が効くことは **未検証**。

## 2026-11-12 補足: staging 更新 workflow の deploy key 化（実装）

前節の方針を実装した。`stashpad-staging-image.yml` は `permissions: contents: read` に下げ、
environment `stashpad-staging-bot`（mainだけを許可）のActions secret `STASHPAD_STAGING_DEPLOY_KEY`
（書込可能deploy key `stashpad-staging-bot` の秘密鍵）を `actions/checkout` の `ssh-key` に渡して、
SSHでmainへpushする。commit名義はgithub-actions[bot]のまま。
鍵・environment・secretは本人が `scripts/stashpad-staging-deploy-key-setup.sh` で作る。

deploy keyのpushは `GITHUB_TOKEN` と違いpush契機のworkflowを起動する。全workflowの `on:` を確認し、
staging composeだけを変えるcommitで動くのは `validate.yml`（contents: read、公開なし）だけである。
`DeployKey` bypassはrepoの全deploy keyに効くため、書込可能deploy keyはこの1本だけにする。
鍵が漏れるとmainへ直接pushでき、15分以内にApps VMへ反映されうる。secretをmain限定environmentに置き、
Hermes Appに触らせない（Secrets・Administration・Workflows権限なし）ことで抑える。
手順、漏えい時の対応、scope確認、onboardingの順序は
[運用書](../operations/hermes-agent.md#homelab-の-github-actions-による-main-更新)。
実機でのdeploy key作成、bypassの効果、App追加後の動作は **未検証** で、手順3〜6の結果で確認する。
