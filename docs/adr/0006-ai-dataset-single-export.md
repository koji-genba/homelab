# ADR-0006: DGX Sparkのデータ置き場を単一NFS exportにする

- 状態: 承認済み（設計）。実機反映は未実施
- 日付: 2026-09-19

## 背景

DGX Sparkを2台（4TB SKUと1TB SKU）導入し、GE2 port 3/4のServer VLAN 10へ接続する。用途は
学習用モデルの置き場と、学習データをtar.gzで置く倉庫である。

既存の共有経路はpve1の`/mnt/shared`（mergerfs）をApps VMがNFS mountし、Sambaで再exportする
構成である。この`/mnt/shared`には次の仕組みが自動で働く。

- `category.create=ff`により新規書き込みは常にSSDのcache-pool（888GB、空き805GB）へ入る
- 毎朝5時の`mover.sh`がSSDからHDDへ移す
- `tank-gen2/data/shared`に日次14・週次8・月次12の計34世代のsnapshotを取る

モデルと学習データはサイズがTB級で、かつ再取得可能である。この3つの仕組みはいずれも
このデータに対しては有害で、SSDキャッシュの枯渇、毎晩のTB級move、snapshotによる容量増幅を
引き起こす。

ネットワークは全区間1GbEである。pve1のNICは`RTL8111`1本、IX2215内蔵switchも1GbEで、
10GbE化にはNICだけでなくswitchの導入が必要になる。今回は投資しない判断とした。

## 決定

`tank-gen2`に独立したdataset `tank-gen2/data/ai` を作り、**単一のNFS exportとして公開する。**

- export: `/mnt/tank-gen2/data/ai` を `192.168.10.0/24` へ `rw,sync,no_subtree_check,no_root_squash`
  で公開する。既存4 exportと同じ書式・同じclient範囲であり、固有optionは持たない
- `fsid`は指定しない。明示が必要なのはFUSEの`/mnt/shared`と、それとinode空間を共有する
  `tank-gen2/data/shared`だけである。素のZFS datasetはカーネルがfsidを導出できる
- **read-only exportやclientごとのexport分割は行わない。** DGX 2台とApps VMは同一の1 exportを
  同一の条件でmountする
- dataset propertyは`recordsize=1M`だけを明示する。`atime=off`と`compression=lz4`はpool継承で
  既に目的の値である
- **snapshotは設定しない。** `mover.sh`のsnapshotは`tank-gen2/data/shared`だけを対象とするため、
  この決定は「何もしない」ことで達成される。データは再取得可能であることを前提とする
- 所有者は`root:root`、modeは`0777`とする。SMB（Sambaのuid）とDGX 2台（操作者のuid）が同じ
  directoryへ書くため、uid/gidを揃えない唯一の単純な解である。既存の`k8s-volumes`配下も`0777`
- SMBは既存Apps VMのSambaに`[ai]` shareを追加する。pve1やDGXにSMB serverを増やさず、
  「Apps VMが唯一のwriter」というADR-0001の前提を崩さない。`[ai]`だけ`create mask = 0666`、
  `directory mask = 0777`とし、他shareの`0600/0700`と揃えない

## 検討して採らなかった案

**`/mnt/shared`配下のdirectoryにする。** exportもshareも増えないが、上記3つの仕組みが全て
このデータに働いてしまう。独立datasetのほうが設定量が少なく、かつ何も起きない。

**models/datasetsをread-only exportにする。** 誤削除の防波堤にはなるが、export行とmount行が
倍になり、DGX 2台で書ける場所と書けない場所の区別を運用中に覚える必要が出る。単一bucketという
今回の要件に対して複雑さが見合わない。またADR-0001の記述どおり、親exportがrwである以上、
子pathのro exportはserver側のsecurity boundaryにならない。

**10GbE化。** NICだけでなくswitchが必要になり、かつ`tank-gen2`はHDD 2本mirrorで
シーケンシャル200〜400MB/s程度であるため、投資に対する上限が低い。1GbEのまま運用し、
必要になった時点で再評価する。

## 影響

- pve1のexportが4つから5つになる。`192.168.10.0/24`公開のため、DGXの追加でIX2215の
  ACL変更は不要である（Server VLAN内は同一trust boundary、ADR-0003）
- `docs/operations/nfs-export.md`のclient範囲計画は、Apps VM `/32`への収束を前提としていた。
  `ai` exportはDGX 2台もclientになるため、この1 exportだけ`/24`のままとする例外を明記する
- 1GbE（実効110MB/s）が前提となるため、運用側で次を守る。tar.gzはNFS上で展開せずDGXの
  ローカルNVMeへ展開する。`HF_HOME`/`HF_HUB_CACHE`はNFSへ置かない。2台分のstagingは
  4TB機を起点とし、1TB機はDGX間のQSFP直結経路から読む
