# 実行時secret

Apps VM用のsecretは、このdirectoryの`runtime.sops.yaml`としてSOPS/ageで暗号化し、main branchに
保存する。age identityの復旧copyはKeePassXCに保存し、GitやApps VMへ配置しない。keyの一覧と形式は
[runtime.yaml.example](runtime.yaml.example)を参照する。

## 初回作成

1. 管理端末で`age-keygen`を実行し、identityをmode `0600`で保存する。
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

## 配置の境界

`AGE_IDENTITY_FILE`はMakefileがtoolboxの`/run/secrets/age-identity`へread-onlyでmountする。Ansibleは
管理端末側でだけbundleを復号し、個別のruntime fileをApps VMの`/etc/homelab/secrets`へroot所有、mode
`0600`で配置する。

`runtime.sops.yaml`はapplication cutoverを有効化する前に必要になる。それまでのフェーズ1 bootstrapでは
secretを復号せず、containerも起動しない。
