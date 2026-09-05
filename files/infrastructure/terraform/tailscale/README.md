# Tailscale用Terraformルート

このrootは、公式の`tailscale/tailscale` provider（`0.29.2`固定）で既存tailnetを管理する。
新しいtailnet deviceやgateway VMは作成せず、MagicDNS、global DNS設定、grant/tag、subnet routeを
記述する。

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

`tailscale-import-core`はACL ID `acl`とMagicDNS ID `dns_preferences`をimportする。
`tailscale-import-dns`は最終readiness gateでだけglobal AdGuard nameserver ID `dns_nameservers`をimportする。
router targetは確認済みのdevice/node IDを`device_tags[0]`と`device_subnet_routes[0]`の両方に使う。
importは自動実行せず、live valueをconfigurationへコピーもしない。exportとdiffのreviewは必須である。

`manage_tailnet=true`は、import済みpolicyと現在のadmin console exportをreviewした後だけ使う。
`manage_subnet_router=true`は、既存の`tailscale-gateway` deviceが意図したrouterであり、advertise済みrouteが
このrootと一致することを確認した後だけ使う。routeはdeviceが既にadvertiseしている必要があり、Terraformは
import済みdeviceのrouteを有効化するだけである。

`enable_adguard_dns`は別のdefault false gateである。`manage_tailnet=true`かつ`adguard_ready=true`でなければ
有効にできない。有効にするとtailnet global DNS serverを最終Apps address `192.168.10.101`へ向ける。
Split DNSは意図的に管理しない。フェーズ1ではreadyでないaddressへTailscale DNSを変更しない。

OAuth/API credentialはproviderが環境変数から読み取るため、KeePassXCから管理端末へ一時的に注入する。
Tailscale Terraform toolbox runnerにだけ渡し、runtime SOPS bundle、Terraform variable、file、Apps VMには保存しない。
`make tailscale-init`と`make tailscale-plan`は読み取り専用helperである。`make tailscale-apply`は明示的な手動操作で、
apply成功後は通常のstate-backup targetで暗号化stateを記録する。CI jobからは実行しない。
