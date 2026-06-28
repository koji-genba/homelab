# Proxmox ホスト再構築手順書

## 概要

このドキュメントは Proxmox ホスト (`pve.default.kojigenba-srv.com`, `192.168.10.11`) の
ハード変更・OS 再インストール後の復旧手順を記載する。

**前提条件 (再構築方針):**

- **新規作成するもの**: OS (rpool / nvme1n1), vmpool (nvme0n1), すべての VM
- **既存データを保持するもの**: `tank-gen1` (sdc/sdd + sde/sdf), `tank-gen2` (sda/sdb)
- 手動構築は「IaC (Terraform) が実行できる状態」まで。実際の VM プロビジョニングは Terraform に引き継ぐ

> tank-gen1 / tank-gen2 以外はまっさらな状態から組み直すイメージ。vmpool 上の VM ディスクは破棄され、
> Terraform によって新規にプロビジョニングされる。VM 内データが必要な場合は事前にバックアップしておくこと。

---

## ディスク構成

| デバイス | モデル | 容量 | 用途 | 扱い |
| --- | --- | --- | --- | --- |
| nvme1n1 | KIOXIA-EXCERIA PLUS G3 SSD | 931.5G | OS ブートディスク / rpool | **新規作成** |
| nvme0n1 | WD_BLACK SN770 1TB | 931.5G | vmpool (VM ディスク) | **新規作成** |
| sda | TOSHIBA HDWG62CUZSVA (20TB) | 20T | tank-gen2 mirror メンバ | インポート |
| sdb | TOSHIBA HDWG62CUZSVA (20TB) | 20T | tank-gen2 mirror メンバ | インポート |
| sdc | TOSHIBA MD04ACA400 (3.6TB) | 3.6T | tank-gen1 mirror メンバ | インポート |
| sdd | TOSHIBA MD04ACA400 (3.6TB) | 3.6T | tank-gen1 mirror メンバ | インポート |
| sde | KIOXIA-EXCERIA SATA SSD | 894G | tank-gen1 SLOG(p1) / L2ARC(p2) | インポート |
| sdf | KIOXIA-EXCERIA SATA SSD | 894G | tank-gen1 SLOG(p1) / L2ARC(p2) | インポート |

> **重要:** sda〜sdf は tank-gen1/gen2 のデータが入っているため Proxmox インストール中に**絶対に**選択しない。
> インストーラのディスク選択で **nvme1n1 のみ** を指定すること。nvme0n1 (vmpool) は後ほど手動でフォーマットする。

---

## Step 1: Proxmox VE インストール

### 1-1. ISO 準備

