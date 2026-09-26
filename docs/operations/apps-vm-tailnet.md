# Apps VMのtailnet参加（issue #30）

Apps VMを`tag:apps`付きnodeとしてtailnetへ参加させ、Caddy（80/443）、AdGuard DNS（53/tcp、53/udp）、Samba（445）をVM自身の100.x addressでも公開する。Stage 1ではclientの接続先を変更せず、Stage 2でAdGuardのrewriteとtailnet nameserverを`100.86.147.127`へ切り替える。

## 前提とACL

TailscaleのACL `tagOwners`に`tag:apps`を含める。既存のACLを置き換えず、既存のownerを保って次のentryを追加する。

```json
"tagOwners": {"tag:apps": ["autogroup:admin"]}
```

管理端末のignore対象`files/infrastructure/terraform/tailscale/acl-policy.live.json`にreview済みlive exportを保存して編集し、[Tailscale Terraform手順](../../files/infrastructure/terraform/tailscale/README.md)の`make tailscale-plan MANAGE_TAILNET=true ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json`でplanを確認し、同手順の`make tailscale-apply`で反映する。ACLの他の定義を維持する。

## 手動登録

admin consoleで`tag:apps`を付けたauth keyを生成する。Pre-approvedを有効、Reusableを無効、expiryは短時間とする。keyをrepository、shell history、VM上の永続fileへ保存しない。key値をcommand引数へ入れない。tagはauth keyから付与されるため`--advertise-tags`は指定しない。tag付きnodeのkey expiryはdefaultで無効になる。

まずAnsibleを一度実行してpackageとdaemonを準備する。未登録なのでroleは`not Running`で停止する。これは初回の想定した停止点である。VMの対話Bash shellで次を実行し、その後Ansibleを再実行する。`read`の入力は画面に表示されず、historyにも残らない。`/run`はtmpfsであり、rootだけが一時keyを読める。

```sh
sudo install -d -m 0700 /run/tailscale-auth
trap 'sudo rm -f /run/tailscale-auth/key; sudo rmdir /run/tailscale-auth' EXIT
IFS= read -r -s -p 'Tailscale auth key: ' ts_auth_key; printf '\n'
printf '%s' "$ts_auth_key" | sudo sh -c 'umask 077; cat > /run/tailscale-auth/key'
unset ts_auth_key
sudo tailscale up --auth-key=file:/run/tailscale-auth/key --accept-routes=false --accept-dns=false --snat-subnet-routes=false
sudo rm -f /run/tailscale-auth/key
sudo rmdir /run/tailscale-auth
trap - EXIT
```

登録後、VMで`tailscale status --json | jq '.Self.Tags, .Self.KeyExpiry'`を実行し、`["tag:apps"]`と`null`を
確認する。tagが空ならauth keyにtagが付いていなかった。user所有nodeとして登録され、key expiryが有効になる。
admin consoleの **Edit ACL tags** で`tag:apps`を付け、それでもexpiryが残る場合は **Disable key expiry** を実行する。
expiryが残ると、失効日にtailnetからApps VMが外れる。

割り当てられた100.x addressはそのまま使ってよい。変える場合はadmin consoleの **Machines > Apps VMのdevice > Edit IPv4** で変更する。`tailscale ip -4`で実値を確認し、Git管理の`files/infrastructure/ansible/apps/group_vars/apps.yml`に`apps_tailnet_ip`として設定してcommitする。exampleの`100.64.0.101`を実値として使わない。Ansibleは未設定または不一致なら検出値を表示して停止する。

## 適用順序

Apps VMのcheckoutは`main`を追い、`homelab-app-reconcile.timer`が15分ごとにfetch、fast-forward、Compose設定検証を行う。一方、`APPS_TAILNET_IP`はAnsibleが`/etc/homelab/compose.env`へ描画する。したがって**PRをmainへmergeする前**に、このbranchからAnsibleを一度実行し、上記登録とIP固定を済ませ、同じbranchのAnsible変更を管理端末から再適用して`APPS_TAILNET_IP`を先に配置する。Ansible実行時のVM checkoutはまだmainでよい。sysctlの`ip_nonlocal_bind`により、tailscale0がdownでもDockerは100.x addressへbindでき、LAN側のCompose起動はtailscaledの状態に依存しない。適用後にenvの値と既存LANサービスを確認してからmergeする。merge後、reconcilerが新しいCompose bindingを適用する。

