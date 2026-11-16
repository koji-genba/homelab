# ADR-0016: 暗号化GitブランチをTerraform stateの正本にし、refでロックする

- 状態: 採用。repo実装済み、実端末間の運用・GitHub ruleset反映は未検証
- 日付: 2026-11-16
- 置換対象: [ADR-0005](0005-secrets-and-terraform-state.md)のstate正本・成功時backup・remote lockingなしの部分。SOPS/ageと鍵の保管方針は継続

## 背景と比較

利用者は一人だが、管理端末を替えるとactive stateが元端末に束縛される。
既存のrestoreは上書き禁止であり、継続的な端末間同期には使えない。
apply失敗時にもTerraformが途中のstateを書くため、成功時だけのbackupでは不足する。
例えばtailscale-gatewayのlocal stateがbackupより新しい場合、別端末で古いstateを使ってしまう。

| 案 | 利点 | 負担と判断 |
| --- | --- | --- |
| A: age暗号化Gitブランチ正本 + refロック | 既存Git remoteとage鍵で端末間同期でき、復旧依存を増やさない | Terraform backendではなく同期・比較・ロックを自前実装する。単一利用者で問題が端末への束縛なので採用 |
| B: 自宅内S3互換 + `use_lockfile` | TerraformのS3 backendとロックを利用できる | pve1障害時にbackendも失い、VMを復旧するためのstateを先に復旧する循環ができる。storage・認証・backupの運用も必要なため不採用 |
| C: HCP Terraform / 外部S3 | 自宅障害から独立し、サービス側のstate管理を使える | 新しい外部account、credential、復旧手順への依存が増える。現状の単一利用者では追加運用を採らず不採用 |

## 決定

`origin/state-backup`のage暗号化stateを正本へ格上げする。Terraformは各rootのdefault local backendを
引き続き使い、Makeがその前後で同期する。生のTerraform実行や別workspaceは運用対象にしない。

planと書込み操作の前にfetchし、toolbox内で復号する。全rootを検証してから配置する。
ローカルが無ければ0600で配置し、同lineageでbackupのserialが大きければ旧stateを
`terraform.tfstate.pre-sync.<UTC時刻>`へ0600で退避して置き換える。
同serialでJSON内容が等しければ何もしない。localのserialが大きい、lineage不一致、同serialで内容不一致は停止する。
backupに無いlocal rootは警告する。fetch失敗も停止し、明示的な`STATE_SYNC=skip`だけで同期を省略できる。
使用時は警告する。これは主にoffline plan用で、書込みのremote lockやbackupは省略できない。

復号平文は0700の一時directoryと0600のfileで扱い、trapで削除する。同期一時directoryは
Terraform directory内のignore対象名とし、同一filesystemのrenameで配置する。
pre-sync copyは既存`*.tfstate.*` ignoreとmode検査の対象で、機密情報として端末側で管理する。

書込みは `preflight → lock → sync → 操作 → 変更時backup → unlock` の順にする。
lockはホストGitの空tree/orphan `commit-tree`で作り、branch・index・作業treeを変更しない。
公開情報はUTC時刻、短いホスト名（`STATE_LOCK_HOST`で公開用別名可）、操作名、ランダムtokenだけとする。
取得は空のexpected値を持つ`--force-with-lease=refs/heads/state-lock:`による原子的作成、
解放は取得したSHAをexpected値にした削除にする。期限切れによる自動解放はしない。

apply/importの成功・失敗・INT/TERMにかかわらず、子processの終了を待ち、stateが変わっていれば
backupを試す。操作失敗の終了codeを保持する（外側のGNU makeは通常どおり失敗を2として返す）。
backup失敗時はlockを残し、元端末での復旧を案内する。SIGKILL・電源断でもlockは残る。
読取りplanはlockを取らず、他端末のlockがあれば警告する。実行中の変更によりsaved planが古くなれば、
Terraformのstale plan判定に従ってplanを作り直す。validateは同期も鍵も不要。

手動`state-backup`もlockを取り、古いlocalによる正本の巻戻しやlineage不一致を拒否する。
localに無いrootの暗号化コピーは削除しない。`state-restore`もlockで保護し、既存stateへの上書き禁止を維持する。
この2つは移行・復旧用なので事前syncはしない。

## 公開ブランチへの書込み権限

ageは公開鍵だけで暗号化できるので、暗号化だけでは正本への偽state注入を防げない。
[既存運用](../operations/hermes-agent.md#github-app-による公開pr-②)と`github-agent-repo.py`ではmainだけを保護しており、
Contents writeのHermes Appと書込可能staging deploy keyはstateブランチにもpushできる権限を持つ。
実際のinstallation/rulesetの現状は、この変更では取得していない。

`github-agent-repo.py protect-state` / `check-state`を追加し、stateの2ブランチにcreation/update/deletion/
non_fast_forward制限を設定する。個人repoのadmin（本人）だけをbypassとし、App・Actions・DeployKeyは入れない。
mainのdeploy key例外はstate用rulesetへ引き継がない。organization repoにはこの本人限定方針を適用しない。
コードは用意するが適用は別途本人が行う。正本の自動同期を始める前に保護を反映・確認する。

## 移行と制約

最初は**既存の管理端末で、この変更を使う前に`make state-backup`を実行し、正本を最新にする**。
古いbackupを新端末で先に使わない。tailscale-gatewayのlocalがbackupより新しい例もこの手順で解消する。
以降の端末準備・lock復旧は[作業端末の準備](../operations/workstation-setup.md)に従う。

これは複数人向けbackendではない。全rootで一つのlockを共有し、正本更新の途中失敗は人が復旧する。
GitHub障害中は書込みを止める。local平文state・退避copyの端末storage暗号化とage鍵の保護は継続する。
試験は一時bare remote・生成した試験用age鍵・架空stateで行い、実stateやGitHubには適用していない。
