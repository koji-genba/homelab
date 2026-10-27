# 実行時secret

Apps VM用のsecretは、このdirectoryの`runtime.sops.yaml`としてSOPS/ageで暗号化し、main branchに
保存する。age identityの復旧copyはKeePassXCに保存し、GitやApps VMへ配置しない。keyの一覧と形式は
[runtime.yaml.example](runtime.yaml.example)を参照する。

`/etc/homelab/secrets/searxng.env`（SearXNGの`SEARXNG_SECRET`）だけはこのbundleに含めない。初回の
`make ansible-apply`でAnsibleがApps VM上に生成し、以後は上書きしない。backupは不要で、Apps VMを
作り直せば再生成される。

## Agent VM用bundle

Agent VMのsecretは`agent/runtime.sops.yaml`として同じSOPS/ageで暗号化し、
[agent/runtime.yaml.example](agent/runtime.yaml.example)のkey一覧に従う。暗号化・復号確認は
`make secrets-encrypt-agent` / `make secrets-decrypt-check-agent`を使う。Discordのbot tokenと
channel ID、監視用webhookが対象で、PostgreSQL passwordとSSH鍵はVM上で生成するためbundleへ
含めない。

## Tailscale ACL全文の復旧用コピー

`tailscale/acl-policy.sops.json`は、既存age鍵で暗号化したreview済みACL全文のSOPS binary形式の復旧コピーである。
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
