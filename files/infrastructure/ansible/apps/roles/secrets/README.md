# 実行時secret

実行時secretの構造・編集・配置手順は[中央README](../../../../secrets/README.md)を参照する。
配置の実装はこのroleの[tasks/main.yml](tasks/main.yml)にある。

任意の`hf_downloader.token`はuid/gid `10002:10002`、mode `0400`の
`/etc/homelab/secrets/hf-downloader/hf-token`へ配置する。directoryは同じ所有者で`0500`とする。
keyを省略した場合も空fileを配置し、配置変更を`secrets_runtime_changed`へ含める。
既存bundleへの追加は[中央READMEの任意token手順](../../../../secrets/README.md#任意のhugging-face-token)に従う。
追加時も全12 projectsが再作成される。