1. [Proxmox VE ダウンロードページ](https://www.proxmox.com/en/downloads) から最新の ISO を取得
   - 再構築時の参考バージョン: `pve-manager 8.4.19` (Debian 12 Bookworm ベース)
2. USB メモリに書き込み (balenaEtcher 等)

### 1-2. インストール設定

| 項目             | 設定値                          |
|-----------------|--------------------------------|
| Target disk     | **nvme1n1** (KIOXIA-EXCERIA PLUS G3 SSD) のみ選択 |
| Filesystem      | ZFS (RAID0) — シングルディスク   |
| ZFS ashift      | 12                              |
| Hostname        | `pve.default.kojigenba-srv.com` |
| IP Address      | `192.168.10.11/24`              |
| Gateway         | `192.168.10.1`                  |
| DNS Server      | `192.168.10.1`                  |
| Email           | `satosyenserver@gmail.com`      |
| root password   | (任意のパスワードを設定)          |

> インストーラが rpool を nvme1n1 上に自動作成する。

---

## Step 2: 初期設定 (インストール直後)

SSH で root ログイン後に以下を実施。

### 2-1. APT リポジトリ設定

エンタープライズリポジトリを無効化し、no-subscription リポジトリを有効化する。

```bash
# Enterprise リポジトリを無効化
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list

# Debian ミラーを日本向けに設定 + no-subscription リポジトリを追加
cat > /etc/apt/sources.list << 'EOF'
deb http://ftp.jp.debian.org/debian bookworm main contrib non-free-firmware
deb http://ftp.jp.debian.org/debian bookworm-updates main contrib non-free-firmware
deb http://security.debian.org bookworm-security main contrib non-free-firmware
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

apt-get update && apt-get dist-upgrade -y
```

### 2-2. ホスト設定確認

```bash
# hostname 確認
hostname -f
# → pve.default.kojigenba-srv.com

# /etc/hosts を確認・修正
cat /etc/hosts
```

`/etc/hosts` の内容:
```
127.0.0.1 localhost.localdomain localhost
192.168.10.11 pve.default.kojigenba-srv.com pve
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
```

### 2-3. キーボードレイアウト設定

```bash
pvesh set /cluster/options --keyboard ja
```

---

## Step 3: ネットワーク設定

`/etc/network/interfaces` を以下の内容に置き換える。

```bash
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

iface enp34s0 inet manual

auto vmbr0
iface vmbr0 inet static
    bridge-ports enp34s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094

auto vmbr0.10
iface vmbr0.10 inet static
    address 192.168.10.11/24
    gateway 192.168.10.1

auto vmbr0.11
iface vmbr0.11 inet static
    address 192.168.11.11/24

source /etc/network/interfaces.d/*
EOF
```

> **注意:** `enp34s0` はインターフェース名。再インストール後も同じ NIC が同名になるはずだが、
> `ip link show` で確認すること。MAC アドレスは `30:9c:23:cf:70:c3`。

ネットワーク設定を反映:

```bash
ifreload -a
# または reboot
```

---

## Step 4: ZFS プール設定

### 4-1. rpool の追加設定

インストーラが作成した rpool に必要なプロパティを設定する。

```bash
zfs set compression=on rpool
zfs set atime=on rpool
zfs set relatime=on rpool
zfs set acltype=posix rpool/ROOT/pve-1

# /var/lib/vz を ZFS で管理 (インストーラが作成しない場合)
zfs list rpool/var-lib-vz || \
  zfs create -o mountpoint=/var/lib/vz rpool/var-lib-vz

# VM/CT 用データセット (storage.cfg の local-zfs が参照)
zfs list rpool/data || zfs create rpool/data
```

### 4-2. vmpool 新規作成

nvme0n1 上に vmpool を新規作成する。

```bash
# デバイス確認 (by-id のパスをメモ)
ls -l /dev/disk/by-id/ | grep nvme0n1
# 例: nvme-WD_BLACK_SN770_1TB_22390J802169_1

# 既存の ZFS ラベルが残っている場合はクリア
zpool labelclear -f /dev/nvme0n1 || true

# プール作成
zpool create -f \
  -o ashift=12 \
  -o cachefile=none \
  vmpool \
  /dev/disk/by-id/nvme-WD_BLACK_SN770_1TB_22390J802169_1

# 圧縮を有効化
zfs set compression=on vmpool

# 状態確認
zpool status vmpool
```

### 4-3. tank-gen1 インポート

3.6TB ミラープール (SLOG・L2ARC 付き) をインポートする。

```bash
zpool import tank-gen1

# 状態確認
zpool status tank-gen1
```

期待する構成:
```
pool: tank-gen1
config:
  tank-gen1
    mirror-0
      wwn-0x50000398bb903d0d  (sdc)  ONLINE
      wwn-0x50000398bb883e91  (sdd)  ONLINE
  logs
    mirror-2
      ata-KIOXIA-EXCERIA_SATA_SSD_85LB61PUK0Z5-part1  (sde1)  ONLINE
      ata-KIOXIA-EXCERIA_SATA_SSD_51VB81OWKJ72-part1  (sdf1)  ONLINE
  cache
      ata-KIOXIA-EXCERIA_SATA_SSD_85LB61PUK0Z5-part2  (sde2)  ONLINE
      ata-KIOXIA-EXCERIA_SATA_SSD_51VB81OWKJ72-part2  (sdf2)  ONLINE
```

> プールが自動で見つからない場合: `zpool import -d /dev/disk/by-id tank-gen1`

### 4-4. tank-gen2 インポート

20TB ミラープールをインポートする。

```bash
zpool import tank-gen2

# 状態確認
zpool status tank-gen2
```

期待する構成:
```
pool: tank-gen2
config:
  tank-gen2
    mirror-0
      ata-TOSHIBA_HDWG62CUZSVA_9562A00WFDQJ  (sda)  ONLINE
      ata-TOSHIBA_HDWG62CUZSVA_9562A00QFDQJ  (sdb)  ONLINE
```

### 4-5. 全プール確認

```bash
zpool list
zpool status
```

正常時の期待値:
```
NAME        SIZE   ALLOC   FREE   HEALTH
rpool       928G   ~4G     ~924G  ONLINE
tank-gen1  3.62T  ~687G   ~2.9T  ONLINE   ← 既存データあり
tank-gen2    20T  ~3.6T  ~16.4T  ONLINE   ← 既存データあり
vmpool      928G   ~数MB   ~928G  ONLINE   ← 新規・空
```

---

## Step 5: PVE ストレージ設定

### 5-1. storage.cfg の設定

```bash
cat > /etc/pve/storage.cfg << 'EOF'
dir: local
    path /var/lib/vz
    content backup,iso,vztmpl,snippets

zfspool: local-zfs
    pool rpool/data
    content rootdir,images
    sparse 1

zfspool: vmpool
    pool vmpool
    content rootdir,images
    mountpoint /vmpool
    nodes pve
EOF
```

### 5-2. ストレージ確認

```bash
pvesm status
```

期待する出力:
```
Name        Type     Status  Total       Used        Available
local        dir     active  ...
local-zfs  zfspool   active  ...
vmpool     zfspool   active  ...
```

---

## Step 6: cloud-init スニペット作成

Terraform が VM 作成時に参照する cloud-init スニペットを配置する。

```bash
mkdir -p /var/lib/vz/snippets
```

**k8s 用 cloud-init** (`/var/lib/vz/snippets/k8s-cloud-init.yaml`):

```bash
cat > /var/lib/vz/snippets/k8s-cloud-init.yaml << 'EOF'
#cloud-config
users:
  - default
  - name: ubuntu
    groups: [sudo]
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPHZpYh1V3WHfWU2Tl1XekRfUonVkjwW3yelkzIN+7j9 k8s-cluster
    sudo: ALL=(ALL) NOPASSWD:ALL
packages:
  - qemu-guest-agent
  - net-tools
  - curl
  - wget
  - vim
  - htop
  - tmux
  - jq
  - nfs-common
  - rpcbind
  - dnsutils
  - telnet
  - tcpdump
  - rsync
  - tree
  - unzip
package_update: true
package_upgrade: false
timezone: Asia/Tokyo
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now rpcbind
  - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  - sysctl -p
EOF
```

**Tailscale 用 cloud-init** (`/var/lib/vz/snippets/tailscale-cloud-init.yaml`):

```bash
cat > /var/lib/vz/snippets/tailscale-cloud-init.yaml << 'EOF'
#cloud-config
packages:
  - qemu-guest-agent
  - curl
  - iptables
  - net-tools
  - dnsutils
package_update: true
timezone: Asia/Tokyo
runcmd:
  - systemctl enable --now qemu-guest-agent
  - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
  - echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
  - sysctl -p
  - ethtool -K eth0 rx-udp-gro-forwarding on
  - curl -fsSL https://tailscale.com/install.sh | sh
  - systemctl enable tailscaled && systemctl start tailscaled
EOF
```

---

## Step 7: VM テンプレート作成 (VMID 9000)

Terraform は VMID 9000 (`ubuntu-2404-cloudinit`) をクローン元として使用するため、
事前に手動でテンプレートを作成する必要がある。

```bash
# 作業ディレクトリ
cd /var/lib/vz/template/iso

# Ubuntu 24.04 cloud image をダウンロード
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# VM 作成 (ディスクなし)
qm create 9000 \
  --name ubuntu-2404-cloudinit \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine q35 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --serial0 socket \
  --vga serial0

# cloud image を vmpool にインポート
qm importdisk 9000 noble-server-cloudimg-amd64.img vmpool

# インポートされたディスクをアタッチ (名前は qm config 9000 で確認)
qm set 9000 --scsi0 vmpool:vm-9000-disk-0,discard=on,ssd=1

# cloud-init ドライブを追加
qm set 9000 --ide2 vmpool:cloudinit

# ブートディスク設定
qm set 9000 --boot order=scsi0

# テンプレート化
qm template 9000

# 確認
qm config 9000
```

> **補足:** テンプレートは Terraform が `clone` するためのベースとなる。
> テンプレート自体は起動しないので、ディスクサイズは cloud image そのまま (~3.5GB) で良い。
> 各 VM のディスクサイズは Terraform 側 (`variables.tf`) で指定される。

---

## Step 8: VM プロビジョニング (Terraform)

ここから先は Terraform に引き継ぐ。手動で `qm create` する必要はない。

### 8-1. Kubernetes クラスタ (VM 101-103)

```bash
# ローカル開発機から実行
cd files/infrastructure/terraform/k8s-cluster/
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars   # Proxmox 認証情報と SSH 公開鍵を設定

./setup.sh
# または
terraform init && terraform plan && terraform apply
```

詳細: `files/infrastructure/terraform/k8s-cluster/README.md`

### 8-2. Tailscale ゲートウェイ (VM 105)

```bash
cd files/infrastructure/terraform/tailscale-gateway/
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars

terraform init && terraform plan && terraform apply
```

詳細: `files/infrastructure/terraform/tailscale-gateway/README.md`

### 8-3. 疎通確認

Terraform 完了後に各 VM への疎通を確認する。

```bash
ping -c 3 192.168.10.21  # k8s-master01
ping -c 3 192.168.10.22  # k8s-worker01
ping -c 3 192.168.10.23  # k8s-worker02
ping -c 3 192.168.10.30  # tailscale-gateway

# SSH 接続 (cloud-init で配布された鍵で接続)
ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.21
```

---

## tank-gen1 / tank-gen2 再作成 (参考: インポート失敗時のみ)

> **警告:** 以下はプールのデータが失われる操作。インポートが正常に完了した場合は不要。
> tank-gen1 / tank-gen2 のデータが破損していない限り、`zpool import` が成功するはず。

### tank-gen1 の新規作成

```bash
# KIOXIA SATA SSD を SLOG/L2ARC 用にパーティション分割
# sde: 238G (part1=SLOG) + 655G (part2=L2ARC)
parted /dev/sde mklabel gpt
parted /dev/sde mkpart primary 1MiB 238GiB  # SLOG
parted /dev/sde mkpart primary 238GiB 100%  # L2ARC

parted /dev/sdf mklabel gpt
parted /dev/sdf mkpart primary 1MiB 238GiB
parted /dev/sdf mkpart primary 238GiB 100%

# プール作成
zpool create tank-gen1 \
  mirror \
    wwn-0x50000398bb903d0d \
    wwn-0x50000398bb883e91 \
  log mirror \
    ata-KIOXIA-EXCERIA_SATA_SSD_85LB61PUK0Z5-part1 \
    ata-KIOXIA-EXCERIA_SATA_SSD_51VB81OWKJ72-part1 \
  cache \
    ata-KIOXIA-EXCERIA_SATA_SSD_85LB61PUK0Z5-part2 \
    ata-KIOXIA-EXCERIA_SATA_SSD_51VB81OWKJ72-part2

# データセット作成
zfs create tank-gen1/data
zfs create tank-gen1/data/archive
```

### tank-gen2 の新規作成

```bash
zpool create tank-gen2 \
  mirror \
    ata-TOSHIBA_HDWG62CUZSVA_9562A00WFDQJ \
    ata-TOSHIBA_HDWG62CUZSVA_9562A00QFDQJ

# データセット作成
zfs create tank-gen2/data
zfs create tank-gen2/data/shared
zfs create tank-gen2/data/k8s-volumes
```

---

## Secure Boot 対応 (マザボ交換時)

現在のホストは Secure Boot が **有効 (user モード)** で運用されている。
マザボを交換すると UEFI NVRAM のキー登録が消えるため、そのままでは起動しない。

### 方法① Secure Boot を無効化する (簡単)

新マザボの UEFI セットアップで Secure Boot を OFF にして起動する。Proxmox の動作に影響なし。

### 方法② MOK を再登録する (Secure Boot を維持する)

#### 前提

- Proxmox の署名付きカーネルパッケージがインストール済みであること
  - `proxmox-kernel-*-pve-signed` が入っていれば OK
- Proxmox の MOK 証明書は `/etc/proxmox-ve/pve-signing.key` および
  `/usr/share/pve-utils/pve-kernel-signing.crt` に含まれている

#### 手順

##### 1. 新マザボの UEFI で Secure Boot を "Setup Mode" にする

UEFI セットアップ → Secure Boot → "Clear Secure Boot Keys" または "Reset to Setup Mode" を実行。
これにより Secure Boot は有効だがキーが未登録の状態 (Setup Mode) になる。

##### 2. OS を起動する

Setup Mode では署名検証がスキップされるため、Proxmox がそのまま起動する。

##### 3. Proxmox の MOK を登録する

```bash
# Proxmox 署名証明書を MOK に登録 (要求を発行)
mokutil --import /usr/share/pve-utils/pve-kernel-signing.crt
# パスワードを入力 (再起動時に使用する)
```

##### 4. 再起動して MOK Manager で登録を確定する

```bash
reboot
```

再起動時に青い MOK Manager 画面が表示される:

1. "Enroll MOK" を選択
2. "Continue" → "Yes" → 手順 3 で設定したパスワードを入力
3. "Reboot" で再起動

##### 5. Secure Boot の状態を確認する

```bash
mokutil --sb-state
# → SecureBoot enabled

# 登録された MOK を確認
mokutil --list-enrolled | grep -A5 "Proxmox"
```

#### 補足

- Setup Mode への移行方法は UEFI の実装によって異なる ("Delete all Secure Boot variables" 等の表記の場合もある)
- MOK Manager が表示されない場合は `efibootmgr -v` でブートエントリを確認し、`shimx64.efi` 経由で起動しているか確認する
- `mokutil --import` で登録した要求は再起動後 MOK Manager で承認しないと無効になる (15 分以内)

---

## ネットワーク構成メモ

| ネットワーク | VLAN | サブネット        | 用途                              |
|------------|------|-----------------|----------------------------------|
| VLAN 10    | 10   | 192.168.10.0/24  | 管理・k8s external / Pod external |
| VLAN 11    | 11   | 192.168.11.0/24  | k8s internal / Pod-to-Pod        |

| ホスト            | VLAN10 IP       | VLAN11 IP       |
|-----------------|----------------|----------------|
| PVE ホスト       | 192.168.10.11  | 192.168.11.11  |
| k8s-master01    | 192.168.10.21  | 192.168.11.21  |
| k8s-worker01    | 192.168.10.22  | 192.168.11.22  |
| k8s-worker02    | 192.168.10.23  | 192.168.11.23  |
| tailscale-gw    | 192.168.10.30  | —              |
| Gateway/Router  | 192.168.10.1   | —              |
