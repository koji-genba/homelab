# Hermes とのファイル受け渡し共有

2026-11-05 JST: issue #194 / PR #195 の共有を**実機反映済み**。
10:21にpve1、10:23にAgent/Runner、10:28にAppsへ反映し、main merge後の10:33〜10:35にreconcileを再開した。
export・mount・guard・隔離・Sambaを確認し、運用者がWindows・AndroidとHermesから共有を利用できた。
手順は再反映・復旧用に残し、各手順に今回の結果を記す。切り離し・撤去は今回の実施対象外。
残る確認は[未検証の項目](#未検証の項目)にまとめる。判断は [ADR-0014](../adr/0014-hermes-share-nfs.md)。

## 目的と消失許容

Windows・Android（SMB）と Hermes の間で大きなファイルを双方向に渡す。
`inbox/` はユーザーから Hermes へ、`outbox/` は Hermes からユーザーへ渡す約束で、権限の分離ではない。
双方が両方を読み書きできる。Hermes は inbox の原本を消さず、成果物を outbox に置く。

スナップショット・バックアップ・復元・自動削除は無い。唯一のコピーや機密を置かない。
共有の中身は Runner のコマンドや MEDIA により外へ出得る。skill の禁止指示だけでは強制できない。
DGX 用の [scratch](scratch-storage.md) とは別 dataset・別 export で、DGX には出さない。
mergerfs・mover・snapshot job の対象にも加えない。

## pve1 の契約

| 項目 | 値 |
| --- | --- |
| dataset / mountpoint | `tank-gen1/data/hermes` / `/mnt/tank-gen1/data/hermes`（継承） |
| property | `recordsize=1M,compression=lz4,atime=off,xattr=sa,quota=2T` |
| 同期と export 管理 | `sync=standard`（既定）、`sharenfs=off`。`/etc/exports` 管理 |
| 入口 | `root:10004 1775`（sticky） |
| inbox / outbox | 各 `10002:10004 2775`（setgid） |
| marker | `.homelab-export`、値 `hermes`（改行付き）、`root:root 0644` |
| README | `README-DISPOSABLE.txt`、日英、`root:root 0644` |
| client | Apps `.101/32`、Runner `.105/32` のみ |
| export option | `rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004`、`fsid` 無し |

root を含む全 NFS アクセスは `10002:10004` になる。入口の sticky は root 所有の marker と
README の削除を防ぐが、利用者同士を分離しない。`async` は応答済みデータの喪失も許容する設定。
`secure` は既定のまま維持し、非 root による高位送信元ポートからの直接 NFS を許可しない。
非特権の `hermes-runner` は kernel mount を通して利用する。

Runner の firewall を開ける**前に** ai の export を `.101/32`・`.51/32`・`.52/32` に絞る。
既存の `rw,sync,no_subtree_check,no_root_squash` は維持する。
2026-11-05 10:21に`/proc/fs/nfsd/clients`の相手が`.101`・`.104`・`.51`・`.52`だけと確認し、
aiのclientを上記3台へ絞った。反映後もAppsと両DGXのaiはnfs4のまま読み取れた。

quota は予約ではない。scratch の 3T と hermes の 2T は pool 容量を合計で超え得る。
`zpool list tank-gen1` と `zfs list -o name,used,avail,quota tank-gen1/data/hermes tank-gen1/data/scratch`
で pool 全体と両 dataset を見る。既存の import と scrub は維持する。

## Runner の mount とバックアップ

`nfs-common` を入れ、作業ディスクの下地 `/srv/agent-work/share` を `root:root 0555` で作る。
mount 済み・autofs 稼働中には下地の chmod/chown を行わず、server の入口権限を変更しない。

```fstab
192.168.10.11:/mnt/tank-gen1/data/hermes /srv/agent-work/share nfs4 hard,_netdev,nofail,nfsvers=4.1,noatime,rsize=1048576,wsize=1048576,timeo=600,retrans=2,nconnect=8,x-systemd.automount 0 0
```

Ansible は fstab を宣言して daemon-reload、生成された automount unit を start する。
fstab generator が boot 時の依存を作るため、生成 unit に `enable` は行わない。
firewall handler はアクセス前に flush する。`showmount` は使わず、marker の `cat` で
automount を発火させ、`findmnt -t nfs4 -M` の source・fstype と marker `hermes` を照合する。
check mode では接続検査を実行しない。
Runnerの`/srv/agent-work/share`やDGXの`/mnt/ai`・`/mnt/scratch`では、
`findmnt -M`がautofsとnfs4の2行を返す。接続先を確かめるときは`-t nfs4`を付ける。

export 未作成・アクセス拒否・marker 不一致は apply の失敗とし、skip やローカル書き込みへ逃がさない。
検査の Ansible 待機は async 120 秒 / poll 3 秒で制限する。初回 mount は systemd の mount timeout にも従う。
既に hard NFS の I/O に入って停止したプロセスは、この上限で確実に終了できるとは限らない。
`nofail` は boot の必須依存を外す設定であり、アクセス時の待機を防ぐものではない。
下地 0555 は通常の誤書き込み防止であり、親を所有する実行ユーザーに対する改ざん防止境界ではない。

Agent の `agent_ops_runner_excludes` は `./share`（末尾 slash 無し）を含める。
`tar -C /srv/agent-work ... .` の directory 自体を traversal 前に除外し、
`--one-file-system` も付ける。後者だけでは automount の stat を防ぐ保証がないため、明示除外が主になる。
共有をローカルへコピーした場合、そのコピーはこの除外の対象にはならない。

## Apps の mount と Samba

`nfs_mounts` の `hermes` は `/srv/homelab/nfs/hermes`、server `192.168.10.11`、
export `/mnt/tank-gen1/data/hermes`、marker `.homelab-export` / `hermes`。
options は scratch と同じ
`hard,_netdev,nfsvers=4.1,noatime,rsize=1048576,wsize=1048576,timeo=600,retrans=2,nconnect=8`。
cutover 有効時に storage role が `rw` を付ける。

`hermes_share_mount_path` → `HERMES_SHARE_MOUNT_PATH` → Samba `/mnt/hermes` の bind。
`[hermes]` は `valid users = @samba-users`、writable/browseable、create mask 0664、directory mask 0775。
comment は `Hermes exchange - inbox/outbox, no snapshots or backups`。
mask は許可する bit の上限であり、group write を強制する設定ではない。
Homepage に `\\samba.kojigenba-srv.com\hermes` のコピー用カードを置く。
Apps の他 container には共有を渡さない。

共通 mount guard が source・fstype・marker を確認するため、hermes の障害でも全 project の起動が止まり得る。
個別共有だけを起動対象から外す仕組みは追加しない。

## Hermes の契約と skill 配布

`files/services/agent/hermes/skills/hermes-share/SKILL.md` を配る。
Runner の terminal で mount と目印を確認し、inbox の原本を消さず、成果物を outbox へ置き、
`outbox/…` と `\\samba.kojigenba-srv.com\hermes\outbox\…` を案内する。
共有が空・目印無し・検査失敗なら書かずにユーザーへ知らせる。共有内容を外部サービスへアップロードしない。

`agent_stack/tasks/config.yml` は skills tree 全体を Agent の `/srv/agent/hermes/skills/` に再帰 copy し、
`force: false` で既存ファイルを保つ。新 directory と新ファイルは追加されるので、今回の新 skill も届く。
隔離した localhost の copy 試験でも、新 skill の追加と既存・改訂済み skill の保持を確認した。
既存 skill の改訂はこの copy では上書きされない。初回追加の changed は
`Recreate Hermes and the CDP tunnel` handler を通知し、play 終了時に両 container を force-recreate する。
main merge だけでは Agent に配られない。

小さいファイルは `MEDIA:/srv/agent-work/share/outbox/画像.png` も使える。
repo の session-key patch は取得時の session を保つ修正であり、path policy を拡張しない。
remote fetch は元パスと realpath の両方を denylist で検査する。NFS の通常ファイルは
client の共有パスのまま解決され、許可される。禁止先への symlink は拒否される。
既存 remote MEDIA fixture に inbox/outbox の成功と禁止 realpath の拒否を加えてローカル image で検査する。
strict mode、サイズ・配送先制限で失敗し得るため、大きいファイルは SMB パスを案内する。
実 NFS と Discord を通した配送の確認範囲は[未検証の項目](#未検証の項目)を参照。

## 反映の順番と確認（2026-11-05実施済み）

以下の順番で反映した。時刻はJST。確認手順と、今回確認した結果を区別して記す。

1. **pve1**: 既存 dataset/export/property と pool 状態を確認し、exports の控えを取る。
   ai の `/24` entry を下の 3 client の行へ**置換**する。追加して `/24` を残さない。

   ```exports
   /mnt/tank-gen3/data/ai 192.168.10.101/32(rw,sync,no_subtree_check,no_root_squash) 192.168.10.51/32(rw,sync,no_subtree_check,no_root_squash) 192.168.10.52/32(rw,sync,no_subtree_check,no_root_squash)
   ```

   初回作成時だけ以下を実施する。既存 dataset がある場合は再作成せず差分を照合する。

   ```sh
   zfs create -o recordsize=1M -o compression=lz4 -o atime=off -o xattr=sa -o sharenfs=off -o quota=2T tank-gen1/data/hermes
   chown root:10004 /mnt/tank-gen1/data/hermes
   chmod 1775 /mnt/tank-gen1/data/hermes
   mkdir /mnt/tank-gen1/data/hermes/inbox /mnt/tank-gen1/data/hermes/outbox
   chown 10002:10004 /mnt/tank-gen1/data/hermes/inbox /mnt/tank-gen1/data/hermes/outbox
   chmod 2775 /mnt/tank-gen1/data/hermes/inbox /mnt/tank-gen1/data/hermes/outbox
   printf '%s\n' hermes > /mnt/tank-gen1/data/hermes/.homelab-export
   cat > /mnt/tank-gen1/data/hermes/README-DISPOSABLE.txt <<'EOF'
   Hermes との受け渡し用。inbox はユーザーから Hermes へ、outbox は Hermes からユーザーへ。
   スナップショット・バックアップ無し。Hermes はインターネットに出られるので、ここに置いたものは外に出る可能性がある。
   唯一のコピーや機密を置かない。
   Hermes exchange: inbox is from the user to Hermes; outbox is from Hermes to the user.
   No snapshots or backups. Hermes can access the internet, so files placed here may leave the system.
   Do not store the only copy or confidential data here.
   EOF
   chown root:root /mnt/tank-gen1/data/hermes/.homelab-export /mnt/tank-gen1/data/hermes/README-DISPOSABLE.txt
   chmod 0644 /mnt/tank-gen1/data/hermes/.homelab-export /mnt/tank-gen1/data/hermes/README-DISPOSABLE.txt
   ```

   `/etc/exports` に次の新 entry を一度だけ追加し、`exportfs -ra` を実行する。

   ```exports
   /mnt/tank-gen1/data/hermes 192.168.10.101/32(rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004) 192.168.10.105/32(rw,async,no_subtree_check,all_squash,anonuid=10002,anongid=10004)
   ```

   `exportfs -v` で ai の `/24` が消えたこと、新共有の 2 client と `secure`、他 export が不変であることを確認する。
   Apps と両 DGX の既存 ai mount の source・marker `ai`・読み書きが継続することを確認する。

   **実施記録（2026-11-05 10:21）**: スクリプトで`/etc/exports`をバックアップし、
   ai行のclientだけを置換した（path・空白は維持）。上記property・継承mountpoint・権限でdatasetを作成し、
   markerとREADMEを配置、hermes行を追加して`exportfs -ra`を実行した。
   `exportfs -v`でaiの3 client、hermesの`.101`・`.105`と
   `async,no_subtree_check,anonuid=10002,anongid=10004,rw,root_squash,all_squash`を確認した。
   他exportは不変、全poolはhealthy。Appsの`/srv/homelab/nfs/ai`と両DGXの`/mnt/ai`は
   nfs4のまま読み取れた。
2. **Agent/Runner**: 会話を止められる時間に PR branch から `make ansible-apply-agent`。
   新 skill 配布で Hermes と CDP tunnel が再作成される。Runner の nftables は `.11:2049/tcp` のみ追加。
   `cat /srv/agent-work/share/.homelab-export` の後、`findmnt -rn -t nfs4 -M /srv/agent-work/share -o SOURCE,FSTYPE,OPTIONS`
   で契約を確認する。`sudo -u hermes-runner` で outbox に試験ファイルを作成・読取・削除し、
   pve1 で UID:GID を確認する。`.11:22`・`.11:111`・他 LAN への新規接続が拒否されることも確認する。
   backup の Runner tar に `share` とその中身が無いことを運用者が安全な復号環境で確かめる。
   Hermesのcontainerにはhealthcheckが無いため、状態は`running`で確認する。

   **実施記録（2026-11-05 10:23）**: PR branchからapplyし、Agentはok=87 changed=4、
   Runnerはok=57 changed=5、どちらもfailed=0。新skill配布でHermesとCDP tunnelを再作成した。
   Runnerのoutput chainは`lo`、`established,related`、
   `ip daddr 192.168.10.11 tcp dport 2049 accept`、LAN範囲への`ct state new reject`の4つだけだった。
   shareは`192.168.10.11:/mnt/tank-gen1/data/hermes`からnfs4・`vers=4.1,nconnect=8`で
   automountされ、markerを読めた。`hermes-runner`でinbox・outboxに書いて削除できた。
   pve1の22・111、Appsの445、Agentの22、DGXの8000への接続は拒否された。
   Agentのbackup除外設定に`./share`があることと、Hermesの`running`を確認した。
3. **Apps**: reconcile を pause して PR branch から `make ansible-apply`。
   `compose.env` の追加は全 project を再作成する。Apps checkout は apply 自体では更新されないので、
   checkout と branch 反映の扱いは [scratch の手順](scratch-storage.md) に従う。
   source・marker と `homelab-mount-guard` を確認する。

   **実施記録（2026-11-05 10:28）**: reconcileを止めて作業用pauseを作り、PR branchからapplyした。
   ok=108 changed=10 failed=0。`compose.env`変更で全projectを再作成した。
   hermesのnfs4・`rw,vers=4.1,nconnect=8`、marker、mount guard、`HERMES_SHARE_MOUNT_PATH`、
   全13コンテナとAdGuardのDNSを確認した。scratchも維持された。
4. **main merge**。ここで Compose 変更は本番 deploy 対象になる。pause を維持したまま merge する。

   **実施記録（2026-11-05）**: PR #195をmainへmergeした。
5. **Apps**: pause を外して reconcile。Samba の bind、healthy、`testparm -s` の `[hermes]`、
   匿名拒否と認証済みアクセス、Windows/Android の作成・読取・削除を確認する。

   **実施記録（2026-11-05 10:33〜10:35）**: pauseを外し、`/opt/homelab`をmainへfast-forwardした。
   `.env.example`変更で全projectを再作成した。Sambaのhealthy、
   `/srv/homelab/nfs/hermes` → `/mnt/hermes`のrw bind、`testparm -s`の`[hermes]`、
   匿名の一覧拒否を確認した。運用者はWindows・Androidから`\\samba.kojigenba-srv.com\hermes`を利用できた。
6. **Hermes**: 新 skill が読めること、inbox を原本削除無しで読めること、outbox に成果物を置けること、
   Windows から見えることを確認する。小さい MEDIA 添付も実際に試す。

   **実施記録（2026-11-05、運用者確認）**: Hermesから共有を利用できた。
   outboxに作ったdirectoryはpve1で`10002:10004`・`2775`となり、setgidの継承を確認した。
   使用量は9.25M / quota 2T。

## 障害時の切り離し

NFS 停止中は `ls`・`du`・再帰検索等を重ねない。hard I/O の待機は timeout や kill でも解消しないことがある。
まず pve1 の pool・dataset・nfsd と接続を復旧する。復旧できなければ Hermes の実行と SMB writer を止める。

Runner では使用プロセスを止めて `srv-agent\x2dwork-share.automount` と `.mount` を停止し、
fstab 宣言を外して daemon-reload する。通常 unmount が busy なら使用元を確認し、
lazy/force unmount で成功扱いにしない。下地を `root:root 0555` に保ち、skill の目印検査を無効にしない。
Runner の TCP 2049 例外も閉じる。repo 宣言を残すと次回 apply が戻すため、恒久切り離しは repo も揃える。

Apps は reconcile pause と全 project の停止後、hermes bind・Samba share・Homepage card・env・
`nfs_mounts` を揃えて外す。mount guard が参照したまま server export を先に消さない。
残りの mount guard と project 起動を確認して reconcile を再開する。

## 撤去

全 writer 停止 → Runner と Apps の client 宣言・mount を除去 → TCP 2049 例外と skill・関連設定を整理
→ pve1 の hermes export のみ除去・`exportfs -ra` の順。ai の client 絞り込みは維持する。
backup の `./share` 除外は残存するローカル受け渡しファイルを確認してから整理する。
dataset/data の削除は別の明示判断で行い、この手順だけで削除しない。
復旧時は中身を復元せず、dataset・権限・inbox/outbox・marker・README・export を作り直す。

## 未検証の項目

- Runner・Apps・pve1の再起動後の自動mountとguardの通過。
- 大きいファイルの転送速度。
- READMEとmarkerをSMB・Runnerから消そうとしたとき、stickyで削除が拒否されること。

従来の確認手順のうち、実NFSの障害時の待機・切り離し、backupがNFSへ入らないことと
本番Runner tarの内容検査、共有ファイルのDiscord MEDIA配送も今回の確認には含まれず、未検証のまま。
backupは`./share`の除外設定までを確認した。ローカルfixtureはこれらの実機受入を代替しない。
