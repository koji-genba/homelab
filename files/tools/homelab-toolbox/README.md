# Homelab toolbox（実行環境）

このimageは、version固定したTerraform、Ansible、SOPS、age、shellcheckと各linterの実行環境である。
rootの`Makefile`はこれらのtoolをDocker経由で実行するため、管理端末に必要なのはGit、Docker、Make、SSHだけ
となる。baseはDockerfileで固定したOCI index digestの`debian:13-slim`で、Debian trixieの
`shellcheck=0.10.0-1`をinstallする。

公式AdGuard Home v0.107.79 amd64 checkerも組み込む。release archiveのSHA256
`c48f4a43000665484c5ec28177de11a004759b620dae8f77b2aabefc9ef3687f`を検証してから配置し、fixtureは
`--check-config`の前に展開したbinaryのchecksumを検証する。

正確なlocal tagを`make toolbox-build`でbuildするか、review済みimage workflowを通して同じimageを
`ghcr.io/koji-genba/homelab-toolbox:1.0.1`としてpublishする。

**Makefileはtoolboxをtagではなくdigestで固定して実行する。** publish workflowは
`.github/workflows/toolbox-image.yml`自身の変更でも起動し、同じ`:1.0.1`タグを上書きするため、
タグ参照では引かれるimageが再現しない。2026-09-06のPR #8（`actions/checkout`のbump）は
Dockerfileを変えていないのにタグを`sha256:7607f2c7...`から`sha256:9da8408a...`へ移した。
`compose.yaml`が全imageをdigest固定するのと同じ規律をtoolboxにも適用している。

- 実行に使う参照は`TOOLBOX_IMAGE`（`TOOLBOX_IMAGE_REPO@TOOLBOX_IMAGE_DIGEST`）である。
- `make toolbox-build`がlocalに付けるtagは`TOOLBOX_BUILD_IMAGE`（`TOOLBOX_IMAGE_REPO:TOOLBOX_IMAGE_TAG`）で、
  実行用の参照とは分離してある。
- imageを更新するときは、workflowのpublish後に
  `docker buildx imagetools inspect ghcr.io/koji-genba/homelab-toolbox:1.0.1`で新しいdigestを確認し、
  Makefileの`TOOLBOX_IMAGE_DIGEST`を差し替える。
- localでbuildしたimageを試すときは`make TOOLBOX_IMAGE=$(TOOLBOX_BUILD_IMAGE) <target>`のように上書きする。wrapperはrepositoryを呼び出し元のUID/GIDで
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
