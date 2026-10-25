# Tailscale用Terraformルート

このrootは、公式の`tailscale/tailscale` provider（`0.29.2`固定）で既存tailnetを管理する。
新しいtailnet deviceやgateway VMは作成せず、MagicDNSとAdGuardのglobal nameserverを含むtailnet DNS設定、
grant/tag、subnet routeを記述する。

`tailnet`のdefaultは`example.com`であり、実際のtailnet ID/nameをignore対象の`terraform.tfvars`などで
指定する必要がある。gateway VMの管理は[別ルート](../tailscale-gateway/README.md)にある。

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

上の例はDNS設定をimportする前の初回用である。`tailscale_dns_configuration`がstateにある現在は、
ACLだけを変える場合も`ENABLE_ADGUARD_DNS=true ADGUARD_READY=true`を付ける（後述）。

```sh
make tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true ADGUARD_READY=true \
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

## ACL全文の復旧用コピー（2026-10-25）

review済みACL全文を`files/infrastructure/secrets/tailscale/acl-policy.sops.json`へSOPSのbinary形式で
暗号化してrepoに保存する。
通常のSOPS JSON形式ではkey名が平文で残り、ACLのkeyにはhostname・CIDR・tagが入りうるため、
全文をblobとして暗号化するbinary形式を使う。既存の`AGE_RECIPIENT`と`AGE_IDENTITY_FILE`を使い、
creation_rulesは追加しない。鍵の保管は[secret手順](../../secrets/README.md)に従う。

### 復旧用コピーの更新

ACLを変えるたびに更新する。consoleでの緊急変更後も、最新export全文をreviewし、ignore対象の
`acl-policy.live.json`へmode `0600`で保存する。厳密なJSONであることを確認し、内容をlogやPRへ貼らない。
既存の暗号文を消してから暗号化する（初回は削除不要）。古い版はGitの履歴に残る。

```sh
rm files/infrastructure/secrets/tailscale/acl-policy.sops.json
make tailscale-acl-encrypt AGE_RECIPIENT="$AGE_RECIPIENT" \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make tailscale-acl-decrypt \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make secrets-scan
```

`tailscale-acl-encrypt`は既存暗号文を上書きせず、mode `0600`で作成する。
`tailscale-acl-decrypt`はlive.jsonが有れば上書きせず、復号結果とのbyte単位の「一致 / 不一致」だけを表示する。
不一致や復号失敗はerrorで停止する。一致を確認した暗号文だけをPRに含め、commit messageにexportの取得日を書く。
復旧コピーとconsoleの自動drift検知は行わない。

### 復元

管理端末で既存identityを復旧し、次を実行する。live.jsonが無ければmode `0600`で作成し、
失敗時には部分ファイルを残さない。symlinkやrepo外の出力先は拒否する。

```sh
AGE_IDENTITY_FILE=/secure/path/age-identity.txt make tailscale-acl-decrypt \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
```

既存tailnetなら、復旧コピーを最新のadmin console exportと照合してからimport / planする。
差分があれば意図を確認し、採用する全文をreviewする。新しいtailnetなら旧user・tag・route等の有効性を
再確認する。import順序とgateは以下に従い、planをreviewする。import / plan / applyは別途承認された
本番作業として実施する。ACL全文だけでは端末登録やDNSまで復元できない。

## 既存resourceのimport順序

provider v0.29.2のimport IDはMake targetで固定している。以下は初回向けの各helperの呼出例である。
既にstateにある対象のgateも指定する。下の例ではDNS import後のrouter helperにもDNS gateを付ける。
routerを先にimportした場合は、DNS helperにも`MANAGE_SUBNET_ROUTER=true`を付ける。

```sh
make tailscale-import-core MANAGE_TAILNET=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-import-dns MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true \
  ADGUARD_READY=true \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-import-router MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true \
  ENABLE_ADGUARD_DNS=true ADGUARD_READY=true \
  TAILSCALE_DEVICE_ID=node-id \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
