# Phase 2A 事前調査結果

- 調査日: 2026-09-05
- 対象: `origin/main` `371fc31`、Kubernetes cluster、pve1（NFS/ZFS）、IX2215、Tailscale tailnet
- 方法: Kubernetes APIの読み取り、`root@192.168.10.11`と`deploy@192.168.10.42`への読み取り専用SSH、
  公開registryのmanifest照会、ユーザーが取得したIX2215コンソール出力とTailscale管理コンソールのexport
- 変更: **実機・クラスタ・ネットワーク機器への変更は一切行っていない**

この文書はPhase 2Bのcutover判断に使う実測値を日付付きで固定する。
[作業指示](next-session.md)の「Phase 2A: 読み取り専用の事前調査」に対応する。

## 1. Git基準

| 項目 | 実測値 |
| --- | --- |
| cutover候補commit | `origin/main` = `371fc31`（PR #18 merge） |
| Fluxが適用中のrevision | `main@sha1:371fc314b793bd9940b6699e796239fa263bb07b`（一致） |
| main最新commitのCI | `Validate infrastructure and applications` = success |
| 未commit差分 | 保護対象2ファイルのみ。stageしていない |
| branch乖離 | `k8s-decommission`は`origin/main`の祖先。乖離なし |

7 Compose projectのimageはすべて`@sha256:`固定で、tag参照は0件だった。7 digestすべてを匿名で
公開manifest照会し、`Docker-Content-Digest`が宣言値と一致した。toolbox 1.0.1のdigest
`sha256:7607f2c7...067dad0`も実在を確認した。

未解決の記録として、1つ前のcommit時点でDependabotスキャンjobが6 projectで失敗している。
コード検証ワークフローとは別系統であり、cutoverの停止条件ではないが原因は未調査である。

### 1.1 Kubernetes稼働中imageとCompose宣言digestの一致

cutover前後でapplicationのバージョンが変わると、stashPadのSQLite databaseが一方向にschema
migrationされてrollback不能になりうる。そこでKubernetes Podの`imageID`とCompose宣言digestを
突き合わせた。**4用途すべてbyte単位で一致した**。

| 用途 | Kubernetes稼働中の`imageID` | Compose宣言 | 判定 |
| --- | --- | --- | --- |
| stashPad prod | `stashpad@sha256:b2218a61...cf8c0a33f1` | 同一 | 一致 |
| stashPad staging | `stashpad@sha256:87c7f28b...e99e87ad5e` | 同一 | 一致 |
| Samba | `samba@sha256:72441fe9...95601dbb5b` | 同一 | 一致 |
| SillyTavern | `sillytavern@sha256:7b30a169...98065dcedd3` | 同一 | 一致 |

Kubernetes側はprodが`:edge`、stagingが`:main-50-7585c86`というtag参照でdeployされているが、
実際にpullされているdigestはCompose宣言と同一である。したがって**cutoverの瞬間にimageは変わらず、
schema migrationによるrollback不能リスクはこの4用途については存在しない**。

なおprodのbuildは2026-07-06、stagingは2026-07-12で約6日差があるが、これは各環境が独立して
Kubernetes/Compose間で一致しているだけであり、cutoverが引き起こす差ではない。
floating tagの`:edge`はprodが現在稼働させているdigestより先へ進んでいるが、prodはKubernetes側も
Compose側も固定digestを参照しているため影響しない。

## 2. 現行writerとservice ownership

### 2.1 NFS clientとopen writer

NFS server側`/proc/fs/nfsd/clients/`の実測で、clientは既知の3ホストのみだった。**未知のclientは0件**である。

| client | 種別 | open state |
| --- | --- | --- |
| `192.168.10.22`（k8s-worker01） | NFSv4.2 / v4.1 | stashPad staging DBに対しopen(rw)+write delegation |
| `192.168.10.23`（k8s-worker02） | NFSv4.2 / v4.1 | stashPad prod DBに対しopen(rw)+write delegation |
| `192.168.10.42`（Apps VM） | NFSv4.1 | **0件。writerなし** |

`192.168.10.21`（k8s-master01）からのNFS接続はなかった。

