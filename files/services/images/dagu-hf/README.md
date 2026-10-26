# Dagu HF image

Dagu `2.22.4`（Ubuntu 24.04）と `huggingface_hub==2.3.0` の amd64 image。
公開 tag は `ghcr.io/koji-genba/dagu-hf:2.22.4-hf2.3.0`。
DAG・設定・ヘルパーは image に入れず、Compose から read-only bind する。
上流の sudo entrypoint は使わず、sudoers の追加設定と sudo の setuid bit を除去する。

## lock の再生成

空の作業 directory を scratchpad に作り、`work` にその絶対 path を設定する。
`requirements.in` を変更し、Dockerfile の `DAGU_IMAGE`（base）と同じ image の Python で解決する。base の digest は Dockerfile から読み、文書に書き写さない。
既存の wheels を混ぜない。次は管理端末から実行する。

```sh
base="$(sed -n 's/^ARG DAGU_IMAGE=//p' files/services/images/dagu-hf/Dockerfile)"
mkdir -p "$work/wheels"
docker run --rm --name hfdl-test-lock --memory 2g --entrypoint bash \
  -v "$PWD/files/services/images/dagu-hf:/src:ro" -v "$work:/work" \
  "$base" \
  -c 'apt-get update -qq && apt-get install -y -qq python3-venv &&
      python3 -m venv /tmp/lock &&
      /tmp/lock/bin/pip download --only-binary=:all: -r /src/requirements.in -d /work/wheels &&
      python3 /src/generate-lock.py /work/wheels > /work/requirements.txt'
cp "$work/requirements.txt" files/services/images/dagu-hf/requirements.txt
docker build -t dagu-hf:local-test files/services/images/dagu-hf
```

lock は対象環境で取得した wheel だけの hash を持つ。arm64 への流用はしない。
base 更新時は GHCR の manifest を取得し、実在する digest と Python 版を確認する。
workflow の公開 tag、label、運用手順書を一緒に変更する。公開後の Compose digest 反映は別 PR。
