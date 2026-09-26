# Apps VMのtailnet参加（issue #30 Stage 1）

Apps VMを`tag:apps`付きnodeとしてtailnetへ参加させ、Caddy（80/443）、AdGuard DNS（53/tcp、53/udp）、Samba（445）をVM自身の100.x addressでも公開する。Stage 1ではclientの接続先を変更しない。AdGuardのrewriteとtailnetのnameserverは`192.168.10.101`のままであり、DNS cutoverは後続stageで行う。

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

admin consoleの **Machines > Apps VMのdevice > Edit IPv4** で割り当てられた100.x addressを固定する。`tailscale ip -4`で実値を確認し、管理端末のignore対象`files/infrastructure/ansible/apps/group_vars/apps.yml`に`apps_tailnet_ip`として設定する。exampleの`100.64.0.101`を実値として使わない。Ansibleは未設定または不一致なら検出値を表示して停止する。

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

## 戻し方

このPRのCompose bindingと`APPS_TAILNET_IP` env追加をrevertし、Ansibleを再適用する。VMで`tailscale down`または`tailscale logout`を実行し、admin consoleからdeviceを削除する。`ip_nonlocal_bind` sysctlは残しても無害である。