書き込みopenとして観測されたのは次の2つだけである。いずれもSQLite WALのopenパターンで、
`stashpad.db`、`stashpad.db-wal`、`stashpad.db-shm`の3ファイルにwrite delegationを保持していた。

- k8s-worker02 → `k8s-volumes/stashpad-prod-stashpad-data-pvc-c96b1813-.../stashpad.db*`
- k8s-worker01 → `k8s-volumes/stashpad-staging-stashpad-data-pvc-ecc8b17c-.../stashpad.db*`

両workerから`rpz/hagezi-pro.txt`への読み取りopenも多数観測された。これは後述のblocklist PVCの
更新で同名ファイルが繰り返し置換され、旧inodeへのfdが残っているパターンである。

### 2.2 NFS pathとwriterの対応表

移行文書が管理する7 pathに加え、**文書に記載のないpathが8件**存在した。writerは全件特定でき、
**不明なwriterは0件**である。

| # | path | writer | 状態 |
| --- | --- | --- | --- |
| 1 | `/mnt/shared` | samba Deployment（rw）、および後述の`mover.sh` | 管理対象 |
| 2 | `/mnt/tank-gen2/data/shared` | samba Deployment（rw）、`mover.sh` | 管理対象 |
| 3 | `/mnt/tank-gen1/data/archive` | samba Deployment（rw） | 管理対象 |
| 4 | `/mnt/shared/koji-genba/stashPadLib` | samba Deployment（`/mnt/shared`のrw mount経由）。stashPad prod/stagingは`/media`に`readOnly=true`でmountしており書き込まない | 管理対象 |
| 5 | `k8s-volumes/sillytavern-...85f01a24` | sillytavern Deployment（rw） | 管理対象 |
| 6 | `k8s-volumes/stashpad-prod-...c96b1813` | stashpad-prod Deployment（rw） | 管理対象 |
| 7 | `k8s-volumes/stashpad-staging-...ecc8b17c` | stashpad-staging Deployment（rw） | 管理対象 |
| 8 | `k8s-volumes/external-dns-blocklist-data-pvc-8e7db6e1-...` | external-unbound Deployment（rw）と blocklist-updater CronJob（rw）の2系統 | **未記録・現行アクティブ** |
| 9-11 | `k8s-volumes/openldap-openldap-data-pvc-*`（3世代） | なし（LDAP workloadはcluster上に存在しない） | **未記録・orphan** |
| 12-13 | `k8s-volumes/external-dns-blocklist-data-pvc-91ee1614/4058f1c6` | なし | **未記録・orphan** |
| 14-15 | `k8s-volumes/stashpad-prod-...8e5b6421`、`stashpad-staging-...b53534da` | なし | **未記録・orphan（PVC再作成時のリーク）** |

#8のblocklist PVCはAdGuard Home移行後は不要である。AdGuard HomeはHaGeZi listをCDNから直接取得する
設計であり、Apps VMの`nfs_mounts`にもこのpathは含まれていない。**移行不要だが、cutover時に確実に
writerを止める対象**として扱う。

#9〜15の7 directoryはwriterが存在しないorphanである。**Phase 2Bでは一切削除せず**、
k8s-volumes datasetのsnapshotで保全し、削除判断はPhase 5の「旧PVC data削除」で行う。

### 2.3 Kubernetes以外のwriter: `mover.sh`

`/mnt/shared`はmergerfsであり、`/etc/fstab`は次のとおりである。

```
/mnt/cache-sata:/mnt/tank-gen2/data/shared  /mnt/shared  fuse.mergerfs
  defaults,cache.files=off,dropcacheonclose=false,category.create=ff,inodecalc=path-hash,func.getattr=newest
```

`category.create=ff`により、**`/mnt/shared`への新規書き込みは先頭branchのcache側
（`cache-pool`、`/mnt/cache-sata`）に着地する**。pve1のroot crontabには
`0 5 * * * /usr/local/bin/mover.sh`があり、cache→`tank-gen2/data/shared`へrsyncで移動した後、
`tank-gen2/data/shared`のみにdaily/weekly/monthlyのZFS snapshotを作成して世代超過分をdestroyする。

