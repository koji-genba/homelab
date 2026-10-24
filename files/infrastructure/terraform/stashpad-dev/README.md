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

[main.tf](main.tf)はVMと基本ツールを構築しますが、開発環境はrepoに宣言されていません。
2026-10-12の運用者によるVM確認では、docker、node / npm、go、python3、VS Code server、
`~/stashPad`（[stashPad](https://github.com/koji-genba/stashPad.git)のcheckout）と
`~/stashpad-worktrees/`が手作業で入っていました。開発環境の宣言は[#87](https://github.com/koji-genba/homelab/issues/87)で追跡しています。

VMを作り直すと、VMの中にしか無い作業（pushしていないcommit、未commitの変更）は失われます。
作り直す前に、残す変更をcommitし、未pushのcommitとともにpushしてください。
2026-10-12時点で、VMの中にしか無い作業がありました。
この作業は運用者が別途pushする扱いです。
2026-10-12に、運用者は重要ではないUbuntuの開発用VMとして、VM backupを取らないと決めました。
repoから再構築できるからではなく、失ってよいという判断によるものです。
VM全体の評価と方針は[現行アーキテクチャ](../../../../docs/architecture/target-state.md#再構築性とbackupの方針)を参照してください。

## Apply

このrootでは既存のApps VM token `terraform@pve!apps-vm`を使います。
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
以下は実装から導いた手順で、実機では未検証です。

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
