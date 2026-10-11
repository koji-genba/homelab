# 実行時secret bundleの構造

`site.yml`は、通常は`files/infrastructure/secrets/runtime.sops.yaml`となる
`runtime_secrets_file`を、管理端末上のage暗号化SOPS YAML fileとして想定する。controllerが復号し、
個別のmode `0600` fileとしてApps VMへcopyする。age private keyをApps VMへcopyすることはない。
secretではないkey inventoryは`files/infrastructure/secrets/runtime.yaml.example`を参照する。

唯一の例外が`/etc/homelab/secrets/searxng.env`（SearXNGの`SEARXNG_SECRET`）である。bundleには入れず、
初回のapplyでAnsibleがApps VM上に生成し、以後は上書きしない。backupは不要で、Apps VMを作り直せば
再生成される。

sparkDashの必須token（`sparkdash.token`）はroot:root `0600`の`sparkdash.env`へ配置する。
任意SSH鍵（`sparkdash.ssh_private_key`）は専用directoryを常に作成し、値があるときだけ
uid/gid `10001:10001`、mode `0400`で配置する。directoryは`0500`で、read-only mountする。
任意keyを省略/空にしてapplyすると配置済み鍵を削除する。生成・SOPS編集・反映順序は
[sparkDash運用](../../../../../../docs/operations/sparkdash.md)を参照する。
