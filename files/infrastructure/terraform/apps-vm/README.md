# Apps VM用Terraformルート

このrootはDebian 13 Apps VMだけを作成する。version固定したgeneric-cloud imageをProxmoxへ直接
importし、SHA-512 checksumを検証する。手動管理のtemplate VMやclone操作は使わない。

apply前に、KeePassXCから`TF_VAR_proxmox_api_token`と`TF_VAR_ssh_public_key`を管理端末へ一時的に
注入する。MakeはこれらをProxmox Terraform runnerにだけ渡し、repository、runtime SOPS bundle、
Apps VMには保存しない。

最初のAnsible接続前に、Proxmox consoleまたは別の信頼できるout-of-band channelからVMのSSH
host-key fingerprintを確認する。VMが提示するkeyと照合してから、管理端末の`known_hosts`へ追加する。
検証していない単独の`ssh-keyscan`結果を信頼してはならない。toolboxはhost-key検証を有効にしたままにする。

指定したimage URLの公式SHA-512 checksumはsecretではないdefault値として含めている。default VMIDは
`101`、管理アドレスは`192.168.10.101/24`である。旧Kubernetes VM 101〜103は2026-09-23に削除済み。
VMIDを変更する際はTerraform planのVM replacementを確認し、同じIPを持つ旧VMと新VMを同時に
起動しない。

```sh
terraform init
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
terraform fmt -check
terraform validate
terraform plan -out=terraform.tfplan
terraform apply terraform.tfplan
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
