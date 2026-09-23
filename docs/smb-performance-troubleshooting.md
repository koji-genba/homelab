# SMB転送速度トラブルシューティング

WindowsクライアントからSambaへの転送が遅い件の調査記録。現時点で2件ある。

| 時期 | 症状 | 原因 |
| --- | --- | --- |
| 2026-07 | 読み書きとも約50MB/sで頭打ち | Tailscale subnet routeによるヘアピン |
| 2026-09 | 速度が出たり0になったりを繰り返す | cache-pool SSDにTRIMが通っていなかった |

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
- Tailscale経由か直通かは、サーバー側から見た接続元IPで即判別できる(gateway経由だと192.168.10.30にSNATされる)。

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
rebootが必要 ([NFS export契約](operations/nfs-export.md#apps-vmのnconnect))。

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
- **cache-pool 2台のレイテンシ差**: 計測ごとに差が出る。片方は稼働17,666時間の個体。
