# 実行時secret

Apps VM用のsecretは、このdirectoryの`runtime.sops.yaml`としてSOPS/ageで暗号化し、main branchに
保存する。age identityの復旧copyはKeePassXCに保存し、GitやApps VMへ配置しない。keyの一覧と形式は
[runtime.yaml.example](runtime.yaml.example)を参照する。

`/etc/homelab/secrets/searxng.env`（SearXNGの`SEARXNG_SECRET`）だけはこのbundleに含めない。初回の
`make ansible-apply`でAnsibleがApps VM上に生成し、以後は上書きしない。backupは不要で、Apps VMを
作り直せば再生成される。

## Terraform stateの正本と端末移行

[ADR-0016](../../../docs/adr/0016-terraform-state-sync-lock.md)により、age暗号化した
`origin/state-backup`を正本とし、local stateは各rootの実行用copyにする。
**初回移行は既存管理端末で、この変更を使う前に`make state-backup`を実行して全rootを最新にする**。
tailscale-gatewayのlocalがbackupより新しい場合も同じで、新端末のplanを先に行わない。

`terraform-plan` / `tailscale-plan`にも復号用`AGE_IDENTITY_FILE`が必要。
同期はlineage/serialと同serialのJSON内容を比較し、backupが新しければlocalを0600の
`terraform.tfstate.pre-sync.<UTC時刻>`へ退避する。localが新しければ`make state-backup`を促して停止する。
fetch失敗も停止し、明示的な`STATE_SYNC=skip`だけが警告付きの同期省略となる。

apply/importはpreflight・共有lock・同期を通し、失敗時も変更したstateをbackupする。
backup失敗ならlockを残す。`make state-lock-status`は公開lock情報を読むだけで、
`make state-unlock CONFIRM=<SHA先頭12文字以上>`は停止・backup確認後の明示解除用。
手動backup/restoreもlockを取る。復号平文は0700の一時directoryで扱い、trapで消す。
local state・退避copyはGit ignoreと0600検査の対象で、storage暗号化を前提にする。

公開鍵だけでも偽stateを暗号化できるため、stateブランチへのpush権限が信頼境界になる。
main保護だけではHermes Appやstaging deploy keyのstate書込みを防げない。
本人だけがbypassできる専用rulesetをコードで用意したが、GitHubへの適用は未検証。
自動同期前の反映・新端末での鍵/SSH/tfvars準備・lock復旧は
[作業端末手順](../../../docs/operations/workstation-setup.md)を参照する。
tfvarsは不要。既存fileは作業端末手順に従って退避し、7 rootのNo changes確認後に削除する。

## operator認証情報（ADR-0017）

age鍵の既定pathは`~/.config/sops/age/keys.txt`。Makeはhost scriptにもexportする。
公開recipientは`age-recipient.txt`だけに既定値を持つ。`AGE_IDENTITY_FILE`と`AGE_RECIPIENT`の明示指定が優先する。

| bundle | トップレベルの文字列キー |
| --- | --- |
| `operator/proxmox.sops.yaml` | `TF_VAR_proxmox_api_token` |
| `operator/tailscale.sops.yaml` | `TAILSCALE_OAUTH_CLIENT_ID`、`TAILSCALE_OAUTH_CLIENT_SECRET`、または`TAILSCALE_API_KEY`だけ |

SOPS 3.10.2 exec-envの制約に合わせ、ネストや数値・配列は使わない。以下はrepo rootで実行する（実機未検証）。

```sh
make operator-secrets-set PROVIDER=proxmox
make operator-secrets-set PROVIDER=tailscale
make operator-secrets-check PROVIDER=proxmox
make operator-secrets-check PROVIDER=tailscale
```

ホストのBash `read -rs`で入力し、stdinでtoolboxの`sops encrypt`へ渡す。平文をディスクに書かない。
TailscaleはOAuth（既定）またはAPI keyを選ぶ。既存fileを置き換えるときは`y`の確認が必要。
暗号化成功後にだけrenameして置換し、一時fileにも暗号文だけを書く。
checkはメモリ内で復号して形式を検査し、値を出さずキー名だけ表示する。
平文の誤追加や暗号化していない値は`make secrets-scan`で拒否する。

