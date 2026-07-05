# stashPadDev VM

TerraformでProxmox VE上にstashPad開発用VMを構築します。

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

## Connect

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.10.41
```
