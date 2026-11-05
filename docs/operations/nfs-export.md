# NFS export契約

- 状態: `ai`・`archive`の切り替え完了時に適用する契約。pool運用は[tank-gen3運用](tank-gen3.md)を参照
- `shared`は2026-10-29に`async`へ変更済み。既存の`shared-hdd`とほかのexportは`sync`を維持。
- `scratch`は2026-11-05反映・確認済み（`async`・all_squash）。確認結果と残る確認事項は[scratch運用](scratch-storage.md)を参照。
- `hermes` と ai client の `/32` 化は2026-11-05 10:21 JSTに反映・確認済み。手順は [Hermes 共有運用](hermes-share.md)。
- サーバー: Proxmox/NFS host `192.168.10.11`
- データ復旧: このリポジトリの対象外
- 関連設計: [目標ストレージ契約](../architecture/target-state.md#storage-contract)
- 実測記録: [実機インベントリ（2026-08-30）](../archive/live-inventory-2026-08-30.md)

このリポジトリはNFS serverの設定を自動変更しない。以下はApps VM / Agent VM等が必要とするexportを、復旧時と
移行時に再現するための契約である。実機のfilesystem、既存export、NFSv4 pseudo-rootを確認してから
`/etc/exports`へ手動反映する（2026-10-18時点の実機では`/etc/exports.d/`は空）。

## 実測された親export

2026-08-30の確認では、次の4つの親pathが`192.168.10.0/24`に公開されていた。
2026-09-23にApps VMの`/32`へ狭め、`exportfs -v`で確認した。
2026-10-12にpve1の`exportfs -v`で、既存4 exportの`192.168.10.101/32`、`ai`の`192.168.10.0/24`、
`/mnt/shared`の`fsid=100`と`/mnt/tank-gen2/data/shared`の`fsid=101`が契約どおりであることを再確認した。
以下の表はその後の変更を反映しており、`/mnt/shared`の`async`は2026-10-29の変更後の値である。

以下の表は切り替え完了時の契約。過去の実測が新pathを検証済みという意味ではない。

| サーバーpath | client範囲 | 主要option（契約） | 固有option |
| --- | --- | --- | --- |
| `/mnt/tank-gen2/data/k8s-volumes` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen3/data/archive` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | なし |
| `/mnt/tank-gen2/data/shared` | `192.168.10.101/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=101` |
| `/mnt/shared` | `192.168.10.101/32` | `async,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid=100`（2026-10-29にasync化） |
| `/mnt/tank-gen1/data/scratch` | `192.168.10.101/32`・`192.168.10.51/32`・`192.168.10.52/32` | `rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004` | `fsid`なし（2026-11-05反映・確認済み） |
| `/mnt/tank-gen1/data/hermes` | `192.168.10.101/32`・`192.168.10.105/32` | `rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004`（既定`secure`維持） | `fsid`なし、2026-11-05反映・確認済み |
| `/mnt/tank-gen3/data/ai` | `192.168.10.101/32`・`192.168.10.51/32`・`192.168.10.52/32` | `rw,sync,no_subtree_check,no_root_squash` | `/24`から2026-11-05に絞り込み・確認済み |
| `/mnt/tank-gen2/data/agent-backups` | `192.168.10.104/32` | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` | `fsid`なし（2026-10-18作成） |

`ai`と`archive`には明示的な`fsid`を追加しない。marker名・値は移行前と同じで、
`archive` markerは`0:0` / `0644`を保持する。archive exportとApps mountのrw契約は維持し、
datasetも`readonly=off`（書き込み可）とし、毎日04:30の自動snapshotで世代を保持する。

## Apps VMの利用path

親exportの下にある利用pathは7つで、2026-08-30時点では全て存在した。個別pathをexportする契約では
なく、mount後にmarkerで正しいdatasetを確認する。

| 利用path | Apps VMでの用途 | アクセス |
| --- | --- | --- |
| `/mnt/shared` | Samba `shared` | read/write |
| `/mnt/tank-gen2/data/shared` | Samba `shared-hdd` | read/write |
| `/mnt/tank-gen3/data/archive` | Samba `archive` | read/write（自動snapshotで世代保持） |
| `/mnt/shared/koji-genba/stashPadLib` | stashPad media | container bind mountはread-only |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa` | SillyTavern data | read/write |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b` | stashPad prod metadata | read/write |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b` | stashPad staging metadata | read/write |

stashPad mediaは`/mnt/shared`の子であり、同じclientに親exportのwrite権限がある。したがって、子pathを
別のread-only exportにするだけではserver側のsecurity boundaryにならない。実際の書込み防止はComposeの
read-only bind mountで行う。

Open WebUIのdata用に、次のpathを2026-10に宣言へ追加した。`k8s-volumes`親exportの下のdirectoryなので
export設定は変わらない。pve1側のdirectoryとmarkerは2026-10-10に作成し、`exportfs -v`に変化がない
ことを確認した。

| 利用path | Apps VMでの用途 | アクセス |
| --- | --- | --- |
| `/mnt/tank-gen2/data/k8s-volumes/open-webui` | Open WebUI data | read/write |

手順は[Open WebUI運用](open-webui.md)にある。

| 追加利用path | Apps VMでの用途 | アクセス |
| --- | --- | --- |
| `/mnt/tank-gen1/data/scratch` | Samba `scratch`だけ（2026-11-05反映・確認済み） | read/write、消失許容 |
| `/mnt/tank-gen1/data/hermes` | Samba `hermes`だけ（2026-11-05反映・確認済み） | read/write、消失許容 |

## AI dataset export（ADR-0006）

DGX Spark 2台とApps VMが共有する、モデルと学習データ（tar.gz）の置き場である。既存4 exportとは
別のdatasetにして、mergerfsのSSDキャッシュ、`mover.sh`、`tank-gen2/data/shared`のsnapshotの
いずれも働かせない。

| 項目 | 値 |
| --- | --- |
| dataset | `tank-gen3/data/ai` |
| 明示するproperty | `recordsize=1M`のみ（`atime=off`と`compression=lz4`はpool継承） |
| server側path | `/mnt/tank-gen3/data/ai` |
| client範囲 | `192.168.10.101/32`・`192.168.10.51/32`・`192.168.10.52/32`（2026-11-05絞り込み・確認済み） |
| option | `rw,sync,no_subtree_check,no_root_squash`（固有optionなし。`fsid`は指定しない） |
| owner / mode | 既存の数値UID/GIDとmodeをsend/recvで保持。markerは`10002:10002` / `0644` |
| marker | `/mnt/tank-gen3/data/ai/.homelab-export`、内容は`ai` |
| snapshot | 取らない（再取得可能なデータとして扱う） |

clientは次の3つで、いずれも同じ条件でmountする。read-only mountもclientごとのexport分割も行わない。

| client | mount先 | 用途 |
| --- | --- | --- |
| Apps VM `192.168.10.101` | `/srv/homelab/nfs/ai` | Samba `[ai]` shareの再export |
| DGX Spark 4TB機 `192.168.10.51` | `/mnt/ai` | 主client |
| DGX Spark 1TB機 `192.168.10.52` | `/mnt/ai` | 同上 |

DGX側の手順は[DGX Sparkストレージ運用](dgx-storage.md)にある。

Hermes 共有追加時は Runner の TCP 2049 を開ける前に、ai の既存 `/24` entry を上記 3 つの `/32` に置換する。
option と dataset・mountpoint は変えない。2026-11-05 10:21 JSTにこの手順で反映した。
事前に`/proc/fs/nfsd/clients`の相手が`.101`・`.104`・`.51`・`.52`だけと確認し、
aiは3 clientへ絞った。`exportfs -v`と、Apps・両DGXの既存aiがnfs4のまま読めることを確認した。
過去の`/24`実測と今回の確認記録は区別する。

## scratch export（2026-11-05反映済み）

00:18にdataset・exportを作成し、`exportfs -v`で3 clientの`/32`と契約のoption、
既存6 exportが不変であることと全poolのhealthyを確認した。Appsのmount・guard・Samba、
両DGXのmount・書き込み、WindowsのSMB作成・読み取り・削除も同日確認済み。

消えてもよい作業用。datasetは`tank-gen1/data/scratch`、quotaは`3T`。
Appsは`/srv/homelab/nfs/scratch`からSambaだけへ渡し、両DGXは`/mnt/scratch`へmountする。
入口は`root:10004 1775`、全NFSアクセスは`10002:10004`へsquashする。
markerとREADMEは`root:root 0644`で、stickyにより利用者からの削除を防ぐ。
スナップショット・バックアップ・自動削除は無い。既存aiのUID通過・sync契約とは異なる。
property、exportsの完全な1行、作成・確認・切り離し・撤去は[scratch運用](scratch-storage.md)を参照する。

## Hermes 受け渡し export（2026-11-05反映済み）

10:21 JSTにdataset・権限・marker・README・exportを作成し、`exportfs -ra`を実行した。
`exportfs -v`でApps・Runnerの2 clientと契約のoption、他exportが不変であること、全poolのhealthyを確認した。
共有利用の結果と残る確認事項は[共有運用](hermes-share.md)を参照する。

専用 dataset `tank-gen1/data/hermes`、quota 2T、入口 `root:10004 1775`、
`inbox/`・`outbox/` は `10002:10004 2775`。Apps と Runner だけへ公開し、DGX へは公開しない。
全 NFS アクセスを `10002:10004` へ squash する。`secure` を維持し、高位送信元ポートからの直接 NFS を許可しない。
非特権ユーザーは root が mount した kernel NFS を使う。snapshot・backup 無し、内容は外へ出得る。
Runner は `/srv/agent-work/share` で automount、Apps は `/srv/homelab/nfs/hermes` から Samba のみへ渡す。
完全な exports 行、marker・日英 README の作成と反映順序は [共有運用](hermes-share.md) を参照する。

## Agentバックアップ用export（2026-10-18作成）

Agent VM専用の暗号化バックアップ置き場。pve1側の作成と`exportfs -ra`後の`exportfs -v`確認まで実施済み。

| 項目 | 値 |
| --- | --- |
| dataset | `tank-gen2/data/agent-backups` |
| property | `quota=300G`、`recordsize=1M`、`compression=lz4`（継承） |
| server側path / mountpoint | `/mnt/tank-gen1/data/hermes` | `192.168.10.101/32`・`192.168.10.105/32` | `rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004`（既定`secure`維持） | `fsid`なし、2026-11-05反映・確認済み |
| `/mnt/tank-gen3/data/ai` | `192.168.10.101/32`・`192.168.10.51/32`・`192.168.10.52/32` | `rw,sync,no_subtree_check,no_root_squash` | `/24`から2026-11-05に絞り込み・確認済み |
| `/mnt/tank-gen2/data/agent-backups` |
| client範囲 | `192.168.10.104/32` |
| `/etc/exports`のoption | `rw,sync,no_subtree_check,sec=sys,secure,no_root_squash,no_all_squash`（`fsid`なし） |
| 有効option | `sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash` |
| owner / mode | `root:root` / `0700` |
| marker | `/mnt/tank-gen2/data/agent-backups/.homelab-export-agent-backups`、内容は`agent-backups` |
| snapshot | なし。バックアップ自体が世代管理・暗号化されるため取らない |
| client mount | Agent VM `/mnt/agent-backups`（2026-10-18のAnsible適用でnfs4 mount・backup成功を確認） |

2026-10-18の再適用で、Ansibleのmount-point作成taskがmount済みのexport rootを`0750`へ変更した
（`no_root_squash`）。WS26ではmount済みなら作成taskをskipし、server側のowner/modeに触れないよう修正した。
同日、運用者がAgent VMのrootから`chmod 0700 /mnt/agent-backups`を実行し、
`no_root_squash`経由でexport rootを`root:root 0700`へ復旧済み。6回目のAnsible適用では
agent-vm / runner-vmともchanged=0、export root 0700を維持し、健康確認all checks passed。

設定は既存exportと同じ`/etc/exports`に追加した。変更後のSHA-256（2026-10-18）は
`5639f51953049d980b62faa7745546f9a6364e8eaeb8ffebe306327369f118fe`。
詳細は[Agentバックアップのpve1準備](hermes-agent-backup.md#7-pve1-側の事前準備手動自動化しない)を参照。

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

基本optionは `rw,sync,no_subtree_check,no_root_squash` とする。ただし`shared`（`/mnt/shared`）は
2026-10-29から`rw,async,no_subtree_check,no_root_squash,fsid=100`とする。client mount optionへ`sync`は付けない。
新規scratchは別契約の`rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004`とする。
`no_root_squash`は既存UID/GIDとの初期互換性のためで、移行後の所有者検証を終えたら
`root_squash`へ狭められるか再評価する。

`shared`の変更は、ファイルごとのNFS COMMITがmergerfsのfsyncを待つ時間を減らすためである。
pve1の異常停止時には、完了応答済みの直近数秒程度の書き込みを失う危険を受け入れる。
主用途は元ファイルがPCに残るコピーで、`shared-hdd`（`fsid=101`）とほかのexportは`sync`のままとする。
判断の根拠・計測・UPSの制約は[2026-10の調査記録](smb-performance-troubleshooting.md#2026-10-小さめのファイルを大量に書くと速度が出ない)を参照する。

フェーズ1ではexportが`rw`でもApps VM側を`ro`でmountし、旧Kubernetesを唯一のwriterにする。
cutover確認後だけApps VM側mountを`rw`へ変更する。

## Apps VMの`nconnect`

`nconnect`はmountごとではなく、server address、protocol、NFS versionが同じNFS client単位で共有される。
このため、repo宣言の`192.168.10.11`への11 mount（既存9つ＋scratch＋hermes。hermesも2026-11-05反映・確認済み）は全て`nconnect=8`を指定する。
scratchは2026-11-05に追加し、Apps・両DGXで`rw,vers=4.1,nconnect=8`を確認済み。DGXもaiとscratchの両方を`nconnect=8`に揃える。

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
| `/mnt/tank-gen3/data/archive/.homelab-export` | `archive` |
| `/mnt/tank-gen2/data/shared/koji-genba/stashPadLib/.homelab-export` | `stashpad-media` |
| `/mnt/tank-gen2/data/k8s-volumes/sillytavern-sillytavern-data-pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa/.homelab-export` | `sillytavern-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-be70-49ca-865f-989e77359a6b/.homelab-export` | `stashpad-prod-data` |
| `/mnt/tank-gen2/data/k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b/.homelab-export` | `stashpad-staging-data` |

ADR-0006の`ai` exportを追加した時点で、次の1件が加わって8つになる。

| server側の実体path | marker内容 |
| --- | --- |
| `/mnt/tank-gen3/data/ai/.homelab-export` | `ai` |

Open WebUIのdata pathを追加した時点で、次の1件がさらに加わる（2026-10-10に作成）。

| server側の実体path | marker内容 |
| --- | --- |
| `/mnt/tank-gen2/data/k8s-volumes/open-webui/.homelab-export` | `open-webui-data` |

scratchの追加時に次の1件も作成し、Apps・両DGXで値を確認した（2026-11-05）。

| server側の実体path | marker内容 |
| --- | --- |
| `/mnt/tank-gen1/data/scratch/.homelab-export` | `scratch`（`root:root 0644`、改行付き） |

hermes の追加時に `/mnt/tank-gen1/data/hermes/.homelab-export` を値 `hermes`（改行付き）、
`root:root 0644` で作成し、Runner と Apps の双方で照合した（2026-11-05）。

scratchのmarkerはsnapshot/backupに含めず、喪失時はREADME・dataset・exportとともに作り直す。

markerはApps VMの未mount directoryには絶対に作らない。NFS server local consoleで対象datasetとpathを
確認して作成し、scratch・hermes以外は各datasetのsnapshot/backup方針に従う。`archive`は毎日04:30の自動snapshot対象である。
`k8s-volumes`には自動snapshotがないため、少なくとも移行前snapshotを別途取得してからフェーズ2へ進む。

2026-11-04の補足: 明示の了承を得てPhase 5直前の手動snapshotも削除したため、
現在の`k8s-volumes`には自動・手動ともsnapshotがない。
取得方針は[issue #185](https://github.com/koji-genba/homelab/issues/185)、
名前を変えるかは[issue #190](https://github.com/koji-genba/homelab/issues/190)で扱う。

## 手動反映の記録手順

1. `findmnt`、ZFS dataset、対象pathのowner/mode/ACL/xattrを記録する。
2. 現在の`exportfs -v`を保存する。
3. client clauseを現在のPhaseに合わせる。`/etc/exports`には列揃えの複数空白があるため、行を機械的に探すときは空白の数を決め打ちしない。
4. 設定syntaxを確認し、export tableをreloadする。
5. `exportfs -v`で有効なpath、client、optionを再確認する。
6. Apps VM側でNFSv4 mount、read-only/read-write mode、marker内容を確認する。
7. 意図しないclientからmountできないことを確認する。

実施時は日付、操作者、変更前後の`exportfs -v`、設定fileのhash、対応するGit commitを移行記録へ残す。
