# Homelab toolbox（実行環境）

このimageは、version固定したTerraform、Ansible、SOPS、age、shellcheckと各linterの実行環境である。
rootの`Makefile`はこれらのtoolをDocker経由で実行するため、通常運用のwrapperには管理端末のGit、Docker、Make、SSHが
必要となる。host上で実行する検証fixtureには次の追加依存がある。

- Python 3とPyYAML: `make ansible-bootstrap-paths-test`（[fixture](../../../scripts/tests/ansible-bootstrap-paths-fixture.sh)）、`make cloud-init-test`（[fixture](../../../scripts/tests/cloud-init-apps-vm-fixture.sh)）。
- Python 3: `make terraform-apps-vm-lifecycle-test`（[fixture](../../../scripts/tests/terraform-apps-vm-lifecycle-fixture.sh)）、`make compose-reconcile-fixture`（[fixture](../../../scripts/tests/compose-reconcile-fixture.sh)）。
- Docker Compose: `make compose-config`はhostのDocker Composeで[compose-config.sh](../../../scripts/compose-config.sh)を実行する。

baseはDockerfileで固定したOCI index digestの`debian:13-slim`で、Debian trixieの
`shellcheck=0.10.0-1`をinstallする。
publishするimageは`linux/amd64`であり、Dockerfileが取得するtool binaryもlinux/amd64用である。

公式AdGuard Home v0.107.79 amd64 checkerも組み込む。release archiveのSHA256
`c48f4a43000665484c5ec28177de11a004759b620dae8f77b2aabefc9ef3687f`を検証してから配置し、fixtureは
`--check-config`の前に展開したbinaryのchecksumを検証する。

正確なlocal tagを`make toolbox-build`でbuildするか、review済みimage workflowを通して同じimageを
`ghcr.io/koji-genba/homelab-toolbox:1.0.1`としてpublishする。

**Makefileの通常実行はtoolboxをtagではなくdigestで固定する。** publish workflowは
`.github/workflows/toolbox-image.yml`自身の変更でも起動し、同じ`:1.0.1`タグを上書きするため、
タグ参照では引かれるimageが再現しない。2026-09-06のPR #8（`actions/checkout`のbump）は
Dockerfileを変えていないのにタグを`sha256:7607f2c7...`から`sha256:9da8408a...`へ移した。
`compose.yaml`が全imageをdigest固定するのと同じ規律をtoolboxにも適用している。

- 実行に使う参照は`TOOLBOX_IMAGE`（`TOOLBOX_IMAGE_REPO@TOOLBOX_IMAGE_DIGEST`）である。
- `make toolbox-build`がlocalに付けるtagは`TOOLBOX_BUILD_IMAGE`（`TOOLBOX_IMAGE_REPO:TOOLBOX_IMAGE_TAG`）で、
  実行用の参照とは分離してある。buildだけでは通常実行のdigest参照は切り替わらない。
- `validate.yml` の static job は `TOOLBOX_BUILD_IMAGE` と `TOOLBOX_IMAGE` を同じ local tag
  `homelab-toolbox:ci` に設定し、その checkout で build した image を後続の検証に使う。
- imageを更新するときは、workflowのpublish後に
  `docker buildx imagetools inspect ghcr.io/koji-genba/homelab-toolbox:1.0.1`で新しいdigestを確認し、
  Makefileの`TOOLBOX_IMAGE_DIGEST`を差し替える。
- localでbuildしたimageを試すときは`make TOOLBOX_IMAGE=ghcr.io/koji-genba/homelab-toolbox:1.0.1 ansible-check`のように上書きする。repo名 / tagを変えた場合は実際のlocal build tagを指定する。

wrapperはrepositoryを呼び出し元のUID/GIDで
mountし、一時worktreeにはcontainer内で書込み可能な`/tmp`を使い、optional SSH agent socketをmountする。
`AGE_IDENTITY_FILE`を設定した場合だけ、そのfileを`/run/secrets/age-identity`へread-onlyでmountする。
hostの`~/.ssh/known_hosts`が存在する場合は、`/etc/ssh/ssh_known_hosts`としてread-onlyでmountする。

wrapperはroot-owned fileがcheckout内に作られないよう、container内の書込み可能な`HOME`を設定する。任意の
host UID/GIDでもOpenSSH/Ansibleが動くよう、entrypointはそのUID/GIDだけをprivate NSS passwd/group viewへ
追加する（`/etc/passwd`は変更しない）。age
private keyはApps VMに置かない。初回Ansible接続前に、Proxmox consoleまたは別の信頼できるout-of-band
channelからApps VMのhost-key fingerprintを確認し、VMが示すkeyと照合してから管理端末の`known_hosts`へ
追加する。検証していない単独の`ssh-keyscan`結果を信頼してはならない。

