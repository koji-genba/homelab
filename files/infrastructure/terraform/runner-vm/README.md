# Runner VM用Terraformルート

このrootはHermesのコマンド実行・ブラウザを載せる隔離用のDebian 13 Runner VMだけを作成する。
version固定したgeneric-cloud imageをProxmoxへ直接importし、SHA-512 checksumを検証する。方式は
[apps-vm](../apps-vm/README.md)に倣う。

- VMID `105`、VLAN 10 `192.168.10.105/24`、8 vCPU / 16 GiB、OS disk 40 GiB。
- 作業disk 150 GiB（`scsi1`）を追加し、Ansibleが`/srv/agent-work`へext4でmountする。
- tailnetには参加しない。egressはAnsible側のnftablesで制限する（PRD §4.2）。
- Discord token・記憶DB・homelabの管理鍵はこのVMに置かない。

apply前に、KeePassXCから`TF_VAR_proxmox_api_token`と`TF_VAR_ssh_public_key`を管理端末へ一時的に
注入する。MakeはこれらをProxmox Terraform runnerにだけ渡し、repository、runtime SOPS bundle、
VMには保存しない。

```sh
terraform init
terraform fmt -check
terraform validate
terraform plan -out=terraform.tfplan
terraform apply terraform.tfplan
```

repositoryのMake targetはrootを切り替えて同じ保存plan方式を使う。

```sh
make TERRAFORM_ROOT=files/infrastructure/terraform/runner-vm terraform-validate
make TERRAFORM_ROOT=files/infrastructure/terraform/runner-vm terraform-plan
make TERRAFORM_ROOT=files/infrastructure/terraform/runner-vm terraform-apply
```

## 所有と命名

- **cloud image**: このrootは自分専用の`file_name`（`debian-13-genericcloud-amd64-runner.qcow2`）で
  importする。`agent-vm`は別名を使うため、2つのTerraform stateが同じProxmox上のobjectを
  管理しない。`proxmox_download_file`を別rootから重複宣言しない。
- **cloud-init snippet**: `runner-cloud-init.yaml`というホスト固有の名前で作る。
- **cloud-init lifetime**: `initialization[0].user_data_file_id`を`ignore_changes`に入れ、snippet
  更新で既存VMを置換しない。既存VMのcloud-initをclean/reinitで再適用せず、runtime設定は
  Ansibleで収束させる。

## Proxmox側の手動準備（IaC外、実施は了承後）

Proxmoxのuser/role/token/ACLはTerraformで管理しない。applyの前に、既存の
[Apps VM recovery の Proxmox 準備](../../../../docs/operations/apps-vm-recovery.md#terraform実行前のproxmox側準備)
に倣い、次を手作業で用意する。2026-10-18にtoken・ACL準備、VM作成、host key登録まで実施済み（Ansible未適用）。

1. Terraform用API token（例 `terraform@pve!runner-vm`、`privsep=0`）を発行する。
2. ユーザー`terraform@pve`へVMID 105用のACLを付与する。少なくとも`/vms/105`と、image importに必要な
   datastore権限を対象node/datastoreに与える。`privsep=0`のためApps / Agent / Runnerの3 tokenは同じユーザーACLを継承し、VM別には分離されない。
3. 対象datastore `local` のcontent typeに`Import`と`snippets`が含まれることを確認する。
4. VMID 105と`192.168.10.105`が空いていることを確認する。このrootは重複確認のためのIP取得や
   pingを行わない。
5. 最初のAnsible接続前に、Proxmox console等のout-of-band経路でVMのSSH host-key fingerprintを
   確認し、管理端末の`known_hosts`へ追加する。未検証の`ssh-keyscan`結果を信頼しない。

stateはlocalで管理し、mode `0600`を維持する。明示的なage暗号化recovery copyにはrepositoryの
`make state-backup`を使う。`make state-backup`は`files/infrastructure/terraform`以下の`*.tfstate`を
探索するため、このrootの`terraform.tfstate`も対象になる。
