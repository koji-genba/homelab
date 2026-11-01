# Hermes Agent 派生イメージ

上流 main の固定イメージに、固定 commit の Hindsight integration と
`hindsight-client==0.10.2`、remote MEDIA の session key patch を追加する。
固定先は `Dockerfile` を正とする。公開タグは `main-c7da41dd`。
Compose の本番 digest 更新は別の変更で行う。

Python 3.14 の sealed venv に、PM が同梱した uv をビルド時だけ使って依存を追加する。
全既存パッケージの版が追加前後で一致しなければビルドは失敗する。
最後に上流の `docker.build_agent` で source binding と launcher を再作成する。
`hindsight-embed` は導入せず、provider は `local_external` 用として扱う。
実行時の lazy install は上流では既定で許可されるため、運用設定で
`security.allow_lazy_installs: false` を明示する。

## 依存ロックの再生成

repo root で実行する。ベース更新時は必ず実際のベース環境から採取し直す。
ホスト側の Python や uv で生成しない。コンテナへ渡すのはこのディレクトリだけで、
認証情報や設定 volume は渡さない。

```bash
image_dir="$PWD/files/services/images/hermes-agent"
base_image="$(sed -n 's/^ARG HERMES_IMAGE=//p' "$image_dir/Dockerfile")"
docker run --rm --init --memory 6g \
  --user "$(id -u):$(id -g)" --env UV_CACHE_DIR=/tmp/uv-cache \
  --mount "type=bind,src=$image_dir,dst=/lock" \
  --entrypoint /opt/hermes/.venv/bin/python \
  "$base_image" /lock/regenerate-requirements.py
```

`regenerate-requirements.py` は venv の全パッケージ版（Hermes 本体を除く）を
`base-constraints.txt` に保存し、その制約の下で Python 3.14 用の
`requirements.txt` を hash 付きで生成する。共有依存は上流の版を維持する。
PM の toolchain はベースに同梱されたものを読み取り専用で参照する。

## ローカル検証

```bash
image=homelab-hermes-agent:main-c7da41dd-e
docker build --memory 6g --tag "$image" \
  --file files/services/images/hermes-agent/Dockerfile files/services/images/hermes-agent
docker run --rm --init --memory 6g --network none --entrypoint hermes "$image" --version
docker run --rm --init --memory 6g --network none --entrypoint hermes "$image" webapp --help
docker run --rm --init -i --memory 6g --network none --entrypoint python "$image" - < scripts/tests/hermes-image-fixture.py
docker run --rm --init -i --memory 6g --network none --entrypoint python "$image" - < scripts/tests/hermes-remote-media-fixture.py
docker image inspect "$image" --format '{{.Id}} {{.Size}}'
```

PR の validate ジョブもイメージをローカルに load して同じ検査を行う。
fixture は provider の import と `register()`、Webapp の HTML/JS bundle、
patch の引数と呼び出しを検査する。MEDIA fixture はネットワークを使わず、
session context 消去後の配送、context の優先、配送制限の維持を検査する。
Hindsight API への実接続、ブラウザでの認証・WebSocket・画面操作はこの検査に含まない。

追加の `uv pip check` では、固定ベース自体に `browser-harness` が要求する
`pillow==12.3.0` と、導入済み `13.0.0` の不一致があることを確認した。
派生イメージでも同じ不一致が残る。上流依存を維持するため、ここでは変更しない。
ブラウザ harness の実動作への影響は未検証。

## Webapp 内の terminal

固定先の `hermes_cli/web_server_surface.py` は Webapp の `host_terminal` を
定数 `True` にしており、設定で止めるスイッチは確認できない。
手動 terminal は Runner の SSH backend と独立してコンテナ内の shell を起動する。
このイメージでは上流の動作を維持する。
代替策は Caddy で `/api/host-terminal` の WebSocket upgrade を拒否するか、
上流の surface policy に無効化設定を追加すること。Caddy の拒否だけでは
backend 直アクセスを止められないため、Agent の公開ポートの送信元制限も必要になる。
これらの代替策の実動作は未検証。