これはKubernetesとは独立した第3のwriterであり、cutover計画に必ず織り込む必要がある。

### 2.4 service IP所有権

| IP | 所有Service | namespace |
| --- | --- | --- |
| `192.168.11.100` | `ingress-nginx-controller` | ingress-nginx |
| `192.168.11.101` | `external-unbound-dns` | external-dns |
| `192.168.11.103` | `samba-smb` | samba |

3つとも MetalLB `IPAddressPool/homelab-pool`（`192.168.11.100-192.168.11.200`、`autoAssign: true`、
`avoidBuggyIPs: true`）から払い出され、`L2Advertisement/homelab-l2-adv`のL2モードで広告している。
BGPは未使用である。speaker logの実測では、**3つとも k8s-worker01 が announce している**。
`192.168.11.102`（旧LDAPS想定）を使うServiceは存在しない。

### 2.5 Flux管理範囲（手順書の前提と異なる点）

Fluxが管理しているのは次の3 Kustomizationだけである。

| Kustomization | path |
| --- | --- |
| `stashpad-prod` | `manifests/applications/stashpad/overlays/prod` |
| `stashpad-staging` | `manifests/applications/stashpad/overlays/staging` |
| `sillytavern` | `manifests/applications/sillytavern/overlays/prod` |

`samba`、`external-unbound`、`metallb`、`ingress-nginx`、`cert-manager`は`flux-system/kustomization.yaml`に
resourceとして含まれておらず、**Flux管理外**である（metallbにはHelm CLIによる直接installの痕跡がある）。
HelmRelease/HelmRepositoryはcluster上に0件だった。

したがって「Flux reconciliationをsuspendする」だけではSambaとUnboundは停止しない。逆に、
これらにはFluxによる再生成リスクもないため、直接`kubectl scale`で停止する。

### 2.6 既知の異常

- `external-dns/external-unbound`の新ReplicaSet Podが`/shared/rpz/hagezi-tif.txt`のRPZ構文エラーで
  CrashLoopBackOff（RestartCount 177）。**旧ReplicaSet Podが54日間稼働し続けているだけでDNSが成立している**。
  この旧Podが落ちると内部DNSが停止する。
- `blocklist-updater` CronJobは上記が原因で直近3 Jobが連続Failed。blocklist更新は3日以上停止している。
- rollback時にUnboundを`replicas=1`へ戻すと、**新Podは同じ理由で再度CrashLoopする**。
  rollbackでDNSを復旧する場合は、NFS server上で
  `k8s-volumes/external-dns-blocklist-data-pvc-8e7db6e1-.../rpz/hagezi-tif.txt`を退避してから
  scaleする。この修正はcutover前には行わない（本番DNSを提供している旧Podを巻き込まないため）。

## 3. networkの事前条件

### 3.1 IX2215の実測（2026-09-05取得）

| 項目 | live実測値 |
| --- | --- |
| BVI11 アドレス | **`192.168.11.1/25`** |
| routing table | `C 192.168.11.0/25 ... BVI11` |
| `server_app-dhcp` | `assignable-range 192.168.11.100 192.168.11.200`、`subnet-mask 255.255.255.0` |
| BVI11 の filter | `ip filter server_app-out 10 in` |
| ACL | `server_app-out`は`192.168.11.0/25`基準 |
| `server_app-dhcp`のlease | **0 clients** |
| router全体のlease | 8件（`main-dhcp`/VLAN 20が7件、`guest-dhcp`/VLAN 40が1件）。VLAN 10の`server-dhcp`も0件 |

repositoryの`config.txt`（commit済みの内容）はliveと一致して`/25`である。作業ツリーにある未commit編集は
`/25`→`/24`への変更であり、**liveの現状ではなく将来の期待値**である。この編集はユーザー管理であり、
本作業では触らない。

### 3.2 判明した不整合（記録のみ、本フェーズでは修正しない）