対応するproviderのTerraformだけへtoolbox内の`sops exec-env`で注入する。明示環境変数が同名bundle値より優先し、
未指定分をbundleで補う。Tailscaleは明示API keyを優先し、明示OAuthの一部があればOAuth方式を選ぶ。
異なる方式のbundleでは足りないOAuth項目を補えないため、2項目とも指定するかbundleを更新する。
bundleが無ければ従来の環境変数allowlistを使い、両方なければ説明付きで停止する。
bundleが存在するときの復号失敗・形式不正は停止する。provider認証情報をVMへ配布しない。
KeePassXCにはage鍵の復旧コピーとprovider認証情報の控えを残す。

## VMの初期SSH公開鍵

`../terraform/bootstrap-ssh-key.pub`は、作業端末の公開鍵1行をコメント付きで保存する公開情報である。
既存VMの作成時の値に合わせ、apps-vm・agent-vm・runner-vm・tailscale-gatewayは行全体、
elastiflow・stashpad-devは先頭2フィールドをnull/未指定時の既定値にする。明示のTF_VARは加工せず優先する。
この形式でNo changesとなることは本人の実機planで確認済みで、repo既定値への切替後の実機planは未検証。
コメントに含まれるユーザー名・ホスト名の公開は本人了承済み（[ADR-0017](../../../docs/adr/0017-operator-defaults.md)）。

## Agent VM用bundle

