# Apps VM用Terraformルート

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


このrootはDebian 13 Apps VMだけを作成する。version固定したgeneric-cloud imageをProxmoxへ直接
importし、SHA-512 checksumを検証する。手動管理のtemplate VMやclone操作は使わない。

applyにはoperator bundle（または明示したprovider環境変数）を使う。
全6 Proxmox root（Apps VM / Agent / Runner / ElastiFlow / Tailscale gateway / stashPadDev）で
共通token `terraform@pve!terraform`（`privsep=0`）を使う。権限と認証移行は
[Proxmox側準備](../../../../docs/operations/apps-vm-recovery.md#terraform実行前のproxmox側準備)を参照する。
2026-10-25に共通tokenへ移行済み（[記録](../../../../docs/operations/apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)）。

最初のAnsible接続前に、Proxmox consoleまたは別の信頼できるout-of-band channelからVMのSSH
host-key fingerprintを確認する。VMが提示するkeyと照合してから、管理端末の`known_hosts`へ追加する。
検証していない単独の`ssh-keyscan`結果を信頼してはならない。toolboxはhost-key検証を有効にしたままにする。

指定したimage URLの公式SHA-512 checksumはsecretではないdefault値として含めている。default VMIDは
`101`、管理アドレスは`192.168.10.101/24`である。旧Kubernetes VM 101〜103は2026-09-23に削除済み。
VMIDを変更する際はTerraform planのVM replacementを確認し、同じIPを持つ旧VMと新VMを同時に
起動しない。

```sh
make terraform-validate
make terraform-plan
make terraform-apply
```

repositoryのMake targetも同じ保存plan方式を使う。`make terraform-plan`を実行し、mode `0600`のignore対象
`terraform.tfplan`をreviewしてから`make terraform-apply`を実行する。apply targetはplanの欠落、symlink、
緩すぎるmodeを拒否し、`-auto-approve`を使用せず、apply時に新しいvariableを受け付けない。保存planには
sensitive valueが含まれる場合があるため、state fileと同様に保護し、review後に古いplanを削除する。

cloud-init snippetはVM作成時にだけ消費される。`source_raw.data`の修正でsnippet fileが更新されても、
既存VMの`initialization.user_data_file_id`だけを無視してVM replacementを防ぐ。新規作成または再作成する
VMは、作成時点の最新snippet IDを引き続き参照する。既存VMへcloud-initをclean/reinitで再適用してはならず、
Ansibleでruntime設定を収束させる。

対象Proxmox datastoreではcontent type `Import`を有効にする。applyで使うAPI tokenには、対象node/datastore
上で必要なstorage/VM権限だけを与える。`Sys.Audit`、`Sys.Modify`、`Datastore.AllocateTemplate`を含める。
apply前にVMID `101`が空いていることと、旧Apps VMが`192.168.10.101`を解放したことを確認する。
このrootは重複確認のためにIPを取得しない。

VLAN 11 NICと旧service IP用の設定は移行時の互換性のために残っているが、現行のdefaultでは無効である。
現行サービスは管理アドレス`192.168.10.101`へ集約されている。

stateはlocalで管理し、mode `0600`を維持する。明示的なage暗号化recovery copyにはrepositoryの
`make state-backup` entry pointを使用する。


## UPS停止用のstartup設定

VMのstartupは[pve1 Ansible](../../ansible/pve1/README.md)の `guest_startup` roleで管理し、
このrootではstartupブロックを置かず `lifecycle.ignore_changes` に含める。
Terraform tokenには `/` の `Sys.Modify` がないため、権限を増やさずrootの `qm set --startup` で反映する。
VM作成・再作成後はpve1 Ansibleのcheck→applyが必要。値・順序・確認は
[UPS運用](../../../../docs/operations/ups-nut.md)に従う。startupの単独更新にVMの再起動は不要。
