# Runner VM用Terraformルート

## operator入力の既定値（issue #228）

[ADR-0017](../../../../docs/adr/0017-operator-defaults.md)により、通常はtfvarsの配置も環境変数の手入力も不要。
`make operator-secrets-set PROVIDER=proxmox`で共通API tokenをoperator bundleへ保存し、
`make operator-secrets-check PROVIDER=proxmox`でキー名だけを確認する（repo rootで実行）。
この端末移行・実planの手順は未検証。

6 root共通で`ssh_public_key`がnull/未指定なら`../bootstrap-ssh-key.pub`を使う。
repoの公開鍵は作業端末の公開鍵1行をコメント付きで保持する。既存VMの作成時の値に合わせ、
apps-vm・agent-vm・runner-vm・tailscale-gatewayは行全体、elastiflow・stashpad-devは先頭2フィールドだけを使う。
明示した`TF_VAR_ssh_public_key`は加工せず既定値より優先する。tfvarsや`-var`が残ればTerraform本来の優先順位
（`-var` > tfvars > `TF_VAR_*`）に従うため、移行では先に退避する。
本人の実機planでこの4 rootはコメント付き、残る2 rootはコメント無しでNo changesとなることを確認済み。
このrepo既定値へ切り替えた後の実機planは未検証。
`terraform.tfvars.example`は任意の非秘密の上書き用。provider認証は明示環境変数 > operator bundle、
bundleが無い場合は従来のallowlist。認証情報をtfvarsやVMへ保存しない。
ssh-agentは利用者が従来どおり起動・鍵登録する。
移行は[作業端末手順](../../../../docs/operations/workstation-setup.md)に従う。


このrootはHermesのコマンド実行・ブラウザを載せる隔離用のDebian 13 Runner VMだけを作成する。
version固定したgeneric-cloud imageをProxmoxへ直接importし、SHA-512 checksumを検証する。方式は
[apps-vm](../apps-vm/README.md)に倣う。

- VMID `105`、VLAN 10 `192.168.10.105/24`、8 vCPU / 16 GiB、OS disk 40 GiB。
- 作業disk 150 GiB（`scsi1`）を追加し、Ansibleが`/srv/agent-work`へext4でmountする。
- tailnetには参加しない。egressはAnsible側のnftablesで制限する（PRD §4.2）。
- Discord token・記憶DB・homelabの管理鍵はこのVMに置かない。

applyにはoperator bundle（または明示したprovider環境変数）を使う。


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

1. 全6 Proxmox root共通のAPI token `terraform@pve!terraform`（`privsep=0`）を使う。
   2026-10-25に共通tokenへ移行済み（[記録](../../../../docs/operations/apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)）。
   上記のProxmox準備に従い、共通tokenをoperator bundleへ保存する。
2. ユーザー`terraform@pve`へVMID 105用のACLを付与する。少なくとも`/vms/105`と、image importに必要な
   datastore権限を対象node/datastoreに与える。`privsep=0`のため共通tokenはユーザーACLを継承し、VM別には分離されない。
3. 対象datastore `local` のcontent typeに`Import`と`snippets`が含まれることを確認する。
4. VMID 105と`192.168.10.105`が空いていることを確認する。このrootは重複確認のためのIP取得や
   pingを行わない。
5. 最初のAnsible接続前に、Proxmox console等のout-of-band経路でVMのSSH host-key fingerprintを
   確認し、管理端末の`known_hosts`へ追加する。未検証の`ssh-keyscan`結果を信頼しない。

stateはlocalで管理し、mode `0600`を維持する。明示的なage暗号化recovery copyにはrepositoryの
`make state-backup`を使う。`make state-backup`は`files/infrastructure/terraform`以下の`*.tfstate`を
探索するため、このrootの`terraform.tfstate`も対象になる。


## UPS停止用のstartup設定

VMのstartupは[pve1 Ansible](../../ansible/pve1/README.md)の `guest_startup` roleで管理し、
このrootではstartupブロックを置かず `lifecycle.ignore_changes` に含める。
Terraform tokenには `/` の `Sys.Modify` がないため、権限を増やさずrootの `qm set --startup` で反映する。
VM作成・再作成後はpve1 Ansibleのcheck→applyが必要。値・順序・確認は
[UPS運用](../../../../docs/operations/ups-nut.md)に従う。startupの単独更新にVMの再起動は不要。