Agent VMのsecretは`agent/runtime.sops.yaml`として同じSOPS/ageで暗号化し、
[agent/runtime.yaml.example](agent/runtime.yaml.example)のkey一覧に従う。暗号化・復号確認は
`make secrets-encrypt-agent` / `make secrets-decrypt-check-agent`を使う。Discordのbot tokenと
channel ID、監視用webhook、Webapp認証、任意のGitHub App（`github_app.app_id`、
`installation_id`、PEM `private_key`）が対象。App鍵はcontroller復号後にRunnerのgh-brokerだけへ
専用 `/etc/gh-broker`（gh-broker所有0700）の `github-app.pem` と `github-app.json` へ
0400で配布し、Agentコンテナには渡さない。旧 `/etc/homelab/secrets/github-app.{pem,json}` はapply時に削除する。3項目未登録時は公開を無効化する。
repo追加は本人のgh認証でonboardスクリプトを実行してmainのrulesetを付けた後、
[App設定画面](https://github.com/settings/installations/180956595)のRepository accessで本人が行う。
スクリプトはinstallation APIを使わず、checkもrulesetの確認だけを行う。
GitHub Freeのprivate repoはrulesetで守れない。App対象をpublic repoだけにするか、Proにするか、
保護できないリスクを承知して追加するかは本人が判断する。個人repoでGitHub Actionsのbypass登録はできない。
homelabは別PRで毎時staging更新のpushをdeploy key（Actions secret、main限定environment）へ移し、
`--allow-deploy-key-bypass`でonboardingするまでAppのインストール先から外しておく。
このdeploy keyはRunner用SOPS bundleへ入れず、Hermes Appと共有しない。
登録・失効は[Hermes運用](../../../docs/operations/hermes-agent.md#github-app-による公開pr-②)を参照。
PostgreSQL passwordとSSH鍵はVM上で生成するためbundleへ
含めない。

## Tailscale ACL全文の正本

`tailscale/acl-policy.sops.json`は、既存age鍵で暗号化したreview済みACL全文のSOPS binary形式の正本である。plan/import時にはtoolbox内の固定パス
`tmp/tailscale-acl/policy.json`（親0700・file0600、Git ignore対象）へ一時復号する。
saved planのapplyでも、`terraform show -json`の保存変数`acl_policy_file`をメモリ内で確認し、
既定パスなら同じ場所へ再復号する。JSONの内容は表示せず、applyに`-var`も追加しない。
明示パスのplanは元のfileを検査して使い、自動復号・削除しない。旧ランダムパスのplanは作り直す。
固定directoryが既にあれば停止し、自分が作成したfile/directoryだけを成功・失敗・TERM時に削除する。
live.jsonと正本の不一致はapplyでも停止する。この実機apply手順は未検証。
更新・復元は[Tailscale手順](../terraform/tailscale/README.md#acl全文の復旧用コピー2026-10-25)に従う。

## 初回作成

1. 管理端末で`age-keygen`を実行し、identityをmode `0600`で保存する。host上で実行する場合はhost版ageが
   必要である。Makefileに鍵生成targetはない。[toolboxのDockerfile](../../tools/homelab-toolbox/Dockerfile)は
   `age`と`age-keygen`を含むが、toolboxでの鍵生成用wrapperは用意されていない。
2. identityとpublic recipientをKeePassXCの復旧entryへ保存する。
3. `runtime.yaml.example`をignore対象の
   `files/infrastructure/secrets/runtime.yaml`へcopyし、mode `0600`で実値を入れる。
4. 次のMake targetで暗号化し、復号できることを確認する。SOPS/ageはtoolbox内で実行するため、
   管理端末へhost版sopsをinstallする必要はない。

```sh
export AGE_RECIPIENT='age1...'
make secrets-encrypt AGE_RECIPIENT="$AGE_RECIPIENT"
AGE_IDENTITY_FILE=/secure/path/age-identity.txt \
  make secrets-decrypt-check
make secrets-scan
```

`secrets-encrypt`は既存の`runtime.sops.yaml`を上書きせず、入力と出力を固定して保護する。復号確認後は
ignore対象の平文`runtime.yaml`を削除する。このfileが一時的でもlocal storageに作成されることを前提に、
管理端末の暗号化と物理アクセス境界を決める。

## 既存bundleの編集

`make secrets-encrypt`は初回作成専用で、既存bundleの編集には使わない。repository rootで、Makefileと
同じdigest固定toolboxの`sops set`を使う。以下は`adguard.username`を変更する例であり、値を置き換える。
[sparkDash運用](../../../docs/operations/sparkdash.md)の実施例から汎用部分を抜き出した手順で、
実装から導いた手順で、実機では未検証である。

```sh
export AGE_IDENTITY_FILE=/secure/path/age-identity.txt
TOOLBOX_IMAGE="$(sed -n 's/^TOOLBOX_IMAGE_REPO ?= //p' Makefile)@$(sed -n 's/^TOOLBOX_IMAGE_DIGEST ?= //p' Makefile)"
sops_toolbox() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$PWD:/workspace" -w /workspace \
    -v "$AGE_IDENTITY_FILE:/run/secrets/age-identity:ro" \
    -e SOPS_AGE_KEY_FILE=/run/secrets/age-identity \
    -e HOME=/tmp/homelab-toolbox "$TOOLBOX_IMAGE" sops "$@"
}
sops_toolbox set files/infrastructure/secrets/runtime.sops.yaml '["adguard"]["username"]' '"<新しいユーザー名>"'
chmod 0600 files/infrastructure/secrets/runtime.sops.yaml
AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make secrets-decrypt-check
make secrets-scan
```

`sops set`の値はJSONで渡し、既存keyを保持する。値は短時間process listに見えるため、logへ残さない。
編集後はfileが`0644`になるため`chmod 0600`を行い、暗号化bundleだけをreview対象にする。
管理端末の最新checkoutとApps VMのcheckoutを確認し、SSH agentにdeploy用鍵を用意してから反映する。
Gitで取り込んだfileもmodeが戻り得るため、apply直前に設定する。

```sh
chmod 0600 files/infrastructure/secrets/runtime.sops.yaml
AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make ansible-apply
```

## 配置の境界

`AGE_IDENTITY_FILE`はMakefileがtoolboxの`/run/secrets/age-identity`へread-onlyでmountする。Ansibleは
管理端末側でだけbundleを復号し、個別のruntime fileをApps VMの`/etc/homelab/secrets`へroot所有、mode
`0600`で配置する。

bundleのpathはAnsibleの`runtime_secrets_file`で指定する。配置の実装は
[secrets role](../ansible/apps/roles/secrets/tasks/main.yml)にある。
runtime secretやAdGuard設定が変わると`secrets_runtime_changed`が立ち、
[Compose role](../ansible/apps/roles/compose/tasks/main.yml)がcutover有効時に
`HOMELAB_FORCE_RECREATE=true`で`homelab-compose-up all`を実行する。
宣言済みの全12 projectsがforce-recreateされ、DNS・SMBも短時間途切れる。

`runtime.sops.yaml`はapplication cutoverを有効化する前に必要になる。それまでのフェーズ1 bootstrapでは
secretを復号せず、containerも起動しない。

sparkDashの必須token（`sparkdash.token`）は64桁の16進文字列として検証し、root:root `0600`の
`sparkdash.env`へ配置する。
任意SSH鍵（`sparkdash.ssh_private_key`）は専用directoryを常に作成し、値があるときだけ
uid/gid `10001:10001`、mode `0400`で配置する。directoryは`0500`で、read-only mountする。
任意keyを省略/空にしてapplyすると配置済み鍵を削除する。生成・SOPS編集・反映順序は
[sparkDash運用](../../../docs/operations/sparkdash.md)を参照する。

## 任意のHugging Face token

`hf_downloader.token`はprivate/gated repository向けの任意のread tokenである。keyまたは
`hf_downloader`自体を省略してもよい。省略/空でapplyすると、既存の値も空に戻す。
secrets roleは`/etc/homelab/secrets/hf-downloader/hf-token`を常に配置し、uid/gid `10002:10002`、
file mode `0400`、directory mode `0500`とする。containerへはdirectoryをread-only bindする。

既存bundleへ追加するときは上記「既存bundleの編集」の`sops_toolbox`を使い、次のkeyを設定する。
以下は形式だけの例であり、実値をlogやGitへ残さない。

```sh
sops_toolbox set files/infrastructure/secrets/runtime.sops.yaml '["hf_downloader"]["token"]' '"<Hugging Face read token>"'
```

同じ手順で`chmod 0600`、復号確認、暗号化bundleのreviewを行い、checkout更新後に明示適用する。
tokenの追加・変更・空への変更でも`secrets_runtime_changed`が立ち、全12 projectsが再作成される。
Daguの初期管理者はbundleに含めず、デプロイ直後に`/setup`で作成する。
初回反映・確認は[hf-downloader運用](../../../docs/operations/hf-downloader.md)を参照する。

## pve1 NUT用bundle

`pve1/runtime.sops.yaml` は、運用者が下記の手順で2026-10-31に作成済み。
ageのrecipientは既存bundleと同じで、`make secrets-scan` はcleanだった（運用者報告）。
[example](pve1/runtime.yaml.example)の
`nut.upsmon_primary_password` と `nut.upsmon_secondary_password` を含める。
webhook は複製せず、pve1 play が Apps bundle の `gatus.discord_webhook_url` だけを抽出する。
以下は作り直す際のために残す初回作成手順。管理端末の Python 3 で独立したランダムな64桁hexを作り、
値を端末・引数に出さず、ignore済みの平文へ mode 0600 で書く。既存ファイルがあれば拒否する。

```sh
python3 - <<'PY'
import os
import secrets
path = 'files/infrastructure/secrets/pve1/runtime.yaml'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as out:
    out.write('nut:\n')
    for name in ('primary', 'secondary'):
        out.write(f'  upsmon_{name}_password: {secrets.token_hex(32)}\n')
PY
export AGE_RECIPIENT='age1...'
make secrets-encrypt-pve1
rm files/infrastructure/secrets/pve1/runtime.yaml
make secrets-scan
```

`secrets-encrypt-pve1` は既存bundleを上書きしない。作り直す際も、既存bundleの扱いを別途確認してから行う。
復号の確認は、鍵を指定した pve1 の `--check --diff` で必要keyの検証とともに行う。
平文は暗号化成功を確認してから削除し、管理端末のstorage暗号化を前提とする。
既存の plaintext/state scan は全階層の `runtime.yaml` を拒否し、SOPS metadata も全bundleを検査する。
DGX担当へは承認済みの秘密情報受け渡し経路で secondary の値だけを渡す。docs・ログには書かない。
