# Proxmoxホスト復旧手順

ホストの構成値は2026-10-12にpve1で読み取りコマンドを実行して確認した。
[2026年6月版](../archive/proxmox-rebuild.md)とはOSのレイアウトなどが異なるため、6月版の値を現行値の根拠にしない。
VMに関わる部分は現行のTerraform / Ansible定義に基づく。
以下は実装から導いた手順で、実機では未検証（この並びで通しの再構築は実行していない）。

## 位置づけと順序

pve1のハード交換・OS再インストール後、Proxmox/NFSホストとしての役割と、その上のVM群を復旧する入口である。
Apps VMだけを作り直す場合は[Apps VM復旧手順](apps-vm-recovery.md)から始める。

1. 復旧情報とデータを確保し、ホストOS / Proxmoxを導入する。
2. ホストの管理ネットワークを戻す。
3. ZFS pool、cache-pool、mergerfs、moverを戻す。
4. NFS exportとmarkerを揃える。
5. Proxmox datastore、snippetの置き場所、templateを用意する。
6. Proxmox API権限と管理端末の入力を用意する。
7. VM群を復旧する。
8. ホストとVMの受入確認を行い、結果を記録する。

## 復旧に要るもの

共通のcredential、age鍵、state、application dataは
[必要な復旧情報](apps-vm-recovery.md#必要な復旧情報)と
[保持する復旧資産とデータ](apps-vm-recovery.md#保持する復旧資産とデータ)を参照する。
ホスト復旧では、これに次を加える。

- Proxmox ISO、インストール媒体、ローカルconsole / UEFIへ入る手段、ホストroot credential。
- ディスクのモデル・serial・接続先、ZFS topologyとproperty、ホスト設定の退避記録。
  採取項目は[実機で確認する値](#実機で確認する値)にある。
- 保持するpoolのデータ、cache-pool上の残存ファイル、必要なVM disk。
  2026-10-12の確認ではProxmoxのbackup jobもVM backupも無い（[確認記録](#2026-10-12に確認済み)）。
  vmpoolを新規作成するとVM内データは失われ、現状はbackupから戻せない。Apps VMのnamed volumeは
  [復旧範囲](apps-vm-recovery.md#vm内named-volumeの復旧範囲)、ElastiFlowの保存データは
  [データ永続化](../../files/infrastructure/terraform/elastiflow/README.md#データ永続化)を確認する。
- gateway・ElastiFlow・stashPadDevでも使うApps VM用API token、pve1 root用SSH key、各rootの非秘密のlocal入力。
  実値はKeePassXC等から復元し、旧版の公開鍵・password・tokenを転載しない。

## ホストOSとProxmox

### インストール設定

2026-10-12に`pveversion -v`と`/etc/os-release`でProxmox VE 9.2.3 / Debian 13 (trixie)を確認した。
復旧時に同じmajorを使うか新しい版を採用するかは復旧時に判断する。
Apps VMには後述の`local`のcontent type `import`が必要なので、採用するProxmoxで対応を確認し、
対応しない場合はVM作成に進まない。

ISOは[Proxmoxダウンロードページ](https://www.proxmox.com/en/downloads)から取得してUSB媒体へ書き込む。

| 項目 | 現行の値 / 復旧時の扱い |
| --- | --- |
| OS disk | `nvme1n1`（KIOXIA-EXCERIA PLUS G3 SSD / 931.5G）。serialは未確認のため、再構築前に照合する |
| OS layout | LVM + ext4。VG `pve`に`root`（96G、`/`）、`swap`（8G）、thin pool `data`（793.8G）。EFI partitionはvfat 1G |
| node名 / FQDN | `pve1` / `pve1.kojigenba-srv.com`（各Terraformルートの`node_name`と一致させる） |
| IP / gateway | `192.168.10.11/24` / `192.168.10.1` |
| DNS / Email | 未確認。復旧記録に従う |
| root password | 復旧用credentialとして安全な場所に保管する |

OS layoutは`lsblk`で確認した出来上がりであり、インストーラで選んだfilesystem、hdsize、swapsizeなどの
選択肢は未確認である。保持するデータdiskをインストール先に選択しない。
FQDNの設定でも短いhostname / Proxmox node名が`pve1`となることを確認する。

### APTと初期設定

2026-10-12にAPT設定から抽出した値では、deb822形式の`.sources`を使い、
`/etc/apt/sources.list`に`deb`行は無かった。Debianは`trixie` / `trixie-updates` / `trixie-security`、
Proxmoxは`trixie`の`pve-no-subscription`が有効で、`pve-enterprise`と`ceph`は`Enabled: false`だった。
`/etc/apt/sources.list.d/`には`debian.sources`、`proxmox.sources`、`pve-enterprise.sources`、`ceph.sources`があった。
各stanzaとファイル名の対応、`Signed-By`などその他の行は未確認である。

復旧時はインストーラが置く`.sources`を確認し、enterpriseとcephを無効、no-subscriptionを有効にする。
採用OSのsuiteと署名設定を確認し、設定ファイル全体を旧版から上書きしない。

```bash
cat /etc/apt/sources.list
cat /etc/apt/sources.list.d/*.sources
apt-get update && apt-get dist-upgrade -y

hostname
hostname -f
cat /etc/hosts
pvesh get /nodes
pvesh set /cluster/options --keyboard ja
```

2026-10-12に`/etc/hosts`で確認したホストの行は次のとおりである。

```text
192.168.10.11 pve1.kojigenba-srv.com pve1
```

`hostname`と`pvesh get /nodes`で`pve1`を確認してからTerraformへ進む。

### Secure Boot / MOK（マザーボード交換時）

2026-10-12に`mokutil --sb-state`で`SecureBoot disabled`を確認した。
有効にして運用する場合のMOK再登録は[6月版の該当節](../archive/proxmox-rebuild.md#方法②-mok-を再登録する-secure-boot-を維持する)を参照し、
採用するkernel・証明書と交換後のUEFI設定を別途確認する。

## ホストのネットワーク

[network README](../../files/infrastructure/network/README.md#物理ポート)と
[`config.txt`](../../files/infrastructure/network/config.txt)では、PVE1はIX2215 Port 1に接続し、
PVE trunkで運ぶのはtagged VLAN 10だけである。untaggedフレームはL3へ収容しない。
ホストもVMもServer VLAN 10を使い、廃止済みVLANのinterfaceは復元しない。
他zoneの境界は[ネットワークゾーン仕様](../network/target-zones.md)を参照する。

2026-10-12に`/etc/network/interfaces`でNIC名`nic0`、`vmbr0`の`inet static`と
`bridge-vids 2-4094`を確認した。MACは未確認である。交換後は`ip link show`でNIC名を照合し、
ローカルconsoleで`/etc/network/interfaces`を設定する。

```text
auto lo
iface lo inet loopback

iface nic0 inet manual

auto vmbr0
iface vmbr0 inet static
	bridge-ports nic0
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094

auto vmbr0.10
iface vmbr0.10 inet static
        address 192.168.10.11/24
        gateway 192.168.10.1

source /etc/network/interfaces.d/*
```

2026-10-12に`/etc/network/interfaces`を`/etc/network/interfaces.bak-20261012-vmbr0.11`へコピーし、
`ifdown vmbr0.11`の後、廃止済みVLAN 11の`auto vmbr0.11` stanza（4行）だけを削除した。
`ifreload`は実行せず、`vmbr0.11`の不存在とVLAN 10・default routeの維持を確認し、削除後の内容は上の復旧設定と一致した。
このバックアップは、`vmbr0.11`削除後の動作確認ができたため、同日（2026-10-12）に削除した。

`ifreload -a`またはrebootで反映し、`ip -br address`、`ip route`、`bridge vlan show`で確認する。
管理端末から`https://192.168.10.11:8006/`へ接続できることを確認する。

## ストレージ

### ディスクとpoolの識別

次は2026-10-12に`lsblk`、`zpool list`、`zpool status -P`で確認した配置である。
`sd*`の並びは6月版と変わっているため、`/dev/sd*` / `/dev/nvme*`の列挙順を識別子として使わず、
by-idと再構築前の採取記録で照合する。

| 確認時のデバイス | モデル / 容量 | 用途 |
| --- | --- | --- |
| nvme1n1 | KIOXIA-EXCERIA PLUS G3 SSD / 931.5G | OS（LVM + ext4） |
| nvme0n1 | WD_BLACK SN770 1TB / 931.5G | VM disk / vmpool |
| sda / sdb | TOSHIBA HDWG62CUZSVA / 各20T | tank-gen2 mirror |
| sdc / sde | TOSHIBA MD04ACA400 / 各3.6T | tank-gen1 mirror |
| sdd | PLEXTOR PX-512M8VC / 476.9G | tank-gen2 L2ARC |
| sdf / sdg | KIOXIA-EXCERIA SATA SSD / 各894.3G | cache-pool mirror |

| pool / 配置 | by-id識別子（`/dev/disk/by-id/`配下） |
| --- | --- |
| vmpool（単一disk） | `nvme-WD_BLACK_SN770_1TB_22390J802169-part1` |
| tank-gen1 mirror（SLOG / L2ARCなし） | `wwn-0x50000398bb903d0d-part1`、`wwn-0x50000398bb883e91-part1` |
| tank-gen2 mirror | `ata-TOSHIBA_HDWG62CUZSVA_9562A00WFDQJ-part1`、`ata-TOSHIBA_HDWG62CUZSVA_9562A00QFDQJ-part1` |
| tank-gen2 L2ARC | `ata-PLEXTOR_PX-512M8VC_P02947400134-part1` |
| cache-pool mirror（`autotrim=on`） | `ata-KIOXIA-EXCERIA_SATA_SSD_85LB61PUK0Z5-part1`、`ata-KIOXIA-EXCERIA_SATA_SSD_51VB81OWKJ72-part1` |

4 poolとも確認時は`ONLINE`だった。`/var/lib/vz`はOSのroot filesystem（`pve-root`）上にある。
`tank-gen1` / `tank-gen2`は一部featureが未有効化であり、有効化は不可逆なので復旧手順では`zpool upgrade`を実行しない。

### vmpool

vmpoolを保持する場合はimportし、既存VM diskの復元・stateとの対応を先に確認する。
以下はVM diskを破棄して新規作成する場合だけ使う。現状VM backupは無いため、保持するVM内データの
退避・復旧元を別途確保し、対象serialを照合してから進む。保持するpoolのdiskを選択しない。

対象diskのby-idを実機で確認し、`nvme0n1`全体を指すリンク名を確認する。

```bash
ls -l /dev/disk/by-id/ | grep 22390J802169
```

以下の`nvme-WD_BLACK_SN770_1TB_22390J802169`は、上で確認したdisk全体のby-id名に置き換える。
2026-10-12に確認したのはpartition側の`nvme-WD_BLACK_SN770_1TB_22390J802169-part1`で、
disk全体のby-idは未確認である。

```bash
zpool labelclear -f /dev/disk/by-id/nvme-WD_BLACK_SN770_1TB_22390J802169
zpool create -f -o ashift=12 -o cachefile=none vmpool \
  /dev/disk/by-id/nvme-WD_BLACK_SN770_1TB_22390J802169
zfs set compression=on vmpool
zpool status vmpool
```

### データpoolのimportとmergerfs

保持したpoolを一覧で識別してからimportする。既にimportされているpoolには重ねて実行しない。
見つからない場合は`zpool import -d /dev/disk/by-id`で探索する。importできないpoolを新規作成して
データを上書きせず、復旧元と障害原因を確認する。

```bash
zpool import
zpool import tank-gen1
zpool import tank-gen2
zpool import cache-pool
zpool status
zfs list -o name,mountpoint,mounted
```

2026-10-12に`zfs list -d 2`で確認したdatasetとmountpointは次のとおりである。

```text
cache-pool                    /mnt/cache-sata
tank-gen1                     /mnt/tank-gen1
tank-gen1/data                /mnt/tank-gen1/data
tank-gen1/data/archive        /mnt/tank-gen1/data/archive
tank-gen2                     /mnt/tank-gen2
tank-gen2/data                /mnt/tank-gen2/data
tank-gen2/data/ai             /mnt/tank-gen2/data/ai
tank-gen2/data/k8s-volumes    /mnt/tank-gen2/data/k8s-volumes
tank-gen2/data/shared         /mnt/tank-gen2/data/shared
vmpool                        /vmpool
```

cache-poolを新規に戻す場合の残存ファイルの復元元は、採取記録とbackupで確認する。
repoにはcache-pool作成を自動化する定義が無いため、ここで新規作成コマンドは定義しない。

2026-10-12のpackageは`mergerfs 2.40.2-5`、`nfs-kernel-server 1:2.8.3-1`だった。
mergerfsを導入し、[fstab設定](tiered-storage.md#etcfstabmergerfsマウント)を復元する。
両branchが`/mnt/cache-sata`と`/mnt/tank-gen2/data/shared`へ正しくmountされていることを確認してから、
`mkdir -p /mnt/shared`、`mount /mnt/shared`でunion mountを戻す。
cache-poolの`autotrim=on`とAHCI接続も同文書に従って確認する。

### mover、cron、logrotate

2026-10-12に`/usr/local/bin/mover.sh`とrepoの`files/infrastructure/storage/mover.sh`のsha256が一致したことを確認した。
logrotateの配置先は`/etc/logrotate.d/mover.logrotate`だった。
repoからpve1へ手動で配置する。Apps VM用Ansibleはこの配置を行わない。
以下はpve1にrepoの対象ファイルを用意し、そのrootから実行する配置例である。

```bash
install -m 0755 files/infrastructure/storage/mover.sh /usr/local/bin/mover.sh
install -m 0644 files/infrastructure/storage/mover.logrotate /etc/logrotate.d/mover.logrotate
```

rootのcronへ[毎朝5時の設定](tiered-storage.md#moverスクリプト)を戻す。
配置後にrepoのscriptと`/usr/local/bin/mover.sh`を照合し、両mountと所有者を確認してからcronを有効にする。
移動・snapshot・logの仕組みと確認方法は同文書を参照する。

## NFS exportとmarker

[NFS export契約](nfs-export.md)を正として、pve1のNFS server設定とexport tableを手動で復元する。
既存4 exportはApps VMの`192.168.10.101/32`、DGXも使う`ai`だけは`192.168.10.0/24`である。
2026-10-12にpve1で`exportfs -v`を実行し、この契約どおりのexportを確認した。

現行の9 mountの正は`files/infrastructure/ansible/apps/group_vars/apps.yml`の`nfs_mounts`である。
各exportと[marker](nfs-export.md#マーカー契約)が揃わないと、Apps VMのmount guardが失敗し、
全Compose projectの起動を止める。markerを未mountの空directoryへ作って検査を通さない。
保持したdataset上のdata / owner / modeとmarker内容を照合してからVMを復旧する。
DGXの`ai`再mountは[DGX Sparkストレージ運用](dgx-storage.md)を参照する。

## Proxmoxのdatastoreとtemplate

### storage.cfgとsnippetの置き場所

各ルートのVM diskは`vmpool`、snippetは`local`を使う。Apps VMの`main.tf`はcloud imageも
`snippet_datastore_id`（default `local`）へcontent type `import`でdownloadする。
2026-10-12に`/etc/pve/storage.cfg`と`pvesm status`で次の構成を確認し、3 storageとも`active`だった。
`local-lvm`の使用量は0で、VM diskはすべて`vmpool`だった。
復旧時はこの構成へ戻し、`import`が利用できることを採用version / datastoreで確認する。

```text
dir: local
	path /var/lib/vz
	content snippets,vztmpl,backup,import,iso
	shared 0

lvmthin: local-lvm
	thinpool data
	vgname pve
	content rootdir,images

zfspool: vmpool
	pool vmpool
	content rootdir,images
	mountpoint /vmpool
	nodes pve1
```

```bash
mkdir -p /var/lib/vz/snippets
pvesm status
pvesh get /storage/local
```

cloud-init snippetは各ルートの`main.tf`が生成する。ここでは置き場所だけ用意し、手書きsnippetや
固定SSH公開鍵を投入しない。Apps VMのimage URL / checksumは`apps-vm/variables.tf`を正とし、
手動downloadやtemplateへの置き換えは行わない。

### template VM 9000

Apps VMにはtemplateが不要である。gateway・ElastiFlow・stashPadDevは各`main.tf`の`clone`で
`template_vm_id`（各`variables.tf`のdefault `9000`）を使う。
2026-10-25のread-only採取で現物の設定と元imageを特定し、
[`scripts/create-proxmox-ubuntu-template.sh`](../../scripts/create-proxmox-ubuntu-template.sh)に固定した。
同日、運用者が9001を作成し、net0を`tag=10`へ変更してElastiFlow rootからVM 103へのcloneを確認した後、
scriptで9000を作り直して9001を削除した。9000のキー照合はすべて`OK`、diskはraw / 3758096384 bytesだった。
gateway / stashPadDevのrootからのcloneは未検証である。9000を削除する前に、必ず別VMIDで検証する。

採用imageはUbuntu 24.04 amd64の`release-20260518`である。

- 固定URL: <https://cloud-images.ubuntu.com/releases/noble/release-20260518/ubuntu-24.04-server-cloudimg-amd64.img>
- SHA-256: `53fdde898feed8b027d94baa9cfe8229867f330a1d9c49dc7d84465ee7f229f7`
- download size: 627923968 bytes、元qcow2のvirtual-size: 3758096384 bytes（3584 MiB）
- 2026-10-25に`SHA256SUMS.gpg`のGood signatureを確認した。採用時の署名鍵fingerprintは
  `D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81`。image更新時も署名を確認してからURL・hashを一緒に変更する。
- 固定URLは`http://cloud-images-archive.ubuntu.com/releases/noble/release-20260518/ubuntu-24.04-server-cloudimg-amd64.img`へ
  redirectされる。scriptはHTTPへのredirectを許可し、毎回repo固定のSHA-256で内容を照合する。
  2026-10-25はarchiveから598 MBの取得に52分（約196 KB/s）かかったため、約50分以上の取得時間を見込む。
  upstream消失時に備え、image・SHA256SUMS・署名を別途保管する。rolling imageへ切り替えない。

pve1に残っていた`/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img`は上記hashと一致し、
9000.confのmtimeは2026-05-24だった。scriptはこの既存ファイルには触れず、
`/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64-release-20260518.img`を使う。
pve1に同じhashのimageがあれば、上記cache名へコピーして使える。
そのファイルがありhashが合えば再利用し、無ければ同じdirectoryの一時ファイルへdownloadし、照合後にrenameする。
hashが合わないcacheまたはdownload途中のファイルは削除して停止する。

旧9000を基にした設定は次のとおり。MACとstorageが割り当てるdisk番号は固定しない。
旧9000（2026-05作成）のnet0はtagなしだった。2026-10-25に9001からVM 103へのTerraform cloneが
`HTTP 403: Permission check failed (/sdn/zones/localnetwork/vmbr0, SDN.Use)`で失敗したため、
権限を増やさず`tag=10`に変更し、再実行でcloneが成功した。旧9000との設定の違いはこの1キーだけである。

| キー | 値 |
| --- | --- |
| name / memory / cores | `ubuntu-2404-cloudinit` / `2048` / `2` |
| cpu / machine / scsihw | `host` / `q35` / `virtio-scsi-pci` |
| net0 | `virtio,bridge=vmbr0,tag=10` |
| scsi0 | 指定storageのbase disk、`discard=on,size=3584M,ssd=1`（raw、3758096384 bytes） |
| ide2 / boot | 指定storageのcloud-init drive（`media=cdrom`） / `order=scsi0` |
| serial0 / vga / template | `socket` / `serial0` / `1` |
| ostype / agent / bios / citype / onboot | 未設定 |

clone側のrootが`ostype`と`agent`を設定する。上記net0の例外以外は現物再現を優先し、
`virtio-scsi-single`への変更（clone側の`iothread`との整合など）は行っていない。
採取時のPVEはpve-manager 9.2.3 / qemu-server 9.1.16で、`qm create/set`の`import-from`対応を確認した。
scriptは`qm create` → `qm set --scsi0 <storage>:0,import-from=...` → cloud-init / boot設定 →
`qm template`の順に実行し、`qm config`の表示・キーごとの一致判定（MACを除く）とdiskのraw / size照合を行う。
template自体は起動しない。VMごとのdisk sizeはApps VM・gatewayが各`main.tf`、
ElastiFlow・stashPadDevが各`variables.tf`の`disk_size_gb`で宣言する。

#### 配置と別VMIDでの検証

管理端末のrepo rootからscriptをファイルとして転送する。stdinでscriptを流さない。
2026-10-25に運用者が9001の作成とElastiFlow rootからのcloneを実機で確認した。
以下の9900を使う汎用clone試験は未検証であり、同日の確認範囲は[VM 103の作り直し](../../files/infrastructure/terraform/elastiflow/README.md#vm-103-の作り直し)を参照する。

```bash
scp scripts/create-proxmox-ubuntu-template.sh root@192.168.10.11:/root/create-proxmox-ubuntu-template.sh
```

その後pve1のroot consoleで実行する（Bash、Python 3、curl、sha256sum、flock、PVE標準コマンドが必要）。
`--vmid`は必須、`--storage`の既定は`vmpool`。現物どおりraw diskを作れるstorageを使う。

```bash
bash /root/create-proxmox-ubuntu-template.sh --vmid 9001 --storage vmpool
```

scriptはcluster全体のQEMU/LXCを照会し、既存VMIDを拒否する。照会失敗・不正な応答でも停止する。
VMIDの空きは実行時に再確認する（2026-10-25の採取時には9001、9900は空いていた）。
途中で失敗しても作りかけのVMやvolumeは自動削除せず、失敗した工程と設定・volumeの確認結果を表示する。
表示も失敗した場合は手動で確認し、残存物の扱いを判断する。同じIDでの再実行やforce上書きはできない。

9001のキー照合がすべて`OK`になってから、空きVMIDを選びfull cloneを試す。
以下の9900は例なので、使用中なら別IDを選ぶ。

```bash
qm clone 9001 9900 --full 1 --storage vmpool --name ubuntu-template-test
```

検証cloneには3 root相当のCPU / RAM / disk拡張、agent、cloud-init、VLAN / DNS設定を適用し、
専用の検証用IP・鍵を使って起動する。本番IPやtailnet登録は流用しない。
Ubuntu 24.04、`cloud-init status --wait`、`ubuntu` userのsudo、package導入、guest agent応答、
disk拡張、network / DNS、serial console、再起動を確認する。
gatewayの本番route広告・exit node承認は行わない。検証結果と後片付けの対象VMIDを記録する。

#### 既存9000を同じVMIDで作り直す場合

9001の作成とclone検証が成功するまで9000を消さない。削除・再作成は本番操作なので、実施時に明示承認を得る。
gateway・ElastiFlow・stashPadDevの既存VMはfull cloneなのでtemplateのdiskに依存しない。
根拠は各`main.tf`の`clone.full = true`と`lifecycle.ignore_changes`の`clone[0].vm_id`である
（[gateway](../../files/infrastructure/terraform/tailscale-gateway/main.tf)、
[ElastiFlow](../../files/infrastructure/terraform/elastiflow/main.tf)、
[stashPadDev](../../files/infrastructure/terraform/stashpad-dev/main.tf)）。
同じ9000の再作成やclone参照IDだけの変更は既存VMのTerraform差分にならず、既存guestのOSも更新しない。
他の設定差分が無いことまで保証するものではなく、将来の新規作成・再作成には新templateを使う。

1. 9001と検証cloneの結果を保存し、9000が対象の停止templateであることと、他のclone操作が無いことを確認する。
2. 9000の設定・volume情報を保存し、削除の明示承認を得てからpve1のroot consoleで`qm destroy 9000`を行う。
3. `bash /root/create-proxmox-ubuntu-template.sh --vmid 9000 --storage vmpool`を実行し、すべての照合が`OK`であることを確認する。
4. destroyで`/vms/9000`のACLも消えるため、clone用ACLを付け直す。

   ```bash
   pveum acl modify /vms/9000 --user terraform@pve --role HomelabTerraformClone --propagate 0
   ```

5. 結果と実施日を記録し、不要になった9001・検証cloneだけを運用者が確認して手動削除する。
   途中で失敗した場合はscriptの表示を基に残存VM・volumeを確認し、再開前に扱いを判断する。

2026-10-25はcacheを再利用して9000を作り直し、ACLを付け直してから9001を削除した
（9001のACLもProxmoxが削除）。最終状態は101〜105・111がrunning、9000がtemplateで、
`terraform@pve`の`/vms` ACLは101〜105・111が`HomelabTerraform`（propagate 1）、
9000が`HomelabTerraformClone`（propagate 0）だった。

## ProxmoxのAPI権限

user / role / token / ACLは
[Terraform実行前のProxmox側準備](apps-vm-recovery.md#terraform実行前のproxmox側準備)に従う。
共通API token `terraform@pve!terraform`（`privsep=0`、comment `Terraform (all Proxmox roots)`）の
期限は2027-10-31 23:59:59 JST（UNIX time `1824994799`）で、Apps VM / Agent / Runner /
gateway / ElastiFlow / stashPadDevの6 rootで共用する。稼働中のサービスは使わず、期限切れでも停止しない。
期限切れは全6 rootの次回Terraform実行へ影響する。次の実行前に再発行または期限延長を行い、
[期限確認・token再発行とsecret差し替えの手順](apps-vm-recovery.md#403-permission-check-failedが出たときの診断手順)に従う。
2026-10-25に共通tokenへ移行済み。確認結果と旧token削除は[実施記録](apps-vm-recovery.md#実機確認認証移行の実施記録2026-10-25)を参照する。
管理端末のSSH agent・host key・state復元・保存plan・state backupの前提も同文書を使う。
全rootでKeePassXCから`TF_VAR_proxmox_api_token`へ一時注入し、tfvarsには非秘密の値だけを置く。
snippet転送にはSSH agent経由のpve1 root接続を使う。

## VM群の復旧

VMごとの再構築性とbackupの方針は[現行アーキテクチャ](../architecture/target-state.md#再構築性とbackupの方針)を参照する。

次のVMID / LAN IP / 作成方式の正は各Terraformルートの`main.tf`と`variables.tf`である。
全ルートのnodeは`pve1`、bridgeは`vmbr0`、VM NICはVLAN 10である。

| VM | VMID | LAN IP | 役割 | Terraformルート / 復旧入口 | 作成方式 |
| --- | --- | --- | --- | --- | --- |
| Apps VM | 101 | `192.168.10.101` | DNS、SMB、HTTPSとComposeアプリ | `files/infrastructure/terraform/apps-vm/` / [Apps VM復旧](apps-vm-recovery.md) | Debian 13 cloud imageを直接import |
| Tailscale gateway | 102 | `192.168.10.102` | 宅外からLAN機器へ入る経路、exit node | [files/infrastructure/terraform/tailscale-gateway/](../../files/infrastructure/terraform/tailscale-gateway/README.md) | template 9000のfull clone |
| ElastiFlow | 103 | `192.168.10.103` | フロー収集・保存・可視化 | [files/infrastructure/terraform/elastiflow/](../../files/infrastructure/terraform/elastiflow/README.md) | template 9000のfull clone |
| Hermes Agent VM | 104 | `192.168.10.104` | Hermes常駐エージェント、Hindsight記憶、記憶DB、TEI（tailnet外） | [files/infrastructure/terraform/agent-vm/](../../files/infrastructure/terraform/agent-vm/README.md) / [Hermes Agent運用](hermes-agent.md) | Debian 13 cloud imageを直接import |
| Hermes Runner VM | 105 | `192.168.10.105` | コマンド実行と隔離ブラウザ（tailnet外、Dockerなし） | [files/infrastructure/terraform/runner-vm/](../../files/infrastructure/terraform/runner-vm/README.md) / [Hermes Agent運用](hermes-agent.md) | Debian 13 cloud imageを直接import |
| stashPadDev | 111 | `192.168.10.41` | 開発用。本番復旧の対象外 | [files/infrastructure/terraform/stashpad-dev/](../../files/infrastructure/terraform/stashpad-dev/README.md) | template 9000のfull clone |

2026-10-12にpve1の`qm list`で次を確認した。名前・メモリ・boot diskは各Terraform定義
（`main.tf`の固定値、または`variables.tf`のdefault）と一致していた。復旧時の宣言値はTerraformを正とし、
この表は確認日の実機記録として扱う。

| VMID | 名前 | 状態 | メモリ | boot disk |
| --- | --- | --- | --- | --- |
| 101 | apps | running | 12288 MB | 40 G |
| 102 | tailscale-gateway | running | 4096 MB | 20 G |
| 103 | elastiflow | running | 32768 MB | 128 G |
| 111 | stashPadDev | running | 16384 MB | 30 G |

VMID 104 / 105（Hermes Agent / Runner）は2026-10-12時点では存在せず、上の`qm list`確認記録には含まれない。
復旧時の宣言値は各Terraformルート（`main.tf`と`variables.tf`）を正とする。

1. Apps VMを戻す。NFSが揃ってから[復旧フロー](apps-vm-recovery.md#復旧フロー)に従い、
   `make terraform-plan` / `make terraform-apply`、`make ansible-apply`を使う。
   [tailnet再登録](apps-vm-tailnet.md#現在の手順apps-vmを再構築再登録するとき)を含み、
   tailnet IPは`group_vars/apps.yml`の`apps_tailnet_ip`へ合わせる。DNSとSMBはApps VMが提供する。
2. gatewayを戻す。template 9000が必要で、Terraform後の手動tailnet登録 → Ansible prefs適用（未検証）→ route / exit node承認は
   gateway READMEに従う。宅外からホストを管理する経路が先に必要なら、template準備後に
   gatewayをApps VMより先に戻す。Apps VMサービスへの直接tailnet接続はgatewayを経由しない。
3. ElastiFlowを戻す。templateからTerraform/cloud-initでVMを作成した後、READMEの
   `make ansible-apply-elastiflow` でpackage・設定・固定dashboardを反映し、受信確認と
   再実行時のchanged=0を確認する。2026-10-25にVM 103を作り直して実機で確認した。
   router側のcollector定義は`files/infrastructure/network/config.txt`で確認する。
4. エージェントを戻す。Agent VM / Runner VMのVM定義はTerraform、OSとサービスはAnsibleで再構築し、
   記憶とセッションはpve1の専用NFS exportへ取った日次バックアップから戻す。復号identityは運用者が
   管理端末で与える。手順は[Hermes Agent運用](hermes-agent.md)と
   [Hermes Agentバックアップ運用](hermes-agent-backup.md)を正とする。Proxmoxのtoken/ACLは他のVMと同様に
   手動で用意する。
5. 開発作業を再開する場合だけstashPadDevを戻す。VM作成後は
   [READMEの開発環境の再構築](../../files/infrastructure/terraform/stashpad-dev/README.md#開発環境の再構築)に従う（手順は実機未検証）。

gateway等のraw apply後の`make state-backup`は各READMEに従う。
既存resourceと復元stateを照合し、意図しないdestroy / replaceがあるplanを適用しない。
tailnetのDNS / ACL / routeはホストOSと別の管理対象なので、残存状態を確認し、必要な場合だけ
[Tailscale Terraform](../../files/infrastructure/terraform/tailscale/README.md)のimport / plan / applyを行う。

## 検証

pve1で次を確認する。

```bash
hostname
pvesh get /nodes
zpool list
zpool status
zfs list -o name,mountpoint,mounted
zpool get autotrim cache-pool
findmnt -M /mnt/cache-sata
findmnt -M /mnt/tank-gen2/data/shared
findmnt -M /mnt/shared -o TARGET,SOURCE,FSTYPE,OPTIONS
exportfs -v
pvesm status
pvesh get /storage/local
qm list
qm config 9000
```

- poolがONLINEで、保持したdataset / snapshotが存在し、想定pathへmountされていること。
- mergerfsのbranch順序・optionが[Tiered Storage](tiered-storage.md#設定)と一致すること。
- exportのpath / client / optionと全markerの内容が[NFS契約](nfs-export.md#マーカー契約)と一致すること。
  例えば`cat /mnt/tank-gen2/data/shared/.homelab-export-shared`で`shared`、
  `cat /mnt/tank-gen2/data/shared/.homelab-export-shared-hdd`で`shared-hdd`を確認し、残りも契約表と照合する。
- moverの配置・cron・logrotateを確認する。手動moverの確認は書き込み停止中に
  [既存の確認方法](tiered-storage.md#moverスクリプト)で行う。
- datastoreがactiveで、`local`に`snippets` / `import`、`vmpool`に`images`があり、
  cloneを使う場合はtemplate 9000が存在すること。

VM側は[Apps VMの復旧検証](apps-vm-recovery.md#復旧の検証)、
[tailnet検証](apps-vm-tailnet.md#現在の手順apps-vmを再構築再登録するとき)、gateway・ElastiFlowのREADMEへ進む。
DGXもホストのNFS clientなので[DGX側の検証](dgx-storage.md)を行う。
日付、操作者、Git commit、採用OS / image、state backup revision、確認結果を復旧記録へ残す。

## 実機で確認する値

2026-10-12に確認した項目と未確認の項目を分ける。確認済みの値も再構築前に採取し直し、
KeePassXCや運用記録に保存して復旧時の照合元にする。

### 2026-10-12に確認済み

| 対象 / 確認値 | 再採取・照合コマンド（pve1） |
| --- | --- |
| Proxmox VE 9.2.3 / Debian 13 (trixie) | `pveversion -v`、`cat /etc/os-release` |
| `pve1` / `pve1.kojigenba-srv.com` / hosts行 | `hostname`、`hostname -f`、`cat /etc/hosts` |
| OSのLVM + ext4 layout、diskモデル・配置、poolのby-id | `lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS`、`ls -l /dev/disk/by-id/`、`zpool status -P` |
| 4 poolのtopology・ONLINE、cache-poolのautotrim | `zpool list`、`zpool status -P`、`zpool get autotrim cache-pool` |
| dataset mountpoint、Phase 5直前snapshotの現存 | `zfs list -d 2`、`zfs list -t snapshot` |
| NIC名`nic0`、bridge / VLAN 10設定 | `cat /etc/network/interfaces` |
| mergerfs / NFS package、fstab、union mount | `dpkg-query -W mergerfs nfs-kernel-server`、`cat /etc/fstab`、`findmnt -M /mnt/shared -o SOURCE,FSTYPE,OPTIONS` |
| moverのrepoとの一致、root cron、logrotate配置先 | `sha256sum /usr/local/bin/mover.sh`（repoと比較）、`crontab -l`、`ls -l /etc/logrotate.d/mover.logrotate` |
| APT suite・component・有効/無効の状態 | `cat /etc/apt/sources.list /etc/apt/sources.list.d/*.sources` |
| storage.cfgのcontent、storageのactive状態、VM一覧 | `cat /etc/pve/storage.cfg`、`pvesm status`、`qm list` |
| backup jobなし、VM backupなし | `/etc/pve/jobs.cfg`、`/etc/pve/vzdump.cron`、`pvesm list <storage> --content backup`、`/var/lib/vz/dump`、`storage.cfg`（[確認結果](apps-vm-recovery.md#vm内named-volumeの復旧範囲)） |
| Secure Boot無効 | `mokutil --sb-state` |
| NFS exportのclient / option / fsid | `exportfs -v`（[契約](nfs-export.md#実測された親export)と比較） |
| user `terraform@pve`、role `HomelabTerraform`、token `apps-vm`（privsep 0、期限2026-12-04）、ACL 6 path（VLAN 11用ACLは同日に削除） | `pveum user list`、`pveum role list`、`pveum user token list terraform@pve`、`pveum acl list`（[詳細](apps-vm-recovery.md#terraform実行前のproxmox側準備)） |

### 未確認

| 対象 | 再構築前の確認方法（pve1、または保存した復旧記録） |
| --- | --- |
| NICのMAC、OS diskのserial | `ip link show`、`lsblk -o NAME,MODEL,SERIAL` |
| UEFI / BIOS設定、MOK / boot entry | UEFI画面、`mokutil --list-enrolled`、`efibootmgr -v` |
| インストーラの選択肢、DNS、Email | 保存したインストール・復旧記録 |
| APTの各stanzaとファイル名の対応、署名設定 | `cat /etc/apt/sources.list.d/*.sources` |
| `/etc/exports`のファイルそのもの、marker | `cat /etc/exports /etc/exports.d/*`、[marker契約](nfs-export.md#マーカー契約)との照合 |
| template 9000の詳細設定 | `qm config 9000` |

exportは再構築時にmarkerとともに再照合する。

採取できない項目は未確認として記録し、旧版の値で補わない。

Hermes Agentについて、2026-10-17のローカル試験では暗号化scratch restoreとDB復元を確認したが、
VM初回構築・OS reboot・本番DR・Runner/NFSは実機未検証である。ローカルの品質再試験では主要閾値を満たしたが、
創作1件とrerank速度の残課題があり、
この復旧手順が通しで検証済みという意味ではない。詳細は[Hermes Agent運用](hermes-agent.md)を参照する。
