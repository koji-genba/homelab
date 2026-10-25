# stashPadDev VM

TerraformでProxmox VE上にstashPad開発用VMを構築します。
本番Apps VMの再構築対象には含めず、このTerraformルートで別に管理します。

## VM

- **stashPadDev**: 192.168.10.41 (VMID 111)
- CPU: 8 cores
- Memory: 16GB
- Disk: 30GB
- Template: `template_vm_id` (default: 9000)
- Network: VLAN10 / `vmbr0`

## 再構築性とbackup

[main.tf](main.tf)はVMと基本ツールを構築します。開発環境は2026-10-25に
[開発環境の再構築](#開発環境の再構築)としてREADMEで宣言しました。手順は実機で通し実行しておらず、**未検証**です。
template 9000のimageの版・hash・詳細設定が固定されていない点は、別の穴として
[#87](https://github.com/koji-genba/homelab/issues/87)に残ります。
2026-10-12の運用者によるVM確認では、開発ツール、VS Code server、`~/stashPad`と
`~/stashpad-worktrees/`が手作業で入っていました。以下はその後の採取結果と、再構築時に採用する手順です。

VMを作り直すと、VMの中にしか無い作業（pushしていないcommit、未commitの変更）は失われます。
作り直す前に、残す変更をcommitし、未pushのcommitとともにpushしてください。
2026-10-12時点で、VMの中にしか無い作業がありました。
この作業は運用者が別途pushする扱いです。
2026-10-12に、運用者は重要ではないUbuntuの開発用VMとして、VM backupを取らないと決めました。
repoから再構築できるからではなく、失ってよいという判断によるものです。
VM全体の評価と方針は[現行アーキテクチャ](../../../../docs/architecture/target-state.md#再構築性とbackupの方針)を参照してください。

## 開発環境の再構築

Ubuntu 24.04（amd64）のtemplateをcloneし、cloud-initが完了した直後の`ubuntu` userから実行します。
復元するのは`~/stashPad`の基準checkout（`origin`の`main`）と、必要になったときのworktreeです。
**この手順は実機で通し実行していません（未検証）。** 既存VMへの上書き手順ではありません。

### 観測値と採用する目標

観測値は**2026-10-25に既存VMから採取した値**です。再構築時に同じpatch版を固定するものではありません。

| 対象 | 観測値（2026-10-25） | 採用する目標・導入元 |
| --- | --- | --- |
| OS | Ubuntu 24.04 / x86_64 | Ubuntu 24.04 / amd64。template 9000の固定は別途必要 |
| Docker / Compose | 29.1.3 / 2.40.3、daemon active、ubuntuはdocker group所属 | Ubuntuの`docker.io` / `docker-compose-v2`。版はUbuntu 24.04の配布に任せる |
| Node / npm | 20.20.2 / 10.8.2、NodeSourceの`nodejs` | `node_20.x` apt repoの`nodejs`（npm同梱）。major 20はstashPadの[Dockerfile](https://github.com/koji-genba/stashPad/blob/main/Dockerfile)のNode 20に合わせる。stashPad側の要求が変わったら追随する |
| Go | 1.25.0、`/usr/local/bin/go` → `/usr/local/go/bin/go`、dpkg管理外 | [backend/go.mod](https://github.com/koji-genba/stashPad/blob/main/backend/go.mod)の`go`行に合わせる（2026-10-25時点は1.25.0）。公式tarballを`/usr/local/go`へ展開 |
| Python | 3.12.3、pip / pip3なし、pip moduleも利用不可 | OS標準の`python3`（3.12）。pipは必要になったら追加する |
| git / make / gcc | 2.43.0 / 4.3 / 13.3.0 | Ubuntuの`git` / `make` / `gcc`。観測したmakeは`make` package、gccの実体は`gcc-13-x86-64-linux-gnu` package。`build-essential`一式の有無は断定しない |
| gh | 2.101.0、cli.github.comのapt repo | 同repoの`gh`。配布版に追随する |
| VS Code server | `~/.vscode-server`あり | workstationのVS Code Remote-SSHが初回接続時に自動導入するため、VM側では宣言しない。拡張機能もclient側から導入する |

`~/.local/bin`は存在しますが、中身は採取しておらず未確認です。
2026-10-25時点のworktreeは`~/stashPad`本体だけでした（branchは`main`）。
ローカル追跡情報との比較ではahead / behindとも0、追跡ファイルの変更は0でしたが、fetchはしていません。
この観測は、2026-10-12に記録したVM内だけの作業がすべてpush済みであることを保証しません。

### ツールの導入

Ubuntu packageを導入し、NodeSourceとGitHub CLIのapt repoを登録します。
登録方法の参照元は[NodeSourceの設定スクリプト](https://github.com/nodesource/distributions/blob/master/scripts/deb/setup_20.x)と
[GitHub CLIのLinux導入手順](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)です。

```bash
(
set -euo pipefail
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git make gcc python3 docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu

sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
sudo chmod 0644 /etc/apt/keyrings/nodesource.gpg
printf '%s\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main' | \
  sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
printf '%s\n' 'Package: nodejs' 'Pin: origin deb.nodesource.com' 'Pin-Priority: 600' | \
  sudo tee /etc/apt/preferences.d/nodejs > /dev/null

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
  sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
printf '%s\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' | \
  sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y nodejs gh
)
```

一度ログアウトし、`ubuntu` userで入り直してdocker groupを反映します。

### checkoutとGoの導入

```bash
git clone --origin origin --branch main https://github.com/koji-genba/stashPad.git ~/stashPad
```

Goはcheckoutした`backend/go.mod`の`go`行から版を選びます。
公式tarballのURLは`https://go.dev/dl/go<版>.linux-amd64.tar.gz`です。
[go.dev/dl](https://go.dev/dl/)で対象版（必要ならArchived versions）のLinux / amd64のSHA256を確認し、
以下の入力に使います。`sha256sum`の照合に成功した場合だけ、
[公式の導入方法](https://go.dev/doc/install)に従い展開します。既存の`/usr/local/go`がある場合は停止し、重ねて展開しません。

```bash
(
set -euo pipefail
go_version=$(awk '$1 == "go" { print $2; exit }' ~/stashPad/backend/go.mod)
test -n "$go_version"
go_archive="go${go_version}.linux-amd64.tar.gz"
go_tmp=$(mktemp -d)
trap 'rm -rf "$go_tmp"' EXIT
curl -fL "https://go.dev/dl/${go_archive}" -o "$go_tmp/$go_archive"
read -r -p "go.dev/dl の ${go_archive} のSHA256: " go_sha256
[[ "$go_sha256" =~ ^[[:xdigit:]]{64}$ ]]
(cd "$go_tmp" && printf '%s  %s\n' "$go_sha256" "$go_archive" | sha256sum -c -)
test ! -e /usr/local/go
sudo tar -C /usr/local -xzf "$go_tmp/$go_archive"
sudo ln -s /usr/local/go/bin/go /usr/local/bin/go
go version
)
```

### 依存導入と起動の入口

起動方法の正本はstashPadの[README「開発」節](https://github.com/koji-genba/stashPad#開発)です。
frontendは`package-lock.json`を使って`npm ci`、backendは`go mod download`で依存を導入します。

```bash
(cd ~/stashPad/frontend && npm ci)
(cd ~/stashPad/backend && go mod download)
```

backendには環境変数の準備が必要です。必須項目はstashPadの
[README「環境変数」節](https://github.com/koji-genba/stashPad#環境変数)に従い、値はここには記載しません。
それらを設定したterminalでbackendを、別terminalでfrontendを起動します。

```bash
# backend用terminal（必要な環境変数を設定してから）
cd ~/stashPad/backend
go run ./cmd/stashpad
```

```bash
# frontend用terminal
cd ~/stashPad/frontend
npm run dev
```

worktreeが必要な場合だけ、基準checkoutから作成します。以下のbranch名は作業に合わせて変えます。
worktree側でも依存導入と起動はstashPadのREADMEに従います。

```bash
mkdir -p ~/stashpad-worktrees
git -C ~/stashPad worktree add -b feature/example ~/stashpad-worktrees/example main
```

導入後は以下でtoolとcheckoutを確認します。Docker操作は再ログイン後に実行します。
開発サーバーの確認方法・portはstashPadのREADME「開発」節を参照し、停止は各terminalで`Ctrl-C`します。

```bash
docker --version
docker compose version
docker info > /dev/null
node --version
npm --version
go version
python3 --version
git --version
gh --version
make --version
gcc --version
git -C ~/stashPad branch --show-current
git -C ~/stashPad worktree list
```

## Apply

このrootでは全6 Proxmox root共通のtoken `terraform@pve!terraform`を使います。
2026-10-25に共通tokenへ移行済み（[記録](../../../../docs/operations/apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)）。
実行前にKeePassXCから`TF_VAR_proxmox_api_token`を管理端末へ一時注入します。
Makeはこの環境変数をProxmox Terraform runnerへ名前で渡すため、値をMakeの出力へ展開しません。
tokenはrepository、tfvars、runtime SOPS bundle、VMへ保存しません。作業後は
`unset TF_VAR_proxmox_api_token`で管理端末の環境から削除します。

`terraform.tfvars.example`を同じdirectoryの`terraform.tfvars`へコピーし、`ssh_public_key`など
非秘密の値だけを設定します。既存ファイルは上書きしません。tfvarsはGit ignore対象です。
Proxmoxのuser / role / token / ACLの期待状態と既存環境からの移行は
[Proxmox側準備](../../../../docs/operations/apps-vm-recovery.md#terraform実行前のproxmox側準備)を正とします。

API認証とは別に、cloud-init snippetのアップロードにpve1の`root` SSHが必要です。
管理端末のssh-agentへ接続用の鍵を読み込み、`SSH_AUTH_SOCK`と`ssh-add -l`を確認します。
信頼できる経路でpve1のhost keyを照合して`known_hosts`へ登録します。Makeはagent socketと
`known_hosts`をtoolboxへmountします。`ssh_public_key`はguestへ配置する公開鍵で、providerのSSH認証とは別です。

repository rootから設定を用意します。他rootのtfvarsを`-var-file`で共有せず、このrootの入力を使います。
以下のうち plan までは2026-10-25に実機で確認済み。apply は未検証です。

```bash
cp files/infrastructure/terraform/stashpad-dev/terraform.tfvars.example files/infrastructure/terraform/stashpad-dev/terraform.tfvars
chmod 0600 files/infrastructure/terraform/stashpad-dev/terraform.tfvars
# このrootのterraform.tfvarsを編集してから実行
make terraform-plan TERRAFORM_ROOT=files/infrastructure/terraform/stashpad-dev
make terraform-apply TERRAFORM_ROOT=files/infrastructure/terraform/stashpad-dev
```

保存planをreviewしてからapplyします。applyにはstate backupの入力も必要です。

## Terraform state

active stateはこのルートのlocal `terraform.tfstate`で、Git ignore対象です。
上記の`make terraform-apply`は成功後にstate backupを実行します。raw `terraform apply`を使う場合は、
成功後にrepository rootでこのルートのstateも収集する`make state-backup`を実行します。
backup / restoreの仕組みと前提は[ADR-0005](../../../../docs/adr/0005-secrets-and-terraform-state.md)と
[state-backup.sh](../../../../scripts/state-backup.sh) / [state-restore.sh](../../../../scripts/state-restore.sh)を参照してください。

## Connect

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.10.41
```

## トラブルシューティング

2026-10-25に、ホストで過去に`-plugin-dir=../elastiflow/.terraform/providers`を使ってinitした
`.terraform/`にホストの絶対パスを指すprovider symlinkが残り、toolbox内のinitが失敗しました。
`.terraform/`を退避してinitし直すと通りました。同じ症状では、このrootの`.terraform/`だけを削除し、
repository rootから`make terraform-init TERRAFORM_ROOT=files/infrastructure/terraform/stashpad-dev`で
initし直してください。
