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
`112`で、101〜103はKubernetesが使用中である。defaultの`.42`管理アドレスは現在のVLAN 10 DHCP pool外にある。
legacy cutover用に、アドレスを持たないVLAN 11 NICを2本目として作成する。Ansibleは、明示的なDHCP/MetalLB
停止とARP確認が終わった後だけCaddy `.11.100`、AdGuard `.11.101`、Samba `.11.103`を割り当てる。
`192.168.10.101`は将来の単一アドレスであり、このrootが取得することはない。

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

対象Proxmox datastoreではcontent type `Import`を有効にする。applyで使うAPI tokenには、対象node/datastore
上で必要なstorage/VM権限だけを与える。`Sys.Audit`、`Sys.Modify`、`Datastore.AllocateTemplate`を含める。
apply前にVMID `112`と未使用のフェーズ1 IP `192.168.10.42`を確認する。このrootは重複確認のためにIPを取得しない。

2本目のVLAN 11 NICは意図的にcloud-initで設定しない。providerのdeviceごとの`ip_config`は管理deviceにだけ
適用されるため、legacy NICはこのrootからDHCP leaseもaddressも受け取らない。Ansibleのoneshot helperは、
旧所有者をfenceし、重複address検出に成功した後だけ3つのaddressを割り当てる。

stateはlocalで管理し、mode `0600`を維持する。明示的なage暗号化recovery copyにはrepositoryの
`make state-backup` entry pointを使用する。
