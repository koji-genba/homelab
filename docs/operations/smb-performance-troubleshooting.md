# SMB転送速度トラブルシューティング

## 現在の切り分けの入口

名前`\\samba.kojigenba-srv.com\<share>`はtailnetの`100.86.147.127`へ接続する。
LAN経路は`\\192.168.10.101\<share>`を指定して比較する。NFS transportの確認対象は
`group_vars/apps.yml`の`nfs_mounts`にある現在9 mountで、[NFS export契約](nfs-export.md#apps-vmのnconnect)を参照する。
以下の`.10.23` / `.10.30`、7 mount、NFS PVは調査当時の値である。

WindowsクライアントからSambaへの転送が遅い件の調査記録。現時点で3件ある。

| 時期 | 症状 | 原因 |
| --- | --- | --- |
| 2026-07 | 読み書きとも約50MB/sで頭打ち | Tailscale subnet routeによるヘアピン |
| 2026-09 | 速度が出たり0になったりを繰り返す | cache-pool SSDにTRIMが通っていなかった |
| 2026-10 | 小さめのファイルを大量に書くと速度が出ない | ファイルごとのNFS COMMITがmergerfsのfsyncを待つ |

# 2026-07: 読み書きとも約50MB/sで頭打ち

## 結論

**原因はTailscaleのsubnet routeによるヘアピン。** WindowsクライアントのTailscaleがsubnet route (192.168.10.0/24, 192.168.11.0/24) を受け入れていたため、同一LAN内にいてもトラフィックが

```
Windows → WireGuardトンネル → tailscale-gateway VM (1vCPU/768MB) → 宛先
```

と迂回し、ゲートウェイVMのWireGuard暗号化・フォワーディング処理がボトルネックになっていた。読み書き対称に遅いのはこのため(ストレージ層なら通常は書き込みだけ遅くなる)。

対処はWindowsクライアント側で:

```powershell
tailscale set --accept-routes=false
```

- 即時反映・永続。GUIの「Use Tailscale subnets」のチェックを外すのと同じ設定。
- 対処後、SMBは読み書きとも約100MB/s(1GbEの実効上限)に到達し解決。

### accept-routes=false の影響範囲

| 機能 | 影響 |
|---|---|
| 宅外からこのマシンへのアクセス (100.x peer通信) | 影響なし |
| MagicDNS / DNS設定 | 影響なし (`--accept-dns` は別スイッチ) |
| exit node利用 | 影響なし (`--exit-node` は別スイッチ) |
| このマシンを宅外に持ち出して192.168.x.xへアクセス | **不可になる**(必要時はtrueに戻す) |

ADR-0007適用後はroaming machineでも`accept-routes=false`のまま、Apps VMのserviceへ
100.xで宅外から接続できる。上表の「不可になる」はApps VM以外のLAN hostに限り、
それらへはgateway exit node経由で接続する（[ADR-0007](../adr/0007-apps-vm-tailnet-dns.md)）。
2026-09-26時点で、desktopから名前でSMBへ接続するとApps VMとのdirect WireGuard経路（gatewayを経由しない）
となり、1GbE相当の速度で実用上の劣化はなかった。2026-07の低速はWireGuardそのものではなく、
当時1vCPU/768MBのgateway VMでの暗号化・転送がボトルネックだった。

デスクトップ(常時宅内)なら実質ノーデメリット。

## 切り分けの記録

1. **読み込みも50MB/sで頭打ち** → ストレージ書き込みパス(NFS syncマウント等)ではなく経路の対称的ボトルネックと判断。
2. **iperf3 (Windows → 192.168.10.23) の接続元が 192.168.10.30 (tailscale-gateway)** — Windowsが直接来ていれば192.168.20.xになるはず。ここでTailscale経由が発覚。
3. `Get-NetRoute` で 192.168.10.0/24 と 192.168.11.0/24 がTailscaleインターフェース (NextHop 100.100.100.100) に向いていることを確認。Windows版Tailscaleはsubnet routeをデフォルトで受け入れる。
4. Tailscale切断後、SMBは読み書き約100MB/sに回復。

## 白と判定したもの

- **NFS PVの `sync` マウントオプション** (pv-shared / pv-shared-hdd / pv-archive): 当初の第一容疑者だったが、1GbE律速の範囲では書き込み100MB/sを維持できており今回はボトルネックではなかった。ネットワークを10GbE化する際は再検証すること。
- **VMのvirtioシングルキュー**: multiqueue=4適用済みを確認。
- **ゲストのネットワークスタック / virtio / ホストブリッジ**: VM間iperf3が10.8Gbpsで安定。
- **ホストCPU競合**: ゲストの%steal変動なし。pve1は5900X (12C/24T) に対し割当11vCPUでオーバーコミットなし。ecoモード(65W)も無関係。
- **メモリ逼迫**: なし。

## 残課題: ルーター経由の単一TCPフローが二状態になる

Windows(VLAN20)からVLAN10/11へのiperf3単一TCPフローが、**約940Mbps(ワイヤレート)と約200Mbpsの二状態**を示す。どちらになるかはフロー(コネクション)単位で決まり、フローの途中で遷移することもある。VLAN10宛て・VLAN11宛ての両方で発生。

- **仮説**: IX2215のVLAN間ルーティングで、UFSキャッシュ(ファストパス)に乗ったフローはワイヤレート、CPU処理(スロースパス)に落ちたフローが約200Mbps。config上は `ip ufs-cache max-entries 20000` + BVIごとのservice-policy/filterあり。
- **実害が小さい理由**: SMB3はマルチチャネルで複数コネクションに分散するため当たり外れが均され、実測100MB/s出る。
- **次の一手**: 遅いラン中にIX2215のCPU使用率とufs-cache統計を確認する。

## 副次的な知見

- IX2215のQoSポリシーで `ipv4_udp_range` (UDP sport/dport 1024-65535) が voiceクラス → DSCP 48 にマークされるため、**WireGuard(UDP)のトラフィックはTCPより優遇される**。Tailscale経由のiperf3が直通TCPより速く見えることがあったのはこれが一因。
- Tailscale経由か直通かは、サーバー側から見た接続元IPで即判別できる(gateway経由だと現在の宣言では192.168.10.102にSNATされる。
  IPの正は`files/infrastructure/terraform/tailscale-gateway/variables.tf`の`ip_address`を参照)。

# 2026-09: 速度が出たり0になったりを繰り返す

Apps VM (Docker Compose) へ移行後、Tailscale接続したWindows 11から`shared`へFLACを書き込むと、
速度が出る状態と0になる状態を数秒ごとに繰り返すようになった。

## 結論

**原因はcache-pool (KIOXIA EXCERIA SATA SSD ×2) にTRIMが一度も通っていなかったこと。**
SSDが解放済み領域を知らされず内部処理に追われ、書き込みレイテンシが平均48msまで悪化していた。
HDD (N300) の起動以来平均14msより遅いという異常な状態だった。摩耗は7%と2%で寿命ではない。

TRIMが通らない理由はHBAの変換層にある。

- 2台はLSI SAS2008 (mpt3sas, FW P20) に接続され、OSからはSCSIディスクに見えていた。
- SAS2008のファームウェアは、TRIM後にゼロが返ると保証するドライブ (ATA IDENTIFYの
  RZAT/DRATビット) だけを「UNMAP対応」と報告する。
- EXCERIAはTRIM自体には対応するがこのビットを持たない。結果、Linuxは`provisioning_mode=full`
  とし、`discard_max_bytes=0`、ZFSからは`trim unsupported`に見えていた。
- 同じHBAのPLEXTOR PX-512M8VCはこのビットを持つため`provisioning_mode=unmap`で通っていた。

対処は**SSD 2台をマザーボードのSATAポート (AHCI) へ移設**すること。libataはRZAT/DRATがなくても
TRIMを発行する (ゼロ保証がない扱いになるだけで、ZFSはそれを必要としない)。移設後に初回TRIMと
`autotrim=on`を実施した。

```bash
zpool trim cache-pool
zpool set autotrim=on cache-pool
```

なお、Linux側で`provisioning_mode`を`unmap`へ書き換えるのは意味がない。HBAが変換しなければ
エラーになるだけである。

## 止まる仕組み

1. Windowsから届いたデータはApps VMのpage cacheに溜まる (この間はWindowsに速度が表示される)。
2. Sambaがファイルをcloseすると、NFSクライアントが全データをflushしてCOMMITを送る。
3. pve1ではCOMMITがmergerfsのfsyncになり、ZFSのZIL書き込み待ちになる。
4. その間`nfsd`はFUSEへの書き込みで待たされ、SambaはWindowsへcloseを返せない。これが0に見える時間。

対処前にカーネルスタックを3回取り、3回とも同じだった。

```
mergerfs: cv_wait_common → zil_commit_impl → zfs_fsync → zpl_fsync → do_fsync
nfsd:     fuse_file_write_iter → vfs_iocb_iter_write → nfsd_vfs_write → nfsd4_write
```

## 併せて実施した2件の設定変更

**1. Apps VMの全NFS mountに`nconnect=8`** (PR #38)

`nconnect`はmount単位ではなくNFS client (server address + protocol + version) 単位で共有され、
最初にmountされたentryが接続数を決める。`shared`/`shared-hdd`/`archive`にだけ指定していたが、
起動時にsystemdが並列mountするため`nconnect`を持たないentryが先行し、実機では全mountが
1 transportになっていた。`192.168.10.11`への7 mount全てに同じ値を指定する。反映にはApps VMの
rebootが必要 ([NFS export契約](nfs-export.md#apps-vmのnconnect))。

**2. Apps VMの`vm.dirty_background_bytes=67108864`** (PR #39)

既定の`vm.dirty_background_ratio=10` (12GB VMで約1.2GB) では、数十〜数百MBのファイルは転送中に
background writebackが始まらない。64MiBに下げて転送中からpve1へ送るようにし、close時のflush量と
COMMITの負荷を下げる。5秒以上前に書かれたデータはZFS txgへ反映済みになるためfsyncも軽くなる。
hard limitはkernel既定値のままで、データ安全性のsemanticsは変更しない。

## 計測結果

いずれもコピー実行中に40秒間計測した。

| 指標 | 対処前 | SSD移設+TRIM後 | +nconnect+writeback後 |
| --- | --- | --- | --- |
| SSDの書き込みレイテンシ | 48ms | 5.2ms / 11ms | 2.5ms / 2.1ms |
| ZFS txgの同期時間 | 2.9〜5.9秒 | 0.04〜0.98秒 | 0.04秒以下 |
| NFS WRITE 1回 (1MB) のrtt | 約45ms | 約45ms | 11.1ms |
| NFS COMMITのrtt | 約1.4秒 | 約0.53秒 | 78ms |
| Apps VMの`Writeback`滞留 | 9〜12秒 | 最長約2秒 | 1秒以内 |
| NFS書き込みスループット | — | 約51MB/s | 約84MB/s |

ファイルサイズが計測ごとに異なるため、数字は目安である。1GbE上のSMBの実効上限は約110MB/sで、
84MB/sはその近くまで来ている。

## 確認方法

```bash
# pve1: TRIMが通っているか
zpool status -t cache-pool              # trim unsupported が出ないこと
cat /sys/block/sdX/queue/discard_max_bytes   # 0 以外

# pve1: SSDの書き込みレイテンシ (コピー中に40秒の差分を取る)
cat /sys/block/sdX/stat                 # 5列目=write ios, 8列目=write ticks(ms)

# pve1: txgの同期時間 (最終列がns)
tail -5 /proc/spl/kstat/zfs/cache-pool/txgs

# Apps VM: NFSのWRITE/COMMIT待ち時間 (差分を取る)
grep -A40 "192.168.10.11:/mnt/shared " /proc/self/mountstats

# Apps VM: nconnectの実効値 (各mountで 8 を期待)
awk '/^device 192.168.10.11/{d=$2} /xprt:/{c[d]++} END{for(k in c) print c[k], k}' /proc/self/mountstats

# Apps VM: writebackの設定値と挙動
cat /proc/sys/vm/dirty_background_bytes  # 67108864
grep -E '^(Dirty|Writeback):' /proc/meminfo  # 小さい値で推移すること
```

## 切り分けで白と判定したもの

- **Tailscale経由のヘアピン** (2026-07の原因): `--accept-routes`はfalseのままで、SMBの接続元も
  `192.168.20.104`の直通だった。
- **SSDの寿命**: Percentage Used Endurance Indicatorは7%と2%。
- **SSDのflush**: 1回あたり3ms前後で問題なし。遅いのは書き込みそのものだった。
- **mergerfsの`parallel-direct-writes`**: 2.40.2は対応しているが、並列化できるのはファイルサイズを
  伸ばさない書き込みだけである。今回のコピーは新規も上書きも末尾へ書き足すため効果がない。

## 残課題

- **NFSの`sync` export + mergerfsのfsync経路**: COMMITは78msまで下がったが、経路としては残っている。
  さらに詰めるなら`sync=disabled`やexportの`async`になるが、停電時に直近数秒の書き込みを失う。
  cache-poolはmover前の唯一のコピーを持つため、採用は要判断。
  2026-10-29に`shared`だけを`async`へ変更した。判断と計測は[2026-10の結論](#2026-10-小さめのファイルを大量に書くと速度が出ない)を参照する。
- **cache-pool 2台のレイテンシ差**: 計測ごとに差が出る。片方は稼働17,666時間の個体。

# 2026-10: 小さめのファイルを大量に書くと速度が出ない

mp3とflacが混ざった約200GB（1個3〜50MB）をSMBで`shared`へ書くと、
大きいファイルの連続書き込み（約84MB/s）ほどの速度が出なかった。2026-10-28〜29に経路の実装と段ごとの計測で調べた。

## 結論

**ファイルごとのNFS COMMITがmergerfsのfsyncを待ち、逐次コピーで待ち時間が積み重なっていた。**
2026-10-29 00:56（JST）、pve1で`/etc/exports`の`/mnt/shared`だけを手動で
`rw,sync,...,fsid=100`から`rw,async,no_subtree_check,no_root_squash,fsid=100`へ変更し、`exportfs -ra`で反映した。
バックアップは`/etc/exports.bak.20261029T005646`。`shared-hdd`（`/mnt/tank-gen2/data/shared`、`fsid=101`）と
ほかのexportは変更せず`sync`を維持した。現在の契約は[NFS export契約](nfs-export.md)を参照する。

`shared`の8MiB・40MiBの逐次コピーは改善した。300KiBは改善せず、async化だけで小さいファイル全般が速くなるわけではない。
大量のコピーには`robocopy /MT:8`も有効だった。

この変更では、**pve1の異常停止（電源断、カーネルpanic、ハードウェア故障）時に、クライアントへ完了と返した
直近の書き込みを失う危険**を受け入れる。未永続化の範囲はZFSのtxgの間隔に相当する数秒程度で、
`shared`への書き込みは主に元ファイルがPCに残るコピーである。後述のmergerfsの性質により、
1回のWRITEで済みCOMMITが起きない小さいファイルは、変更前もACK時点で永続化されていなかった。
UPS（CPJ1200）はあるが監視ソフトがなく、停電時の正常シャットダウンは
[issue #158](https://github.com/koji-genba/homelab/issues/158)で別に扱う。

## 待ちが積み重なる仕組み

1. Windowsがファイルのデータを書き、コピーの最後にmtimeを設定する。
2. Linux NFSクライアントは通常ファイルのSETATTR前とclose時に、未送信WRITEの完了と必要なCOMMITを待つ。
3. knfsdの`sync` exportではCOMMITが`vfs_fsync_range`になり、FUSEのFSYNC、mergerfsの実体ファイルのfsync、
   ZFSのZIL書き込みへ進む。
4. 逐次コピーでは、この待ちがファイルの数だけ直列に積み重なる。`async` exportではCOMMITで永続化を待たず応答できる。

COMMITは常に1ファイル1回ではない。mergerfs 2.40.2はWRITEの同期フラグ（FILE_SYNC）を下層へ伝えておらず、
今回の300KiBのように1回のWRITEで済みCOMMITが起きない場合は、`sync` exportでもACK時点の永続化を保証できていなかった。
COMMITからfsyncへ進む経路と、WRITEの同期フラグの扱いは区別する必要がある。

新規ファイルの書き込み先がHDDになっていたわけではない。mergerfs 2.40.2のcreate用`ff`はパスの存在を条件にせず、
先頭の書き込み可能で空き容量があるSSDを選ぶ。親ディレクトリがHDD側にしかなくてもSSD側へ親を複製して作成する。
既にHDDにある同名ファイルの更新は別である。

一方、ZFSを直接exportする`shared-hdd`では、OPENによる作成やSETATTRのたびに`zpl_commit_metadata`から
HDDのZIL書き込みを約12msずつ待つ。これが小さいファイルの低速につながる。
mergerfs側のメタデータ処理とは経路が異なるため、両shareの差をSSDとHDDの速度差だけで説明しない。

## 計測結果

Windows → SambaをLANのIPで接続し、1GbEで2026-10-29に計測した。
`sync` / `async`列は`File.Copy`による逐次コピーの全体スループットで、括弧内は1ファイルの所要時間の中央値。
`/MT:8`列はrobocopyによる並列コピーである。

| shared（新規ファイルはSSD） | sync | async | async + robocopy /MT:8 |
| --- | --- | --- | --- |
| 8MiB × 300 | 72MB/s（109ms/個） | 89MB/s（86ms/個） | 100MB/s |
| 40MiB × 50 | 76MB/s（539ms/個） | 99MB/s（424ms/個） | 106MB/s |
| 300KiB × 300 | 23MB/s（9.4ms/個） | 21MB/s | 29MB/s |

`sync`時のrobocopy `/MT:8`は8MiBで77MB/s、40MiBで88MB/sだった。
比較用の`shared-hdd`は`sync`のままで、逐次コピーは8MiBで約31MB/s、40MiBで約54MB/s、300KiBで約2.4MB/s。
2回の計測で同等だった。

### 01:06〜01:09 JSTの保守後の再計測

後述の3件の設定変更を反映後、同じくWindows → Samba、LANのIP、1GbEで計測した。
`shared`は`async`のまま、`shared-hdd`は`sync`のままである。
逐次コピー列の括弧内は1ファイルの所要時間の中央値。

| sharedのファイルサイズ | 変更前（asyncのみ）の逐次コピー | 変更後の逐次コピー | 変更前の /MT:8 | 変更後の /MT:8 |
| --- | --- | --- | --- | --- |
| 8MiB | 89MB/s（86ms/個） | 92MB/s（88ms/個） | 100MB/s | 102MB/s |
| 40MiB | 99MB/s（424ms/個） | 100MB/s（417ms/個） | 106MB/s | 109MB/s |
| 300KiB | 21MB/s | 24MB/s（9.4ms/個） | 29MB/s | 34MB/s |

| shared-hddのファイルサイズ | 変更前の逐次コピー（sync） | 変更後の逐次コピー（sync） |
| --- | --- | --- |
| 8MiB | 約31MB/s | 34MB/s |
| 40MiB | 約54MB/s | 56MB/s |
| 300KiB | 約2.4MB/s | 2.9MB/s |

各条件のスループットは数値上改善し、悪化は見られなかった。ただし改善幅は計測の揺らぎと同程度で、
この3件の設定変更の効果とは断定できない。全体スループットと1ファイルの中央値は別の指標である。

### pve1上の経路別計測（保守前）

Linux側はpython3の計測スクリプトで、段ごとに測った。次の表はpve1上でファイルごとにfsyncした場合の
**1ファイルの合計所要時間の中央値**であり、fsync呼び出しだけの時間ではない。

| pve1上の経路 | 8MiB | 40MiB | 300KiB |
| --- | --- | --- | --- |
| SSDのZFS直 | 24ms | 108ms | 4ms |
| HDDのZFS直 | 71ms | 335ms | 12ms |
| mergerfs | 28ms | 449ms | 4ms |

40MiBではmergerfs経由がSSD直の約4倍だった。8MiBではほぼ差がない。
`sync`時にApps VMからNFS経由で測った40MiBのCOMMITの平均RTTは、mergerfsで355ms、HDD直で244msだった
（明示fsyncなしの試験）。この平均RTTと、上表のファイルごとの中央値は別の指標である。

## 確認方法

- pve1の`exportfs -v`で、`/mnt/shared`だけが`async,fsid=100`、`shared-hdd`が`sync,fsid=101`であることを確認する。
- Apps VMの`/proc/self/mountstats`をコピー直前・直後に読み、対象mountのWRITE・COMMIT・OPEN・SETATTRの
  回数とRTTの差分を比較する。起動以来の累計値だけではコピー中の待ちを評価しない。
- 再計測時は同じサイズ・個数の新規ファイルを使い、LANのIPで逐次コピーとrobocopy `/MT:8`を分ける。
  ファイルの作成・削除を伴うため専用ディレクトリを使い、moverの実行時間を避ける。
- pve1ローカルのcloseだけでは永続化を待たない。段ごとの比較ではfsyncの有無を分け、
  ファイルごとの中央値とRPCの平均RTTを混同しない。

## 2026-10-29に併せて反映した設定変更

2026-10-29 01:06〜01:09（JST）の保守で、次の3件をpve1とApps VMへ反映した。
Apps VMの停止時間は約3分だった。

- **NFS向けの`noforget`**: [mergerfsのfstab手順](tiered-storage.md#etcfstabmergerfsマウント)に`noforget`を追加した。
  NFSのファイルハンドルの安定性のためで、pve1のfstabにも追加し、`/mnt/shared`をマウントし直した。
  mergerfsプロセスの引数に`noforget`があることと、markerを確認した。
- **Apps VMのNICの`queues`**: `files/infrastructure/terraform/apps-vm/main.tf`の1つ目の`network_device`に
  `queues = 4`を追加した。4 vCPUに合わせ、2026-07のmultiqueue=4という記録との食い違いを解消する。
  固定版bpg/proxmox 0.117.0の[公式資料](https://github.com/bpg/terraform-provider-proxmox/blob/v0.117.0/docs/resources/virtual_environment_vm.md)で対応を確認した。
  実機では`qm set`でnet0へTerraformの定義と同じ`queues=4`を設定し、起動後の`eth0`がrx/txとも4キューであることを確認した。
  `terraform plan`で差分が出ないことは未確認。
- **SambaのTCPバッファ**: `smb.conf`の`socket options`行を削除した。
  [公式資料](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html#SOCKETOPTIONS)が固定バッファによる
  自動調整の無効化を警告しているため、カーネルの自動調整に任せる。Sambaの既定は`TCP_NODELAY`。
  PR #159のマージ後、Appsのreconcileで反映し、`testparm`で既定値になったことを確認した。

保守はAppsのreconcile → Apps VMの停止 → pve1で`exportfs -u` → `umount` → fstabの変更 →
`mount` → `exportfs -ra` → `qm set` → Apps VMの起動の順で実施した。

**mergerfsをマウントし直す際の注意**: 今回はApps VMを停止して`exportfs -u`した後も、
`umount /mnt/shared`がbusyになった。`fuser`ではkernel mountだけが見え、ユーザー空間のプロセスは
掴んでいなかった。カーネルのNFS exportキャッシュがマウントを参照していたため、
`exportfs -u`の後に`exportfs -f`でキャッシュを破棄してから`umount`すると成功した。

## 残課題

- **mergerfsのfsync経路とFILE_SYNCの伝達**: `shared`を`async`にしたため、knfsdのCOMMITはfsyncを呼ばない。
  この2件は現在の`shared`の経路では、性能にも永続性の保証にも影響しない。
  `shared`を`sync`に戻す場合や、mergerfsを通る`sync` exportを新しく作る場合に改めて検討する。
