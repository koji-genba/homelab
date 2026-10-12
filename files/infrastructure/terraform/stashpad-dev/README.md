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

## Apply

```bash
cd files/infrastructure/terraform/stashpad-dev
terraform init
terraform plan -var-file=../elastiflow/terraform.tfvars
terraform apply -var-file=../elastiflow/terraform.tfvars
```

上の例はElastiFlowルートのlocal `terraform.tfvars`に依存します。Proxmox接続情報、SSH公開鍵に加え、
共有file内のこのルートと同名の変数も適用されるため、内容を確認してください。
このルート自身の[terraform.tfvars.example](terraform.tfvars.example)から用意する場合は次を使います。
以下は実装から導いた手順で、実機では未検証です。

```bash
cd files/infrastructure/terraform/stashpad-dev
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
terraform init
terraform plan
terraform apply
```

`cd`はrepository rootから実行します。providerは`proxmox_username` / `proxmox_password`方式で、
`ssh_public_key`も設定します。実値を入れた`terraform.tfvars`はGit ignore対象です。

## Terraform state

active stateはこのルートのlocal `terraform.tfstate`で、Git ignore対象です。
このルートはraw `terraform apply`で実行し、state backupを呼ばないため、成功後にrepository rootで
このルートのstateも収集する`make state-backup`を実行します。
backup / restoreの仕組みと前提は[ADR-0005](../../../../docs/adr/0005-secrets-and-terraform-state.md)と
[state-backup.sh](../../../../scripts/state-backup.sh) / [state-restore.sh](../../../../scripts/state-restore.sh)を参照してください。

## Connect

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.10.41
```
