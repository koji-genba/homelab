# Tailscale Gateway構築

TerraformでProxmox VE上にTailscale VPN Gateway用のVMを構築します。

## 構築されるVM

- **tailscale-gateway**: 192.168.10.102（サブネットルーター、VMID 102）
- CPU: 2 cores / メモリ: 4096 MB / ディスク: 20 GB（`vmpool`）
- Template: `template_vm_id`（default: 9000）からfull clone

PVE上のVM名とguest hostnameは`tailscale-gateway`です。tailnet hostnameは手動登録時に指定する
`home-gateway`で、両者を区別します。数値は[main.tf](main.tf) / [variables.tf](variables.tf)の定義です。

IPは`ip_address`変数で管理する。2026-09-12に`.30`から`.102`へ変更した。PVEのcloud-init設定を変えると
instance-idが変わるため、`reboot_after_update = true`による再起動後にcloud-initがnetplanを描き直し、
guestの実IPが切り替わる。再起動でSSH host鍵が作り直される点に注意する。

## 前提条件

- Proxmox VE環境（192.168.10.11）
- Tailscaleアカウント
- SSHキーペア
- Cloud-init対応のVMテンプレート（VMID 9000、現存は別途確認）

## 構築手順

以下はTerraformの定義と`outputs.tf`の案内に基づく再構築手順です。
登録（手動）→ prefs（Ansible）→ 承認（Terraform / 管理画面）の順に進めます。
新しいAnsible手順を含む実機での通し確認は未検証です。

### 1. 設定ファイル作成

```bash
cd files/infrastructure/terraform/tailscale-gateway/

# 設定ファイルをテンプレートからコピー
cp terraform.tfvars.example terraform.tfvars

# Proxmox接続情報とSSH公開鍵を設定
vim terraform.tfvars
```

このrootでは既存のApps VM token `terraform@pve!apps-vm`を使います。
実行前にKeePassXCから`TF_VAR_proxmox_api_token`を管理端末へ一時注入します。
Makeはこの環境変数をProxmox Terraform runnerへ名前で渡すため、値をMakeの出力へ展開しません。
tokenはrepository、tfvars、runtime SOPS bundle、VMへ保存しません。作業後は
`unset TF_VAR_proxmox_api_token`で管理端末の環境から削除します。