1. **DHCP poolがBVI11のsubnetを超えている**。`/25`（`.0-.127`）に対しpoolは`.100-.200`で、
   `.128-.200`はinterfaceのsubnet外である。配布するsubnet-maskも`255.255.255.0`でBVI11と不一致である。
2. **MetalLB poolもsubnetを超えている**。`homelab-pool`は`.100-.200`で、`.128`以降が払い出されると
   router側から到達できない。現在の割り当ては3つとも`/25`内なので実害は出ていない。
3. **Apps VMのlegacy addressは`/24`で定義されている**（`192.168.11.100/24`など）。BVI11が`/25`のため
   mask不一致が残るが、3つのservice IPは`/25`内であり、通信相手もrouterとVLAN 11内hostだけなので
   cutover自体は成立する。
4. `vmbr0.11`は`192.18.11.11/24`（`192.168`ではない）だった。文書上の懸念どおりの実機設定である。

### 3.3 DHCP重複と除外方針（確定）

`.11.100/.101/.103`はDHCP poolと完全に重複しているが、**`server_app-dhcp`のleaseは0件**だった
（`show ip dhcp lease`の8件はすべてVLAN 20とVLAN 40）。VLAN 11上のhostはKubernetes nodeの
静的アドレスとMetalLBのVIPだけで、DHCPを使っているclientは存在しない。

したがって方針を次に確定する。

**cutover windowで`interface BVI11`の`ip dhcp binding server_app-dhcp`を外し、VLAN 11のDHCPを停止する。**

```
configure
interface BVI11
  no ip dhcp binding server_app-dhcp
```

- 影響を受けるclientは0件である。
- service IPとの重複を恒久的に解消できる。
- 同時に、pool `.100-.200`がBVI11の`/25`を超えている既存の不整合も無効化される。
- rollbackは`ip dhcp binding server_app-dhcp`を再投入するだけである。
- `ip dhcp profile server_app-dhcp`自体は削除しない。profileを残しておけばrollbackが1行で済む。

範囲を`.110-.127`へ狭める代替案は採らない。lease 0件であればbindingごと外すほうが、
残った範囲から将来誤って払い出される余地をなくせる。

### 3.4 ARPの実測と検証手段

IX2215の`show arp entry`（2026-09-05取得）でBVI11のentryは3件だった。

| protocol address | hardware address | 解釈 |
| --- | --- | --- |
| `192.168.11.22` | `bc:24:11:81:29:f2` | k8s-worker01のVLAN 11 interface |
| `192.168.11.101` | `bc:24:11:81:29:f2` | **同一MAC。MetalLBがworker01からL2広告している** |
| `192.168.11.103` | `bc:24:11:81:29:f2` | 同上 |

MetalLB speaker logの実測（3つともworker01がannounce）とrouter側のARPが一致した。

**`192.168.11.100`はARP cacheに存在しなかった。** ARP entryのTTLは5分程度で、`.11.101`（DNS）と
`.11.103`（SMB）は継続的に使われている一方、`.11.100`（HTTP/HTTPS）へのrouter経由の通信が
直近になかったためと考えられる。したがって`.11.100`については「ARP entryが無いこと」だけでは
fencingの証拠にならない。**能動的なpingで応答が消えたことを確認する**必要がある。

`vmbr0.11`が`192.18.11.11/24`であるため、**pve1からは`192.168.11.0/24`のARPを観測できない**
（`ip neigh`にも該当entryは0件）。ARP確認は次の3経路で行う。

1. IX2215から`ping 192.168.11.100 / .101 / .103`。**fencing前に応答することを記録し（baseline）**、
   fencing後に無応答になることを確認する。
2. IX2215の`show arp entry`でBVI11のentryが`.11.22`だけになること（TTL経過を待つ）。
3. Apps VMの`homelab-service-addresses`が各IPに対して実行する`arping -D -I ens19 -c 2 -w 3`。
   重複が残っていればunitがfailし、**アドレスは付与されない**（fail-closed）。これが最終gateである。

### 3.5 VLAN 10上の未同定host

