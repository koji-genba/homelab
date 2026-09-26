# Tailscale用Terraformルート

このrootは、公式の`tailscale/tailscale` provider（`0.29.2`固定）で既存tailnetを管理する。
新しいtailnet deviceやgateway VMは作成せず、MagicDNSとAdGuardのglobal nameserverを含むtailnet DNS設定、
grant/tag、subnet routeを記述する。

変更を伴うresourceはすべてdefaultで無効にする。policy resourceはtailnet全体を所有するため、apply前に
明示的なimportが必要である。review済みのlive exportをignore対象の
`files/infrastructure/terraform/tailscale/acl-policy.live.json`へ保存する。これはrepository内の通常fileで
なければならず、symlinkにしてはならない。Make targetはこの境界を検証し、toolbox内の`/workspace`へ対応付ける。

```sh
make tailscale-import-acl MANAGE_TAILNET=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-plan MANAGE_TAILNET=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
```

`tailscale-plan`はreview対象planをignore対象、mode `0600`の
`files/infrastructure/terraform/tailscale/terraform.tfplan`へ書き込む。保存planをreviewしてから
`make tailscale-apply`を実行する。欠落、symlink、緩すぎるmodeのplanを拒否し、variableやACL pathを再指定
せずにそのplanをapplyする。`-auto-approve`は使用しない。保存planにはsensitiveなprovider/configuration
値が含まれる場合があるため、state fileと同様に保護する。

`terraform import`はremote resource addressをstateへ記録するだけで、live ACLをconfigurationへコピーしない。
`manage_tailnet=true`を設定する前に、admin consoleから新しいexportを取得して`acl_policy_file`へ保存する。
このfileがなければplanとimport targetは実行を拒否する。保存planをreviewした後、`tailscale-apply`は再度ACL pathを
読まず、その指定も要求せずにapplyする。grant、tag owner、route auto-approverを含む完全なplanをlive exportと
照合する。`autoApprovers.routes`の各項目は既にadvertise済みの`advertised_routes` inventoryと一致しなければ
ならず、Terraformが新しいrouteを作成・承認することはない。

## 既存resourceのimport順序

各importの後にplanをreviewし、次の順序で既存resourceを取り込む。provider v0.29.2のimport IDはMake targetで
固定している。

```sh
make tailscale-import-core MANAGE_TAILNET=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-import-dns MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true \
  ADGUARD_READY=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-import-router MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true \
  TAILSCALE_DEVICE_ID=node-id \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
```

`tailscale-import-core`はACL ID `acl`だけをimportする。
`tailscale-import-dns`は最終readiness gateで`tailscale_dns_configuration` ID `dns_configuration`をimportする。
このresourceがMagicDNSとAdGuardのglobal nameserverをまとめて保持する。
router targetは確認済みのdevice/node IDを`device_tags[0]`と`device_subnet_routes[0]`の両方に使う。
importは自動実行せず、live valueをconfigurationへコピーもしない。exportとdiffのreviewは必須である。

`manage_tailnet=true`は、import済みpolicyと現在のadmin console exportをreviewした後だけ使う。
`manage_subnet_router=true`は、既存の`tailscale-gateway` deviceが意図したrouterであり、advertise済みrouteが
このrootと一致することを確認した後だけ使う。routeはdeviceが既にadvertiseしている必要があり、Terraformは
import済みdeviceのrouteを有効化するだけである。

`enable_adguard_dns`は別のdefault false gateである。`manage_tailnet=true`かつ`adguard_ready=true`でなければ
有効にできない。有効にするとMagicDNSとtailnet global DNS serverを管理し、後者をApps VMのtailnet IP
`100.86.147.127`へ向ける。`final_apps_ip`はreadinessの基準とrollback用LAN addressとして残す。
Split DNSは意図的に管理しない。フェーズ1ではreadyでないaddressへTailscale DNSを変更しない。

### Exit node使用時のDNSと既存stateの移行

Tailscaleは通常、exit node使用時に全DNS queryをexit nodeへ送る。gateway VMのresolverには内部recordがないため、
AdGuard nameserverで`Use with exit node`（`use_with_exit_node = true`）を有効にし、内部名もAdGuardで解決する。
この設定を使うclientにはTailscale v1.88.1以上が必要である。

以下は旧2 resourceからの初回移行時の記録である。一度だけ次を実行して保存planをreviewする。

```sh
make tailscale-import-dns MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true \
  ADGUARD_READY=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
```

期待するplanは、旧`tailscale_dns_preferences.magic_dns`と`tailscale_dns_nameservers.adguard`がdestroyなしで
stateから除外され、`tailscale_dns_configuration.adguard[0]`では最大でも
`nameservers[0].use_with_exit_node`の`false`から`true`への変更だけである。admin consoleですでに有効なら
変更はない。`magic_dns`、`override_local_dns`、`search_paths`、`split_dns`、nameserver addressの変更や、
それらの値が`known after apply`と表示される場合は停止し、applyしない。`tailscale_dns_configuration.adguard[0]`が
`will be created`と表示される場合もimportが抜けているので停止する。createはlive DNS設定全体を上書きする。
確認後に`make tailscale-apply`を実行する。

以後、DNSに影響するすべてのplanには`ENABLE_ADGUARD_DNS=true ADGUARD_READY=true`を指定する。
指定しない場合はresourceのcountが0となり、`prevent_destroy`によりplanは意図的に失敗する。
即時rollbackはadmin consoleの`Use with exit node`を無効にすることである。その変更はTerraformにdriftとして
表示されるため、後で整合させる。codeをrollbackする場合は、revertより先に
`terraform state rm 'tailscale_dns_configuration.adguard[0]'`でstateから外す。先にrevertすると
`prevent_destroy`ごとresourceが消え、planがtailnet DNS設定全体のdestroyになる。その後にrevertし、
旧2 resourceをrevert後のMake target `tailscale-import-magic-dns`と`tailscale-import-dns`で再importする
（`tailscale-import-core`はstate済みのACLもimportしようとして失敗する）。

### Apps VM tailnet DNS cutover（issue #30 Stage 2）

AdGuardの内部recordを先に`100.86.147.127`へ切り替え、LAN IPとtailnet IPの両方から
正しい回答を確認する。その後、次の保存planをreviewする。

```sh
make tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true \
  ADGUARD_READY=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-apply
```

期待するplanは`tailscale_dns_configuration.adguard[0]`のin-place変更1件だけであり、
`nameservers[0].address`が`192.168.10.101`から`100.86.147.127`へ変わる。
`use_with_exit_node`、`magic_dns`、`override_local_dns`、`search_paths`、`split_dns`は変えない。
これ以外の差分や`known after apply`があれば停止する。

rollback時は`ADGUARD_NAMESERVER_IP=192.168.10.101`を上記`make tailscale-plan`に追加する。
Makeが`-var="adguard_nameserver_ip=192.168.10.101"`を渡すので、addressだけ戻るplanを確認して
`make tailscale-apply`する。admin consoleで先に戻した場合も、後でTerraformと整合させる。

OAuth/API credentialはproviderが環境変数から読み取るため、KeePassXCから管理端末へ一時的に注入する。
Tailscale Terraform toolbox runnerにだけ渡し、runtime SOPS bundle、Terraform variable、file、Apps VMには保存しない。
`make tailscale-init`と`make tailscale-plan`は読み取り専用helperである。`make tailscale-apply`は明示的な手動操作で、
apply成功後は通常のstate-backup targetで暗号化stateを記録する。CI jobからは実行しない。
