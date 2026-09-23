# NFS export契約

- 状態: marker・`ai` export反映済み。旧4 exportは2026-09-23にApps VM `/32`へ制限済み
- サーバー: Proxmox/NFS host `192.168.10.11`
- データ復旧: このリポジトリの対象外
- 関連設計: [目標ストレージ契約](../architecture/target-state.md#storage-contract)
- 実測記録: [実機インベントリ（2026-08-30）](../architecture/live-inventory-2026-08-30.md)

このリポジトリはNFS serverの設定を自動変更しない。以下はApps VMが必要とするexportを、復旧時と
移行時に再現するための契約である。実機のfilesystem、既存export、NFSv4 pseudo-rootを確認してから
`/etc/exports.d/homelab-apps.exports`等へ手動反映する。

## 実測された親export

2026-08-30の確認では、次の4つの親pathが`192.168.10.0/24`に公開されていた。
2026-09-23にApps VMの`/32`へ狭め、`exportfs -v`で確認した。

| サーバーpath | client範囲 | 主要option（実測） | 固有option |
| --- | --- | --- | --- |
| `/mnt/tank-gen2/data/k8s-volumes` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen1/data/archive` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen2/data/shared` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=101` |
| `/mnt/shared` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=100` |

## Apps VMの利用path

親exportの下にある利用pathは7つで、2026-08-30時点では全て存在した。個別pathをexportする契約では
なく、mount後にmarkerで正しいdatasetを確認する。

| 利用path | Apps VMでの用途 | アクセス |
| --- | --- | --- |
| `/mnt/shared` | Samba `shared` | read/write |
| `/mnt/tank-gen2/data/shared` | Samba `shared-hdd` | read/write |
| `/mnt/tank-gen1/data/archive` | Samba `archive` | read/write |
| `/mnt/shared/koji-genba/stashPadLib` | stashPad media | container bind mountはread-only |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa` | SillyTavern data | read/write |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b` | stashPad prod metadata | read/write |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b` | stashPad staging metadata | read/write |

stashPad mediaは`/mnt/shared`の子であり、同じclientに親exportのwrite権限がある。したがって、子pathを
別のread-only exportにするだけではserver側のsecurity boundaryにならない。実際の書込み防止はComposeの
read-only bind mountで行う。

## AI dataset export（ADR-0006）

DGX Spark 2台とApps VMが共有する、モデルと学習データ（tar.gz）の置き場である。既存4 exportとは
別のdatasetにして、mergerfsのSSDキャッシュ、`mover.sh`、`tank-gen2/data/shared`のsnapshotの
いずれも働かせない。

| 項目 | 値 |
| --- | --- |
| dataset | `tank-gen2/data/ai` |
| 明示するproperty | `recordsize=1M`のみ（`atime=off`と`compression=lz4`はpool継承） |
| server側path | `/mnt/tank-gen2/data/ai` |
| client範囲 | `192.168.10.0/24` |
| option | `rw,sync,no_subtree_check,no_root_squash`（固有optionなし。`fsid`は指定しない） |
| owner / mode | `root:root` / `0777` |
| marker | `/mnt/tank-gen2/data/ai/.homelab-export`、内容は`ai` |
| snapshot | 取らない（再取得可能なデータとして扱う） |

clientは次の3つで、いずれも同じ条件でmountする。read-only mountもclientごとのexport分割も行わない。

| client | mount先 | 用途 |
| --- | --- | --- |
| Apps VM `192.168.10.101` | `/srv/homelab/nfs/ai` | Samba `[ai]` shareの再export |
| DGX Spark 4TB機 `192.168.10.51` | `/mnt/ai` | 主client |
| DGX Spark 1TB機 `192.168.10.52` | `/mnt/ai` | 同上 |

DGX側の手順は[DGX Sparkストレージ運用](dgx-storage.md)にある。

## フェーズごとのclient範囲

| フェーズ | client指定 |
| --- | --- |
| Kubernetes稼働中 | 既存node clauseを維持し、Apps `192.168.10.42/32`を追加 |
| Kubernetes停止後 | Apps `192.168.10.42/32`だけ |
| VLAN移行後 | Apps `192.168.10.101/32`だけ |

最終行の状態を2026-09-23に適用した。変更前の`/etc/exports`はpve1の
`/etc/exports.pre-phase5-20260923`に保管した。変更後のSHA-256は
`062c8bf15dfd10bbd75ebd336d1aa6a9eddb96c99a222ee4644b277e581f3d04`。

この収束計画の対象は既存4 exportである。`ai` exportはDGX Spark 2台もclientであるため、
`192.168.10.0/24`のままとする。Server VLAN内を同一trust boundaryとして扱う
[ADR-0003](../adr/0003-four-network-zones.md)の前提に従い、host単位の`/32`へは狭めない。

基本optionは `rw,sync,no_subtree_check,no_root_squash` とする。client mount optionへ`sync`は付けない。
`no_root_squash`は既存UID/GIDとの初期互換性のためで、移行後の所有者検証を終えたら
`root_squash`へ狭められるか再評価する。

フェーズ1ではexportが`rw`でもApps VM側を`ro`でmountし、旧Kubernetesを唯一のwriterにする。
cutover確認後だけApps VM側mountを`rw`へ変更する。

## Apps VMの`nconnect`

`nconnect`はmountごとではなく、server address、protocol、NFS versionが同じNFS client単位で共有される。
このため、`192.168.10.11`への8つのmount（既存7つ＋ADR-0006の`ai`）は全て`nconnect=8`を指定する。DGX側はこのserverへのmountが`ai`の1つだけなので、この制約は生じない。

既存mountへのremountでは接続数を変更できない。設定反映には`192.168.10.11`へのmountを全てunmount
してからmountし直す必要があり、Apps VMではrebootで実施する。reboot後は次のcommandで確認する。

```sh
awk '/^device 192.168.10.11/{d=$2} /xprt:/{c[d]++} END{for(k in c) print c[k], k}' /proc/self/mountstats
```

各mountについて`8 <device>`が出力されることを期待する。

## マーカー契約

誤ったexportや未mountの空directoryへcontainerが書き込むことを防ぐため、各利用pathには
固有markerをserver側で作る。markerはdata copyで偶然複製されないよう、pathごとに一意な識別子を
内容として持たせる。Apps VMのmount guardはmount source、mount type、marker名、marker内容を検証する。

`/mnt/shared`は`/mnt/cache-sata:/mnt/tank-gen2/data/shared`のmergerfsであり、直接HDD exportと
`tank-gen2/data/shared`を共有する。同じ`.homelab-export`へ異なる値を置けないため、この2 mountだけ
固有のmarker名を使う。両markerはmover対象のcacheではなくsnapshot対象のHDD側へ直接作成する。

既存の必要なmarkerは次の7つである。2026-08-30の時点では全て未作成である。

| server側の実体path | marker内容 |
| --- | --- |
| `/mnt/tank-gen2/data/shared/.homelab-export-shared` | `shared` |
| `/mnt/tank-gen2/data/shared/.homelab-export-shared-hdd` | `shared-hdd` |
| `/mnt/tank-gen1/data/archive/.homelab-export` | `archive` |
| `/mnt/tank-gen2/data/shared/koji-genba/stashPadLib/.homelab-export` | `stashpad-media` |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa/.homelab-export` | `sillytavern-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b/.homelab-export` | `stashpad-prod-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b/.homelab-export` | `stashpad-staging-data` |

ADR-0006の`ai` exportを追加した時点で、次の1件が加わって8つになる。

| server側の実体path | marker内容 |
| --- | --- |
| `/mnt/tank-gen2/data/ai/.homelab-export` | `ai` |

markerはApps VMの未mount directoryには絶対に作らない。NFS server local consoleで対象datasetとpathを
確認して作成し、snapshot/backup対象に含める。`archive`と`k8s-volumes`には自動snapshotがないため、
少なくとも移行前snapshotを別途取得してからフェーズ2へ進む。

## 手動反映の記録手順

1. `findmnt`、ZFS dataset、対象pathのowner/mode/ACL/xattrを記録する。
2. 現在の`exportfs -v`を保存する。
3. client clauseを現在のPhaseに合わせる。
4. 設定syntaxを確認し、export tableをreloadする。
5. `exportfs -v`で有効なpath、client、optionを再確認する。
6. Apps VM側でNFSv4 mount、read-only/read-write mode、marker内容を確認する。
7. 意図しないclientからmountできないことを確認する。

実施時は日付、操作者、変更前後の`exportfs -v`、設定fileのhash、対応するGit commitを移行記録へ残す。
