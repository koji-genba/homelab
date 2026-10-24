# Agent VM用Terraformルート

このrootはHermes常駐エージェント用のDebian 13 Agent VMだけを作成する。version固定した
generic-cloud imageをProxmoxへ直接importし、SHA-512 checksumを検証する。手動管理のtemplate VMや
clone操作は使わない。方式は[apps-vm](../apps-vm/README.md)に倣う。

- VMID `104`、VLAN 10 `192.168.10.104/24`、初期12 vCPU / 24 GiB、OS disk 40 GiB
  （2026-10-17 WS14ユーザー決定。embedding 4 CPU・reranker 6 CPUと、swapなしのTEI warm-upに余裕を持たせる。2026-10-18に適用済み）。
- データdisk 100 GiB（`scsi1`）を追加し、Ansibleが`/srv/agent`へext4でmountする。
- tailnetには参加しない。外向きはDiscord / GHCR / Debian / DGX / Apps VM / pve1 NFS。

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
`terraform-validate`/`terraform-plan`/`terraform-apply`は`TERRAFORM_ROOT`でrootを選ぶ。

```sh
make TERRAFORM_ROOT=files/infrastructure/terraform/agent-vm terraform-validate
make TERRAFORM_ROOT=files/infrastructure/terraform/agent-vm terraform-plan
make TERRAFORM_ROOT=files/infrastructure/terraform/agent-vm terraform-apply
```

apply targetはplanの欠落、symlink、緩すぎるmodeを拒否し、`-auto-approve`を使用しない。

## 所有と命名

- **cloud image**: このrootは自分専用の`file_name`（`debian-13-genericcloud-amd64-agent.qcow2`）で
  importする。`runner-vm`は別名を使うため、2つのTerraform stateが同じProxmox上のobjectを
  管理しない。imageを共有したくなっても、`proxmox_download_file`を別rootから重複宣言しない。
- **cloud-init snippet**: `agent-cloud-init.yaml`というホスト固有の名前で作る。Apps VMの
  `apps-cloud-init.yaml`と同じ名前を使わない。
- **cloud-init lifetime**: snippetはVM作成時にだけ消費される。`initialization[0].user_data_file_id`
  を`ignore_changes`に入れ、snippet更新で既存VMを置換しない。既存VMのcloud-initをclean/reinitで
  再適用せず、runtime設定はAnsibleで収束させる。

## Proxmox側の手動準備（IaC外、実施は了承後）

Proxmoxのuser/role/token/ACLはTerraformで管理しない。applyの前に、既存の
[Apps VM recovery の Proxmox 準備](../../../../docs/operations/apps-vm-recovery.md#terraform実行前のproxmox側準備)
に倣い、次を手作業で用意する。2026-10-18にtoken・ACL準備、VM作成、host key登録まで実施済み（Ansible未適用）。

1. 全6 Proxmox root共通のAPI token `terraform@pve!terraform`（`privsep=0`）を使う。
   2026-10-25に共通tokenへ移行済み（[記録](../../../../docs/operations/apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)）。
   上記のProxmox準備に従い、KeePassXCに保存した共通tokenを`TF_VAR_proxmox_api_token`へ一時注入する。
2. ユーザー`terraform@pve`へVMID 104用のACLを付与する。少なくとも`/vms/104`と、image importに必要な
   datastore権限（`Datastore.AllocateTemplate`、`Datastore.AllocateSpace`等）を対象node/datastoreに
   与える。`privsep=0`のため共通tokenはユーザーACLを継承し、VM別には分離されない。
3. 対象datastore `local` のcontent typeに`Import`と`snippets`が含まれることを確認する。
4. VMID 104と`192.168.10.104`が空いていること、旧VMが存在しないことを確認する。このrootは
   重複確認のためのIP取得やpingを行わない。
5. 最初のAnsible接続前に、Proxmox console等のout-of-band経路でVMのSSH host-key fingerprintを
   確認し、管理端末の`known_hosts`へ追加する。未検証の`ssh-keyscan`結果を信頼しない。

stateはlocalで管理し、mode `0600`を維持する。明示的なage暗号化recovery copyにはrepositoryの
`make state-backup`を使う。`make state-backup`は`files/infrastructure/terraform`以下の`*.tfstate`を
探索するため、このrootの`terraform.tfstate`も対象になる。
