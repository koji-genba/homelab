# 実行時secret bundleの構造

`site.yml`は、通常は`files/infrastructure/secrets/runtime.sops.yaml`となる
`runtime_secrets_file`を、管理端末上のage暗号化SOPS YAML fileとして想定する。controllerが復号し、
個別のmode `0600` fileとしてApps VMへcopyする。age private keyをApps VMへcopyすることはない。
secretではないkey inventoryは`files/infrastructure/secrets/runtime.yaml.example`を参照する。
