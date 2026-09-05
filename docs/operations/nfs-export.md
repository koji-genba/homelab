# NFS export契約

- 状態: 手動反映メモ（未適用）
- サーバー: Proxmox/NFS host `192.168.10.11`
- データ復旧: このリポジトリの対象外
- 関連設計: [目標ストレージ契約](../architecture/target-state.md#storage-contract)
- 実測記録: [実機インベントリ（2026-08-30）](../architecture/live-inventory-2026-08-30.md)

このリポジトリはNFS serverの設定を自動変更しない。以下はApps VMが必要とするexportを、復旧時と
移行時に再現するための契約である。実機のfilesystem、既存export、NFSv4 pseudo-rootを確認してから
`/etc/exports.d/homelab-apps.exports`等へ手動反映する。

## 実測された親export

2026-08-30の確認では、次の4つの親pathが`192.168.10.0/24`に公開され、主要optionは全て同じだった。
これは現状の記録であり、フェーズ2のwriter停止後にApps VMの`/32`へ狭める。

| サーバーpath | client範囲 | 主要option（実測） | 固有option |
| --- | --- | --- | --- |
| `/mnt/tank-gen2/data/k8s-volumes` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen1/data/archive` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen2/data/shared` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=101` |
| `/mnt/shared` | `192.168.10.0/24` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=100` |

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

## フェーズごとのclient範囲

| フェーズ | client指定 |
| --- | --- |
| Kubernetes稼働中 | 既存node clauseを維持し、Apps `192.168.10.42/32`を追加 |
| Kubernetes停止後 | Apps `192.168.10.42/32`だけ |
| VLAN移行後 | Apps `192.168.10.101/32`だけ |

基本optionは `rw,sync,no_subtree_check,no_root_squash` とする。client mount optionへ`sync`は付けない。
`no_root_squash`は既存UID/GIDとの初期互換性のためで、移行後の所有者検証を終えたら
`root_squash`へ狭められるか再評価する。

フェーズ1ではexportが`rw`でもApps VM側を`ro`でmountし、旧Kubernetesを唯一のwriterにする。
cutover確認後だけApps VM側mountを`rw`へ変更する。

## マーカー契約

誤ったexportや未mountの空directoryへcontainerが書き込むことを防ぐため、各利用pathには
`.homelab-export` markerをserver側で作る。markerはdata copyで偶然複製されないよう、pathごとに
一意な識別子を内容として持たせる。Apps VMのmount guardはmount typeとmarker内容の両方を検証する。

必要なmarkerの識別子は次の7つである。2026-08-30の時点では全て未作成である。

```text
shared
shared-hdd
archive
stashpad-media
sillytavern-data
stashpad-prod-data
stashpad-staging-data
```

markerはApps VMの未mount directoryには絶対に作らない。NFS server local consoleで対象datasetとpathを
確認して作成し、snapshot/backup対象に含める。

## 手動反映の記録手順

1. `findmnt`、ZFS dataset、対象pathのowner/mode/ACL/xattrを記録する。
2. 現在の`exportfs -v`を保存する。
3. client clauseを現在のPhaseに合わせる。
4. 設定syntaxを確認し、export tableをreloadする。
5. `exportfs -v`で有効なpath、client、optionを再確認する。
6. Apps VM側でNFSv4 mount、read-only/read-write mode、marker内容を確認する。
7. 意図しないclientからmountできないことを確認する。

実施時は日付、操作者、変更前後の`exportfs -v`、設定fileのhash、対応するGit commitを移行記録へ残す。