Make wrapperはallowlistしたTerraform/Tailscale provider環境変数名だけをDockerの`-e NAME`形式で渡す。
Makeやrepositoryへ値をinterpolateしない。provider credentialは、該当するplan/apply/import操作の間だけ
KeePassXCから管理端末へ取得する。runtime SOPS bundleの一部にはしない。

初回Terraform apply前に、`AGE_RECIPIENT`、読取り可能な`AGE_IDENTITY_FILE`、有効な`SSH_AUTH_SOCK`、
SSH origin（またはSSH `pushurl`）を指定して`make state-backup-preflight`を実行する。apply前にage roundtrip、
push URL、SSH agent socket、mode `0600`のlocal state、平文state scanを検証する。

`state-backup`はmodeが異なる既存stateを拒否し、暗黙に修復しない。toolbox内では暗号化、復号確認、
`state-backup` branchのlocal commitまでを行い、Terraform操作成功後のpushはhost Gitから実行する。
実行時はremote-trackingの`origin/state-backup`とlocal branchの履歴を同期確認する。remoteがlocalの先祖なら
localの先行commitを保持し、localがremoteの先祖ならremoteへ追随する。両者が分岐している場合は既存commitを
破棄せずfail closedするため、手動で履歴を解決してから再実行する。
任意host UIDを`/etc/passwd`へ追加しないtoolbox内のOpenSSHへpushを任せないためである。
`make state-backup-preflight`はtoolbox内のage roundtripと平文state scanに加え、host側でSSH pushの
dry-runを行う。SSH origin（またはSSH `pushurl`）とhost SSH agentをcredential境界として使い、hostの
credential helperやtokenをcontainerへmountしない。HTTPS state-backup pushはサポートしない。

## pip 依存の固定と更新

`requirements.txt` を唯一の version 定義とし、Ansible の直接・推移依存を
linux/amd64 / CPython 3.13 の wheel と SHA256 で固定する。形式は
`files/services/images/tei-reranker-onnx/requirements.txt` に合わせた。
Dependabot の `pip` がこのファイルを直接更新し、通常のバージョン更新は月次の
`toolbox-python` group で全パッケージを 1 本の PR にまとめる。
更新ごとの toolbox publish と固定 digest 更新の回数を抑えるためである。
`requirements.in` や uv lock は使わない。group の更新で新しい推移依存が必要になると、
CI の `make toolbox-build` は `--require-hashes` により未固定の依存を拒否する。
その場合は以下の `make toolbox-requirements` で closure と hash を再生成してレビューする。

system Python と `/usr/local/bin` のコマンド名を維持するため venv は使わず、
`--break-system-packages --ignore-installed --require-hashes --only-binary=:all:` で入れる。
apt の Jinja2 / PyYAML / MarkupSafe / packaging も同じ requirement として必ず取得・検証し、
`/usr/local/lib/python3.13/dist-packages` が apt の `/usr/lib/python3/dist-packages` より優先される。
apt 管理のファイルは消さない。`python3` からも固定した Jinja2 / yaml を import できる。
既存インストールを理由に hash 検証を省略しないため `--ignore-installed` が必要である。
pip と wheel は apt の管理用パッケージとして残し、この runtime closure の固定対象外とする。

初回の版は既存の公開 toolbox に合わせた。ただし MarkupSafe は 2.1.5 に
CPython 3.13 wheel がないため 3.0.4 に更新した。sdist のビルド依存を追加せず、
すべてのインストールを hash 検証済み wheel に限定するための意図した変更である。

更新時は `requirements.txt` の必要な version を編集し、repository root から以下を実行する。
生成には `Makefile` の `TOOLBOX_IMAGE` で digest 固定した toolbox を使い、
スクリプトが Python 3.13 と pip 25.1.1 を確認する。
生成コンテナは toolbox ディレクトリだけを mount し、呼び出し元の UID/GID で実行して終了時に破棄する。
鍵・SSH agent・認証設定は渡さない。

```sh
make toolbox-requirements
```

`regenerate-requirements.py` は既存 pins を読み、pip 25.1.1 で公開 PyPI の wheel closure を
解決し、ダウンロードした wheel の SHA256 を書き戻す。入力と出力の version 定義は同じファイルにある。
更新で不要になった依存は、親の metadata を確認して pin を削除してから再生成する。
生成後は hash を PyPI JSON の公開 SHA256 と照合し、専用タグで 2 回 `--no-cache` build して
freeze / 配置先の一致、`pip check`、read-only make 検証を確認する。
apt と ansible.posix collection はこの hash 固定の対象外である。
publish 後の `TOOLBOX_IMAGE_DIGEST` 更新は別 PR とする。
