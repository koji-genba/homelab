# 実行時secret bundleの構造

`site.yml`は、通常は`files/infrastructure/secrets/runtime.sops.yaml`となる
`runtime_secrets_file`を、管理端末上のage暗号化SOPS YAML fileとして想定する。controllerが復号し、
個別のmode `0600` fileとしてApps VMへcopyする。age private keyをApps VMへcopyすることはない。
secretではないkey inventoryは`files/infrastructure/secrets/runtime.yaml.example`を参照する。

唯一の例外が`/etc/homelab/secrets/searxng.env`（SearXNGの`SEARXNG_SECRET`）である。bundleには入れず、
初回のapplyでAnsibleがApps VM上に生成し、以後は上書きしない。backupは不要で、Apps VMを作り直せば
再生成される。