`show arp entry`のBVI10に`192.168.10.51`（`fc:9d:05:13:d3:a4`）があった。Proxmox VMのMAC
（`bc:24:11:*`）ではなく物理機器と見られるが、実機インベントリに記載がない。NFS clientではないため
writerではなく、今回のcutoverには影響しない。ECW5211の管理interfaceである可能性があり、
Phase 4のAP調査で同定する。

### 3.6 ECW5211

ユーザー判断によりPhase 4へ延期する。今回のcutoverはVLAN 11のままapplicationだけを切り替えるため、
AP設定は変更対象外である。**未取得・Phase 4の前提条件**として記録する。

## 4. Tailscale live exportとTerraform宣言の差分

live export（2026-09-05取得）とTerraform宣言の対応は次のとおりである。

| 項目 | live | Terraform宣言 | 判定 |
| --- | --- | --- | --- |
| global nameserver | **`192.168.11.101`** | `tailscale_dns_nameservers.adguard` = `var.final_apps_ip`（`192.168.10.101`固定） | **不一致。現状applyするとtailnet全体のDNSが解決不能になる** |
| MagicDNS | 有効 | `tailscale_dns_preferences.magic_dns = true` | 一致 |
| subnet routes | 承認済み`192.168.10.0/24`、`192.168.11.0/24` | `advertised_routes`に両方を含む | 一致 |
| exit node | `home-gateway`で有効 | `advertised_routes`に`0.0.0.0/0`、`::/0` | 一致 |
| device tag | `home-gateway`は無タグ | `subnet_router_tags = []`（無タグ維持） | 一致 |
| 対象device | `home-gateway` | `subnet_router_hostname = "home-gateway"` | 一致 |
| ACL | 全許可（`src:*` → `dst:*:*`）、管理者1名のgroup、SSH check rule、参照先のない`192.168.1.0/24`→`192.168.0.0/24` ruleが残存 | `acl = file(var.acl_policy_file)`。Git上にpolicy実体はなくimport前提 | **Terraform側に実体なし。live exportをファイル化するまでapply不可** |

結論として、`manage_tailnet=false`を維持する。global nameserverの差分はPhase 4で
`.10.101`へ移す前提の宣言であり、application cutover（VLAN 11のまま）とは混ぜない。

**cutover windowへの影響**: tailnet全deviceのDNSは`192.168.11.101`に依存している。Unbound停止から
AdGuard Home起動までの間、**Tailscale経由のクライアントは名前解決ができない**。したがって、

- 窓中の作業はFQDNではなくIPで行う（PVE console `https://192.168.10.11:8006`、SSHは`192.168.10.x`直指定）
- 作業者はLAN側から実施し、Tailscale経由の名前解決に依存しない
- LAN clientはDHCPで`1.1.1.1`/`8.8.8.8`を配布されているため影響は限定的だが、内部FQDNは`.11.101`依存である

なお`macbook-air`のkey expiryが2026-09-13であり、窓の設定によっては再認証が必要になる。

## 5. snapshot計画

`tank-gen2/data/shared`のみ26 snapshot（`mover.sh`によるdaily/weekly/monthly）が存在し、
`tank-gen1/data/archive`と`tank-gen2/data/k8s-volumes`は**snapshot 0件**である。
`sanoid`/`zfs-auto-snapshot`/`znapzend`はいずれも未インストールで、snapshot関連timerもない。

さらに、mergerfsのcache branchである`cache-pool`にもsnapshotがない。**`/mnt/shared`への直近の
書き込みはcache側にあるため、HDD側datasetのsnapshotだけでは保護できない**。

対象は4 datasetとする。snapshot名はwindow当日の日付で統一する。

| dataset | 現在のsnapshot | 対象とする理由 |
| --- | --- | --- |
| `tank-gen2/data/k8s-volumes` | 0件 | stashPad prod/staging、SillyTavernの実データ。巻き戻し手段が皆無 |
| `tank-gen1/data/archive` | 0件 | Samba archive。巻き戻し手段が皆無 |
| `tank-gen2/data/shared` | 26件 | Samba shared HDD側とstashPad media |
| `cache-pool` | 0件 | **mergerfsのcache branch。直近の書き込みはここにある** |

