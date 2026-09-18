# DGX Sparkストレージ運用

- 状態: 手順A（pve1）と手順B（Apps VM）は2026-09-19に反映・確認済み。手順C（DGX 2台）は未実施
- 設計判断: [ADR-0006](../adr/0006-ai-dataset-single-export.md)
- export契約: [NFS export契約](nfs-export.md#ai-dataset-exportadr-0006)
- 対象: DGX Spark 2台（4TB機 `192.168.10.51`、GE2 port 3 / 1TB機 `192.168.10.52`、GE2 port 4）

DGX Spark 2台から使うモデルと学習データ（tar.gz）の置き場を、`tank-gen2/data/ai`の単一NFS export
として用意する。read-only exportもclientごとの分割も行わず、Apps VMとDGX 2台が同じ条件でmountする。

## 前提

- 全区間1GbE、実効110MB/s。20GBのモデルで約3分、500GBで約75分かかる
- `tank-gen2`はHDD 2本mirrorで空き9.0TB。10GbE化はNICに加えswitchが必要なため今回は行わない
- IX2215のACL変更は不要。DGXはServer VLAN 10で、Server内は同一trust boundaryとして扱う
  （[ADR-0003](../adr/0003-four-network-zones.md)）
- Port 3/4はすでにVLAN 10 accessであり、`config.txt`の変更も不要

## 手順A: pve1（`192.168.10.11`、rootで実行）

変更前の状態を保存してから、datasetとexportを作る。

```sh
cp -a /etc/exports /etc/exports.bak.$(date +%F)
exportfs -v > /root/exportfs-before-$(date +%F).txt

zfs create -o recordsize=1M tank-gen2/data/ai
mkdir -p /mnt/tank-gen2/data/ai/models /mnt/tank-gen2/data/ai/datasets
chmod -R 0777 /mnt/tank-gen2/data/ai

# marker本体は0644のままにして、非rootから上書きされないようにする
printf 'ai\n' > /mnt/tank-gen2/data/ai/.homelab-export

cat >> /etc/exports <<'EOF'
/mnt/tank-gen2/data/ai           192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

exportfs -ra
exportfs -v | grep -F /mnt/tank-gen2/data/ai
```

`fsid`は指定しない。明示が要るのはFUSEの`/mnt/shared`と、それとinode空間を共有する
`tank-gen2/data/shared`だけである。

確認：

```sh
zfs get -o property,value recordsize,atime,compression tank-gen2/data/ai
# recordsize=1M / atime=off / compression=lz4 を期待する
ls -la /mnt/tank-gen2/data/ai
cat /mnt/tank-gen2/data/ai/.homelab-export   # -> ai
```

`tank-gen2/data/ai`はsnapshot対象に含めない。`mover.sh`は`tank-gen2/data/shared`だけを見るため、
追加設定は不要である。

## 手順B: Apps VM（管理端末から）

repo側（`nfs_mounts`、`compose.env`、Samba `[ai]`）は反映済みなので、通常のAnsible適用でよい。

**前提: 管理端末でssh-agentとage鍵の両方を用意する。** toolboxはprivate keyもage鍵も
image内に持たず、対応する環境変数があるときだけmountする設計である（Makefileの
`TOOLBOX_SSH_MOUNT`と`TOOLBOX_AGE_MOUNT`）。片方でも欠けると、containerには鍵が無い状態で
playbookが走る。

| 欠けているもの | 失敗する場所 |
| --- | --- |
| `SSH_AUTH_SOCK`（ssh-agent未起動） | `Gathering Facts`で`Permission denied (publickey)` → `UNREACHABLE` |
| `AGE_IDENTITY_FILE` | `secrets : Decrypt runtime secrets on the controller only`で`non-zero return code`（`no_log: true`のため原因が表示されない） |

```sh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
export AGE_IDENTITY_FILE="$HOME/.config/sops/age/keys.txt"

ssh-add -l                          # 鍵が載っていることを確認する
make ansible-check && make ansible-apply
```

どちらもそのshellの間だけ有効である。`docker run`の引数に`-v "...:/run/ssh-agent"`と
`-v "...:/run/secrets/age-identity:ro"`の両方が含まれているかで、渡っているかを目視確認できる。
secretsロールは`no_log: true`で原因を隠すため、この段で落ちたらまず環境変数を疑う。

`nconnect`はserverごとに固定されるため、既存7 mountがすでに`nconnect=8`である以上、`ai`を
追加するだけならrebootは不要である。適用後に確認する。

```sh
ssh deploy@192.168.10.101 'findmnt /srv/homelab/nfs/ai; cat /srv/homelab/nfs/ai/.homelab-export'
ssh deploy@192.168.10.101 "awk '/^device 192.168.10.11/{d=\$2} /xprt:/{c[d]++} END{for(k in c) print c[k], k}' /proc/self/mountstats"
```

mount guardは source / fstype=nfs4 / `rw` / marker内容 の4点を見る。ここで落ちるとComposeが
起動しないので、Samba再起動の前に必ず通しておく。

SMB側の確認：

```sh
smbclient -L //192.168.10.101 -U koji-genba    # [ai] が見えること
```

## 手順C: DGX Spark 2台（4TB機・1TB機とも同じ）

```sh
sudo mkdir -p /mnt/ai
sudo tee -a /etc/fstab <<'EOF'
192.168.10.11:/mnt/tank-gen2/data/ai  /mnt/ai  nfs4  hard,_netdev,nfsvers=4.1,noatime,rsize=1048576,wsize=1048576,timeo=600,retrans=2,nconnect=8,x-systemd.automount  0  0
EOF
sudo systemctl daemon-reload
ls /mnt/ai        # automountがここで張られる
```

`x-systemd.automount`は`hard` mountを維持したままアクセス時にだけmountする。pve1を止めても、
NFSを触っていないジョブは巻き込まれない。

確認：

```sh
findmnt /mnt/ai
cat /mnt/ai/.homelab-export                        # -> ai
touch /mnt/ai/.write-test-$(hostname) && rm /mnt/ai/.write-test-$(hostname)
dd if=/mnt/ai/models/<任意のファイル> of=/dev/null bs=1M status=progress   # 約110MB/s
```

## 運用ルール

1GbEが前提なので、次の3点を守る。守らないと転送量ではなくメタデータ往復で潰れる。

- **tar.gzはNFS上で展開しない。** ローカルNVMeへコピーしてから`tar xf`する。NFS上で数万の
  小ファイルを作ると1GbEでは実用にならない
- **`HF_HOME` / `HF_HUB_CACHE`をNFSへ置かない。** symlinkとlockの塊でNFSと相性が悪い。
  `/mnt/ai`は「curateされた置き場」、HFキャッシュはDGXローカル、と役割を分ける
- **2台分のstagingをNFSから二重に引かない。** 4TB機へ展開し、1TB機はDGX間のQSFP直結経路から
  読む。両方が1GbEでpve1を叩くより桁で速い

モデルは1回のシーケンシャル読みなのでNFS直読みでよい。何度も読むもの（学習データ、DataLoader）
とcheckpoint書き込みはローカルNVMeを使う。

## ディレクトリ

```
/mnt/ai/
├── models      # モデル本体
└── datasets    # 学習データ（tar.gz）
```

単一exportなので、ここから先の構造は運用で自由に決めてよい。infrastructure側の設定は増えない。

## 手動反映の記録

| 項目 | 値 |
| --- | --- |
| 手順A実施日 / 操作者 | 2026-09-19 / ユーザー |
| 変更前 `exportfs -v` | `/root/exportfs-before-2026-09-19.txt`（pve1、Git管理外） |
| `/etc/exports` バックアップ | `/etc/exports.bak.2026-09-19`（pve1、Git管理外） |
| 変更後 `exportfs -v` | `/mnt/tank-gen2/data/ai` が `192.168.10.0/24(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash)` で公開されていることを確認 |
| dataset property | `recordsize=1M` / `atime=off` / `compression=lz4` を確認 |
| owner / mode / marker | `root:root`、`0777`、`models`と`datasets`を作成。marker内容`ai`を確認 |
| Apps VM mount / marker確認 | 2026-09-19に`/srv/homelab/nfs/ai`が`nfs4,rw,nconnect=8`でmountされ、marker内容`ai`、`homelab-mount-guard.service`が`active`であることを確認 |
| Apps VM Compose反映 | 2026-09-19に完了。PR [#43](https://github.com/koji-genba/homelab/pull/43)（merge commit `a5c2e3e`）のmerge後、`homelab-app-reconcile.service`でVM側cloneを`a5c2e3e`へ更新。Sambaが再作成され`healthy`、bind `/srv/homelab/nfs/ai -> /mnt/ai`、`smbclient -L`に`ai`が出ることを確認 |
| SMB書き込み確認 | 2026-09-19。container内でsamba uid（`10002:10004`）として`/mnt/ai/models`へ作成・削除が通り、所有者が`koji-genba:samba-users`になることを確認 |
| DGX 4TB機 mount確認 | 未実施（ユーザーが実施予定） |
| DGX 1TB機 mount確認 | 未実施（ユーザーが実施予定） |
| 実測read速度 | 未測定 |
| 対応commit | `a5c2e3e`（PR #43）。手順Cの結果はこの表へ追記する |

## 切り戻し

exportを外すだけで元に戻る。datasetを消す場合は中身の確認を先に行う。

```sh
# pve1
cp -a /etc/exports.bak.<date> /etc/exports
exportfs -ra && exportfs -v
```

Apps VM側は`nfs_mounts`から`ai`エントリを、Sambaから`[ai]`を外して`make ansible-apply`する。
DGX側は`/etc/fstab`の行を消して`systemctl daemon-reload`、`umount /mnt/ai`する。