`terraform.tfvars.example`を同じdirectoryの`terraform.tfvars`へコピーし、`ssh_public_key`など
非秘密の値だけを設定します。既存ファイルは上書きしません。tfvarsはGit ignore対象です。
Proxmoxのuser / role / token / ACLの期待状態と既存環境からの移行は
[Proxmox側準備](../../../../docs/operations/apps-vm-recovery.md#terraform実行前のproxmox側準備)を正とします。

API認証とは別に、cloud-init snippetのアップロードにpve1の`root` SSHが必要です。
管理端末のssh-agentへ接続用の鍵を読み込み、`SSH_AUTH_SOCK`と`ssh-add -l`を確認します。
信頼できる経路でpve1のhost keyを照合して`known_hosts`へ登録します。Makeはagent socketと
`known_hosts`をtoolboxへmountします。`ssh_public_key`はguestへ配置する公開鍵で、providerのSSH認証とは別です。

このルートにはTailscale認証キーの変数はなく、TerraformはTailscaleのinstallと`tailscaled`の起動までを行います。

### 2. Terraform実行

```bash
terraform init
terraform plan
terraform apply
```

### 3. guest内でTailscale登録（手動）

[outputs.tf](outputs.tf)が案内する次のコマンドをguest内で実行し、認証を完了します。

```bash
ssh ubuntu@192.168.10.102
sudo tailscale up --accept-dns=false --hostname=home-gateway
tailscale status
```

登録は未登録nodeに対してだけ行います。登録済みnodeへのprefs再適用では、この登録手順を繰り返しません。
cloud-initとplaybookは`tailscale up` / `login` / `logout`を実行しません。

### 4. prefsをAnsibleで適用（未検証）

管理端末でrepository rootに戻り、Git管理の
`files/infrastructure/ansible/gateway/inventory/hosts.yml`で接続先を確認します。
SSH userはcloud-initと同じ`ubuntu`で、SSH鍵は他のAnsibleと同じくtoolboxにmountするssh-agentから渡します。
inventoryは`ansible_python_interpreter: /usr/bin/python3`を指定します。
[template 9000の復旧手順](../../../../docs/operations/proxmox-host-recovery.md#template-vm-9000)は
Ubuntu 24.04 cloud imageを使用し、cloud-initが必要とするPython 3を前提とします（実機の配置確認は未検証）。

```bash
# 実機に接続して読み取り、変更予定だけを表示
make ansible-apply-gateway GATEWAY_ANSIBLE_ARGS=--check
# prefsを適用し、同じコマンドを再実行してchanged=0を確認
make ansible-apply-gateway
make ansible-apply-gateway
```

`group_vars/gateway.yml`がexit nodeとsubnet routeの目標値です。
playbookは`tailscale status --json`で`BackendState=Running`を確認し、未登録・daemon停止などでは
何も変更せず前節の手動登録手順を案内して失敗します。
登録済みならApps VMと同じ`tailscale debug prefs`で`AdvertiseRoutes`を読み、順序を無視して比較し、
異なる場合だけ`tailscale set`を実行します。check modeでは読み取りと変更予定の報告だけを行います。
認証・hostname・DNSなど、広告以外のprefsはこのplaybookの管理対象に含めません。

IP forwardingは[main.tf](main.tf)のcloud-initが`/etc/sysctl.conf`に
`net.ipv4.ip_forward = 1`と`net.ipv6.conf.all.forwarding = 1`を宣言しており、Ansibleでは二重管理しません。
CIはlint / syntax-checkと、`make gateway-routes-test`によるTerraform承認リスト既定値との整合性を検査します。
local tfvarsや実機の状態とのずれはこの静的検査の対象外です。

### 5. device確認とルート承認

登録後にTailscale Admin Consoleでdeviceを確認し、サブネットルートとexit nodeを承認します。

1. [Tailscale Admin Console](https://login.tailscale.com/admin/machines)にアクセス
2. tailnet hostname `home-gateway`のdeviceが作成したVMに対応することを確認して選択
3. "Edit route settings"をクリック
4. アドバタイズされたルート（192.168.10.0/24）とexit nodeを承認

Terraformで承認を管理する場合は[tailnet側README](../tailscale/README.md)のimport-first手順に従います。
`advertised_routes`はcontrol planeの承認リストであり、guestの広告設定は変更しません。
再構築でidentityが変わった場合は、新deviceの確認と再承認が必要です。router importは自動実行しません。

### 6. 動作確認（Ansible適用後の確認は未検証）

```bash
# VM起動確認
ssh ubuntu@192.168.10.102

# Tailscale状態確認
tailscale status

# 広告は以下の3つだけであることを確認（順序不問）
# 0.0.0.0/0, ::/0, 192.168.10.0/24
sudo tailscale debug prefs

# IPv4 / IPv6 forwardingはどちらも1
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding

# ルーティング確認
ip route
```

Admin Consoleでroute / exit nodeが承認されていることと、clientからexit nodeを選び、
PVE / IX2215などのLAN管理先へ到達できることを確認します（未検証）。
prefs適用は不要な広告を取り下げるため、そのrouteを使用中の接続へ影響します。
LAN側の管理経路を確保してから適用してください。nodeの再登録は行いません。

## Terraform state

active stateはこのルートのlocal `terraform.tfstate`で、Git ignore対象です。
このルートはraw `terraform apply`で実行し、state backupを呼ばないため、成功後にrepository rootで
このルートのstateも収集する`make state-backup`を実行します。
backup / restoreの仕組みと前提は[ADR-0005](../../../../docs/adr/0005-secrets-and-terraform-state.md)と
[state-backup.sh](../../../../scripts/state-backup.sh) / [state-restore.sh](../../../../scripts/state-restore.sh)を参照してください。

## 使用方法

### 外部からのアクセス

Apps VMは自身がtailnet node（`tag:apps`、`100.86.147.127`）であり、内部名は100.xへ解決される。
Apps VMのserviceへはgatewayを経由せず、名前で接続する（[ADR-0007](../../../../docs/adr/0007-apps-vm-tailnet-dns.md)）。

```bash
# Sambaアクセス例（macOS/Linux）
open smb://samba.kojigenba-srv.com

# SSH接続例（MagicDNS名またはtailnet IP）
ssh deploy@apps
```

gatewayの役割はexit nodeと、exit node経由でApps VM以外のLAN機器（PVE、IX2215、ElastiFlow）へ
入ることである。宅外からこれらの管理画面を使うときはexit nodeを有効にする。

ElastiFlow UIは例外として `https://elastiflow.kojigenba-srv.com` からApps VMのCaddy経由でも利用でき、
gateway exit nodeに依存しない（[ADR-0009](../../../../docs/adr/0009-elastiflow-caddy-fqdn.md)）。
ElastiFlow VMへのSSHや直IPのLANアクセスには従来の経路を使う。

### `192.168.10.0/24`の広告を外さない

exit nodeは、自身が接続するLANをsubnet routeとして広告しない限り、そのLANへ転送しない
（Tailscaleの仕様。default routeを提供するnodeはlocal LANを"guest wifi"としてfilterする）。
2026-09-26に広告を外すと、exit node経由でPVE、IX2215、ElastiFlowへ届かなくなることを確認した。
AdvertiseRoutesは`0.0.0.0/0`、`::/0`、`192.168.10.0/24`を維持する
（[gateway Ansible vars](../../ansible/gateway/group_vars/gateway.yml)で宣言）。
prefsの再適用は上記の`make ansible-apply-gateway`を使う。

## トラブルシューティング

### サブネットルートが有効にならない

手動登録済みであることを確認し、repository rootで`make ansible-apply-gateway GATEWAY_ANSIBLE_ARGS=--check`、
`make ansible-apply-gateway`の順にprefsを確認・再適用します（未検証）。
その後Admin ConsoleまたはTerraformの承認リストを確認します。広告と承認は別の層です。

### 接続できない

```bash
# Tailscale接続状態確認
tailscale status

# IPフォワーディング確認
sysctl net.ipv4.ip_forward
# 出力が "net.ipv4.ip_forward = 1" であることを確認

# UFWを別途導入している場合だけ確認（Terraformは導入しない）
sudo ufw status
```

## 関連ドキュメント

- [Tailscale Subnet Routers](https://tailscale.com/kb/1019/subnets/)
- [tailnet側のTerraform管理](../tailscale/README.md)
- [プロジェクトルートREADME](../../../../README.md)