```

`tailscale-import-core`はACL ID `acl`だけをimportする。
`tailscale-import-dns`は最終readiness gateで`tailscale_dns_configuration` ID `dns_configuration`をimportする。
このresourceがMagicDNSとAdGuardのglobal nameserverをまとめて保持する。
router targetは確認済みのdevice/node IDを`device_tags[0]`と`device_subnet_routes[0]`の両方に使う。
importは自動実行せず、live valueをconfigurationへコピーもしない。exportとdiffのreviewは必須である。

### import helperのgate制約

[Makefile](../../../../Makefile)の`tailscale-import-core`は`tailscale-import-acl`を呼ぶ。
各helperはimport対象のgateを確認し、内部の`tailscale-plan`へ他のgateも呼出時の値のまま明示的に渡す。
`tailscale-import-core`からACL helperへの呼出しも同様である。DNSのreadinessやrouterのinventory確認を
省略してgateを自動で有効にすることはない。

このrootはbackendブロックを持たず、`tailscale-init`は`init -backend=false`を使う。
defaultのlocal backend・default workspaceだけを前提とし、`terraform.tfstate.d`が存在すれば
想定外のworkspaceとして停止する。`terraform.tfstate`が存在しなければ初回の空stateとして扱う。
存在する場合は最初のimport前に、import / planと同じtoolbox・Terraform rootで
`terraform state list`を実行する。providerの認証情報は不要なので、チェックは`TOOLBOX_RUN`を使う。
stateにあるACLは`MANAGE_TAILNET=true`、DNSはそれに加えて
`ENABLE_ADGUARD_DNS=true ADGUARD_READY=true`、routerのtagsまたはroutesは
`MANAGE_SUBNET_ROUTER=true`も必要である。gateが欠けている場合やstateの取得に失敗した場合は、
importによるstate変更前に停止する。stateファイルの存在確認では内容を読まない。
readinessとinventoryを確認してから、既に管理している全対象のgateを指定する。

この事前チェックはimport全体をtransactionにするものではない。import自体や後続planの別のerrorで
途中停止した場合は、再実行前にstateを確認する。通常の`tailscale-plan`も、既にstateにある対象のgateを
保持してreviewする必要がある。

`manage_tailnet=true`は、import済みpolicyと現在のadmin console exportをreviewした後だけ使う。
`manage_subnet_router=true`は、tailnet hostname `home-gateway`のdeviceが意図したrouterであり、advertise済みrouteが
このrootと一致することを確認した後だけ使う。routeはdeviceが既にadvertiseしている必要があり、Terraformは
import済みdeviceのrouteを有効化するだけである。
`subnet_router_hostname`はtailnet hostnameを指定する変数で、PVE VM名 / guest hostnameの`tailscale-gateway`とは区別する。

`enable_adguard_dns`は別のdefault false gateである。`manage_tailnet=true`かつ`adguard_ready=true`でなければ
有効にできない。有効にするとMagicDNSとtailnet global DNS serverを管理し、後者をApps VMのtailnet IP
`100.86.147.127`へ向ける。`final_apps_ip`はLAN側の固定値`192.168.10.101`を検証し、rollback時に
`adguard_nameserver_ip`で許容するLAN addressとして残す。到達性を自動確認するものではなく、readinessは
運用者が実測して`adguard_ready`で指定する。
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

以後、`MANAGE_TAILNET=true`のplanには、ACLだけの変更であっても必ず`ENABLE_ADGUARD_DNS=true ADGUARD_READY=true`を
指定する。指定しない場合はresourceのcountが0となり、`prevent_destroy`によりplanは意図的に失敗する
（`Instance cannot be destroyed`）。このerrorはflagの付け忘れを示すだけで、tailnetは変更されていない。
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
`make tailscale-init`と`make tailscale-plan`はremote設定を適用しないが、localの初期化file・保存planを作成する。
`make tailscale-apply`は明示的な手動操作で、
apply成功後は通常のstate-backup targetで暗号化stateを記録する。CI jobからは実行しない。
