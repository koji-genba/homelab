# SMB転送速度トラブルシューティング (2026-07)

WindowsクライアントからSamba (192.168.11.103) への転送が読み書きとも約50MB/sで頭打ちになった件の調査記録。

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