```sh
# 取得（writer停止確認後、Apps VMをwriterにする前）
zfs snapshot tank-gen2/data/k8s-volumes@pre-compose-cutover-YYYYMMDD
zfs snapshot tank-gen1/data/archive@pre-compose-cutover-YYYYMMDD
zfs snapshot tank-gen2/data/shared@pre-compose-cutover-YYYYMMDD
zfs snapshot cache-pool@pre-compose-cutover-YYYYMMDD

# 存在確認（4件そろうこと）
zfs list -t snapshot -o name,creation | grep pre-compose-cutover-YYYYMMDD
```

巻き戻し方法は dataset ごとに変える。

- `tank-gen2/data/k8s-volumes`（358 MiB、他のsnapshotなし）: `zfs rollback`が現実的である。
- `tank-gen1/data/archive`、`tank-gen2/data/shared`、`cache-pool`: `zfs rollback`は使わない。
  `shared`をrollbackするとcutover後に`mover.sh`が作ったsnapshotが破棄される。必要なら`zfs clone`して
  ファイル単位で復元する。

### `mover.sh`の扱い

`mover.sh`は05:00に起動し、cache→HDDの移動とsnapshot作成・世代destroyを行う。窓中に走ると
snapshotの時点がずれる。

- **推奨**: メンテナンス窓を05:00をまたがない時間帯に設定する。実機変更が不要で最も安全である。
- 代替: crontab行を一時的に無効化し、窓終了後に復旧する。復旧忘れが事故になるため推奨しない。

cutover後も`mover.sh`はそのまま運用を継続する。Compose移行とは独立した storage tiering である。

## 6. final syncは不要

Apps VMの`nfs_mounts`は、Kubernetes PVが参照しているのと**同一のNFS server・同一のexport path**を
mountする。データのコピーは発生しない。

したがって手順書の「必要なfinal syncを`rsync -aHAX --numeric-ids`で行う」は、**今回のcutoverでは
対象なし**である。`rsync --delete`の誤用リスクも発生しない。

このため、cutoverで実際に切り替わるのは次の3つだけである。

1. NFSのmount modeが`ro`から`rw`になること（Apps VM側）
2. `.11.100/.101/.103`の所有者
3. どのプロセスがそのデータを開くか

## 7. cutover手順（Phase 2B、明示承認後のみ）

各段階の後に確認欄を満たすこと。満たせない場合は次へ進まず中止する。