`tailscale` roleは`network`の後、`firewall`と`compose`の前に実行する。`accept-routes=false`によりNFSの`192.168.10.11`を含む`192.168.10.0/24`はgateway subnet routerへ迂回しない。`accept-dns=false`によりnetwork roleのsystemd-resolved構成を維持する。`snat-subnet-routes=false`はDocker DNAT後もclientの100.x sourceを保ち、Caddyの`remote_ip` trusted-network判定を通す。

## 検証

`accept-routes`を使っていないtailnet clientから実行する。DNS rewriteが返すLAN IPはStage 1の意図した結果である。

```sh
tailscale ping <apps_tailnet_ip>  # directと表示され、DERPではない
nslookup dns.kojigenba-srv.com <apps_tailnet_ip>  # 192.168.10.101を返す
curl -sS -o /dev/null -w '%{http_code}\n' --resolve dns.kojigenba-srv.com:443:<apps_tailnet_ip> https://dns.kojigenba-srv.com/  # 200または302
```

curlが403ならsource NATと`tailscale debug prefs`の`NoSNAT`を確認する。必要ならSMBの`\\<apps_tailnet_ip>\shared`も確認する。VMでは`ss -lntup`でdocker-proxyがLAN addressと100.x addressの両方をlistenしていることを確認する。
あわせて`ip route get 192.168.10.11`が`dev eth0`を返し、NFSがtailscale0へ迂回していないことを確認する。

## Stage 1の戻し方

このPRのCompose bindingと`APPS_TAILNET_IP` env追加をrevertし、Ansibleを再適用する。VMで`tailscale down`または`tailscale logout`を実行し、admin consoleからdeviceを削除する。`ip_nonlocal_bind` sysctlは残しても無害である。

## Stage 2: DNS cutover

Stage 1の`tag:apps`、固定IP、両addressでの80/443/53/445、direct経路を確認済みとする。
常時宅内desktopのSMB shareは名前のままでよい（切替後はApps VMとのdirect WireGuard経路になる。
[target-zones](../network/target-zones.md#dnsとtailscale)参照）。
roaming clientのTailscaleはv1.88.1以上へ更新する。方針は[ADR-0007](../adr/0007-apps-vm-tailnet-dns.md)を参照する。

1. このbranchから`make ansible-apply`を実行する。AdGuardの内部service名が100.xを返すようになり、
   runtime変更によりcontainerがforce-recreateされる。DNSとSMBは短時間途切れる。
   `nslookup dns.kojigenba-srv.com 192.168.10.101`と
   `nslookup dns.kojigenba-srv.com 100.86.147.127`が、どちらも`100.86.147.127`を返すことを確認する。
2. AdGuardの確認後、保存planを作成する。

   ```sh
   make tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true \
     ADGUARD_READY=true \
     ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
   make tailscale-apply
   ```

   planでは`tailscale_dns_configuration.adguard[0]`の`nameservers[0].address`だけが
   `192.168.10.101`から`100.86.147.127`へin-place変更されることを確認する。
   その他の差分があれば適用を止める（[Terraform手順](../../files/infrastructure/terraform/tailscale/README.md)）。
3. `accept-routes=false`のclientを宅外またはphone hotspotに接続し、
   `https://dns.kojigenba-srv.com`が403にならず開くこと、
   `\\samba.kojigenba-srv.com\shared`へ接続できることを確認する。
   gateway exit nodeを有効にしても内部名が解決すること、`tailscale status`でApps VMへの
   経路がdirectと表示されることも確認する。
4. 全roaming clientの`accept-routes=false`を永続化する。Windows GUIでは
   「Use Tailscale subnets」をoffにする。CLIでは`tailscale set --accept-routes=false`を使う。

手順1と2を実環境へ適用し、確認してからPRをmergeする。

### Stage 2のrollback

`files/infrastructure/ansible/apps/group_vars/apps.yml`の`internal_records_use_tailnet_ip: false`へ戻して
`make ansible-apply`を実行する。Terraformは次のplan/applyでnameserverをLAN IPへ戻す。

```sh
make tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true \
  ADGUARD_READY=true ADGUARD_NAMESERVER_IP=192.168.10.101 \
  ACL_POLICY_FILE=files/infrastructure/terraform/tailscale/acl-policy.live.json
make tailscale-apply
```

admin consoleで先にnameserverを戻した場合は後でTerraformと整合させる。
宅外roaming clientは旧LAN IPへ到達するため、`accept-routes`を再び有効にする。