| # | 操作 | 確認 |
| --- | --- | --- |
| 1 | cutover対象commit（`371fc31`）、7 image digest、rollback先commit、IX2215のconfig backupを記録 | 記録済み |
| 2 | IX2215から`.11.100/.101/.103`へpingし、応答することをbaselineとして記録 | 3つとも応答 |
| 2b | IX2215で`interface BVI11`の`no ip dhcp binding server_app-dhcp`（3.3） | `show ip dhcp profile`で`server_app-dhcp`にInterface表示がないこと |
| 3 | `flux suspend kustomization stashpad-prod stashpad-staging sillytavern` | `kubectl get kustomization -A`で3件suspend |
| 4 | `blocklist-updater` CronJobをsuspend（**Unboundより先**。rollout restartを仕掛けるため） | `SUSPEND: True` |
| 5 | stashpad-prod、stashpad-staging、sillytavern、samba、external-unbound、**ingress-nginx-controller**を`--replicas=0` | 各namespaceでPod 0 |
| 6 | NFS server側でopen writerの消失を確認 | `cat /proc/fs/nfsd/clients/*/states`にstashPad DBのopenが無いこと。**1件でも残れば中止** |
| 7 | MetalLB speakerを停止（DaemonSetに到達不能なnodeSelectorをpatch）。Service objectは変更しない | speaker Pod 0 |
| 8 | IX2215から3 IPへpingし無応答を確認。`show arp entry`のBVI11が`.11.22`のみになることを確認 | 3つとも無応答。**1つでも応答すれば中止** |
| 9 | 4 datasetのsnapshotを取得し存在確認（第5節） | 4件そろう |
| 10 | `legacy_service_addresses_enabled=true`、`legacy_service_cutover_confirmed=true`、`application_cutover_confirmed=true`、`network_migration_complete=false`でAnsible適用 | pre-task gateが通過し、`homelab-service-addresses`の`arping -D`が重複を検出せず起動 |
| 11 | Caddy、AdGuard Home、Samba、applications、Gatusの順に起動 | 各container healthy |
| 12 | [受入試験](k8s-to-compose.md#acceptance)を実施 | 全項目合格 |
| 13 | 合格後にKubernetes VMを停止（**削除しない**） | 14日保持を開始しない（起点は再構築試験の合格日） |

手順書に対する追加・変更点は次の3つである。

- **ingress-nginx-controllerの停止を追加**した。これを止めないと`.11.100`が解放されない。
- **`blocklist-updater` CronJobのsuspendを追加**し、Unbound停止より前に置いた。
- **MetalLB speakerの停止を追加**した。workloadを0にすればendpoint消失で広告は止まるが、
  Service objectを触らずに広告だけを確実に止める二重化として実施する。Service objectを残すため、
  rollback時にMetalLBが同じIPを再割り当てできる。

## 8. rollback手順

新旧を同時にwriterにしないことを最優先する。

| # | 操作 | 確認 |
| --- | --- | --- |
| 1 | Apps VMで`homelab-apps.service`を停止し、全Compose projectがdownしたことを確認 | `docker ps`が0件 |
| 2 | `systemctl stop homelab-service-addresses`でservice IPを外す | Apps VMの`ip -4 addr`に`.11.x`がない |
| 3 | Apps VM側で発生したwriteを記録する。Compose起動後に書かれたデータの扱いを決める | 記録 |
| 4 | NFS server側でApps VMのopen stateが0件であることを確認 | `states`が空 |
| 5 | MetalLB speakerのnodeSelector patchを戻す | speaker Pod 3件 |
| 6 | ingress-nginx、samba、sillytavern、stashpad-prod/stagingを`--replicas=1` | Pod Running |
| 7 | Unboundは**旧ReplicaSetで復旧**する。`replicas=1`にすると新Podが同じRPZ構文エラーで再度CrashLoopする | DNS応答が戻ること |
| 8 | `flux resume kustomization stashpad-prod stashpad-staging sillytavern` | Ready |
| 9 | IX2215で`interface BVI11`に`ip dhcp binding server_app-dhcp`を再投入する | `show ip dhcp profile`でInterface BVI11が復帰 |
| 10 | 現行FQDNから旧serviceが正常に応答することを確認 | 200/401などの期待応答 |

`make rollback-app`が成功した場合は、自動reconcileが停止したまま`/var/lib/homelab/reconcile.pending`に
現在の`origin/main` SHAと対象projectが記録される。原因とdata/schema互換性を確認してから
`reconcile.paused`を削除する。

## 9. 変更対象と、明示的に変更しない対象

### cutover windowで変更するもの

- IX2215のVLAN 11 DHCP設定（停止または範囲縮小）
- Kubernetes workloadのreplica数、Flux Kustomizationのsuspend、CronJobのsuspend、MetalLB speakerのnodeSelector
- ZFS snapshotの新規作成（4 dataset）
- Ansibleのcutover flag 3つと、それに伴うApps VMのNFS mount mode、service IP、Compose起動

### 変更しないもの

- `files/infrastructure/network/README.md`、`files/infrastructure/network/config.txt`
- `vmbr0.11`の`192.18.11.11/24`（記録のみ）
- BVI11の`/25`→`/24`（ユーザー管理の期待値であり、network移行windowで扱う）
- MetalLB poolの範囲、Service object、Ingress定義
- NFS exportの定義、既存data、markerファイル
- LoadBalancer Serviceの削除やtype変更
- orphan PVC directory 7件（Phase 5で判断）
- Tailscaleのpolicy、DNS、route（`manage_tailnet=false`維持）
- ECW5211、他VLANのDHCP、VLAN 10/20/30/40の再編
- Kubernetes VM、PVC、ZFS datasetの削除
- `stashPadDev`（VMID 111）

## 9.1 ユーザー判断（2026-09-05 決定）

| 項目 | 決定 |
| --- | --- |
| Phase 2B着手 | 承認。2026-09-05 18:00以降に実施する |
| maintenance window | 即時開始。`mover.sh`が動く05:00には掛からない |
| 作業経路 | LAN側からIP直指定で実施する。Tailscale経由の名前解決には依存しない。外出先の場合はTailscaleを切断して作業する |
| Tailscale DNS断 | 対策を取らない。窓中の名前解決断は許容する |
| Unbound rollback | Kubernetesには事前に手を加えない。rollbackが必要になった場合は、壊れたRPZファイルをNFS server上で除去してからscaleする |
| 中止判断 | 単独運用・単独利用のため形式的な承認者は置かない。客観的な停止条件（open writer残存、fencing後のping応答、`arping -D`の重複検出、想定外のTerraform/Ansible差分）だけを守る |
| 受入試験 | 全項目を必須とする。短縮aliasと新規2 FQDNも含めて確認する |
| 証明書発行の失敗 | rollbackの理由にしない。HTTPのまま原因を調査する |
| Apps VMのlegacy address mask | `/24`のまま進める。誤っているのはBVI11の`/25`側であり、Phase 4で`/24`へ修正する |
| Kubernetes VMの停止 | 受入試験合格後もしばらく起動したままとする（workloadは0、speakerも停止済みでwriterではない）。安定を確認してから停止する。削除は再構築試験の合格日から14日後 |
| OpenLDAP | 廃止済みであることをPod一覧で確認した。orphan dataはPhase 5で処理する |

### 9.2 cutover後のユーザー確認（2026-09-05）

ユーザーから、7 FQDN（stashPad prod/stagingの正式名と短縮alias、SillyTavern、DNS、status）の動作確認と、
IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない隔離テストの完了申告があった。FQDN確認で実施した
application操作の内訳は記録されていないため、stashPadの更新/upload/metadata分離、SillyTavernの
会話・設定保存、Samba 3 shareのread/writeは個別の受入項目として残す。

## 10. 未解決事項

1. Dependabotスキャンjobの失敗原因。cutoverの停止条件ではない。
2. `192.168.10.51`の同定（3.5）。writerではないためcutoverには影響しない。
3. maintenance window、想定停止時間、操作者、OOB access、各段階の中止判断のユーザー合意。

解決済み:

- Kubernetes稼働中imageとCompose宣言digestの一致確認（1.1）。4用途すべて一致した。
- IX2215のDHCP leaseとARP表（3.1、3.3、3.4）。VLAN 11のlease 0件を確認し、DHCP除外方針を確定した。

## 11. 停止条件に対する現時点の判定

| 停止条件 | 判定 |
| --- | --- |
| VMID 112、`.10.42`、service IPに想定外の所有者 | 該当なし。Apps VMはnon-writerを維持 |
| Terraform planがApps VM以外を変更 | 未実施（本フェーズではplanを実行していない） |
| state backup preflight、SSH host key、NFS source/fstype/mode/markerの検証 | marker 7件は内容一致。Apps VMの7 mountはすべて`ro` |
| NFSの所有者、ACL/xattr、snapshot、open writerを説明できない | すべて説明可能。ただしsnapshot 0件の2 datasetと未記録8 directoryを新たに記録した |
| DHCP/MetalLBがservice IPを所有したままApps VMへ付与 | **現在は該当。手順7の#2b、#5、#7、#8で解消してから#10へ進む**。DHCP側はlease 0件のためbinding解除だけで解消し、MetalLB側はworkload停止とspeaker停止で解消する |
| imageがdigest固定されていない、宣言digestと公開manifestが不一致 | 該当なし。Compose側7件は固定・公開manifestと一致し、稼働中の4 applicationはKubernetesとComposeでdigestが同一 |
| Tailscale live ACLをexport・reviewせず`manage_tailnet=true` | 該当なし。exportとreviewを実施し、`false`を維持 |
| rollback手順、OOB access、maintenance window、明示許可のいずれかがない | **maintenance windowと明示許可が未取得。Phase 2Bへ進まない** |
