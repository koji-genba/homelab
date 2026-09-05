# 実装状況

- 状態: フェーズ0/1 apply・受入確認、Phase 2A読み取り専用調査に続けて、2026-09-05に
  Phase 2B application cutoverを実施済み。**Apps VMが唯一のwriterとなり、7 Compose projectが稼働中**。
  旧KubernetesはVMこそ起動しているがwriterではない。Phase 3（再構築性試験）と、それに続く
  Kubernetes VM 14日保持期間はまだ開始していない
- 更新日: 2026-09-05
- 手順書: [KubernetesからComposeへの移行](k8s-to-compose.md)
- 関連文書: [Phase 2A事前調査結果](phase2a-inventory.md)（実測値、cutover/rollback手順）、
  [次セッションへの作業指示](next-session.md)（最新の実機状態と残作業の一次情報）

この文書は設計、ローカル実装、実機反映を区別する。2026-09-05のPhase 2B application cutoverにより、
Apps VMが唯一のwriterとなり、Caddy/AdGuard Home/Samba/stashPad prod・staging/SillyTavern/Gatusの
7 Compose projectが稼働している。旧KubernetesはVMを起動したまま残しているが、Flux Kustomization 4件の
suspend、Deployment 6件のreplicas=0、MetalLB speakerの停止、3 ServiceのClusterIP化によりwriterではない。
IX2215はVLAN 11のDHCP bindingを解除して`write memory`で保存済み、さらに2026-09-05にBVI11を
`192.168.11.1/25`から`/24`へ修正し、ACL 3本（`server_app-out`、`default-out`、`guest-out`）の
`/25`表記を`/24`へ更新して`write memory`で保存済みである。Tailscaleはlive ACLのexport・reviewは
済んだがTerraformへのimportは済んでおらず`manage_tailnet=false`を維持、ECW5211とVLAN 10/20/30/40への
再編（Phase 4）は未着手である。NFS serverのexport設定と既存dataはmount guard用marker追加以外変更していない。
ProxmoxのTerraform認証、SOPS/age、Discord webhook、Healthchecks.io checkは準備済みで、2026-09-05に
実serviceのread/write、FQDN、隔離、再起動、fail-closed、Gatus/Healthchecks.ioのDiscord通知を含む
application cutoverの受入試験を完了した（詳細は「今後の残作業」）。

## Gitに実装済み

- Debian 13 Apps VMのTerraform root、固定cloud image/checksum、VMID 112、暫定`.10.42`、
  address-less VLAN 11 NIC
- Docker、NFS read-only bootstrap、marker guard、nftables、IPv6無効化、secret転送、
  systemd lifecycleのAnsible roles
- Ansibleのpre-task cutover flag fail-closed検証、既存Compose writer停止後のNFS read-only
  remount、NFS source/fstype/ro-rw検証、Compose reverse-order shutdown、Docker再起動時の
  `PartOf`復旧連携
- Caddy、AdGuard Home、Samba、stashPad prod/staging、SillyTavern、Gatusの7 Compose projects
- legacy service IPのwriter-fencing/ARP gate、cutover時のimage digest gate、手動rollback
- stagingだけのimage digest自動更新、prodの明示promotion、Dependabot、CI validation
- SOPS/ageのruntime secret境界と、`state-backup` branchへの暗号化Terraform state recovery copy、
  fresh cloneからのfail-closedなstate restore
- Tailscale Terraform rootの手動・import-first・global DNS only gate。live ACL exportがなければ
  `manage_tailnet=true`を拒否する
- NFS exportの実path、client scope、option、一意markerを記録した手動反映契約
- toolbox 1.0.1の任意UID/GID OpenSSH対応、Debian 13のcloud-init/Ansible bootstrap修正、
  `deb822_repository`によるDocker repository設定とそのregression fixture
- cloud-init creation-time snippetの更新で既存VMをreplaceしないTerraform lifecycle guard
- 2026-08-30に取得した実機インベントリ（[詳細](../architecture/live-inventory-2026-08-30.md)）
- application cutoverで実機適用時に判明した3件の実装バグ修正（PR #19）: AdGuardHome.yaml.j2の
  `trim_blocks=True`起因のYAML生成不正、`homelab-apps.service.j2`/`homelab-app-reconcile.service.j2`の
  改行消失による`PartOf=docker.service`/`Wants=network-online.target`無効化、Samba image内蔵
  HEALTHCHECKの誤検知（終了コード判定へ変更）。いずれもoffline検証では検出できず実機適用で顕在化した
- cutover後の監視確認で判明したGatus Caddy probeのredirect/TLS誤検知をPR #20で修正し、
  `gatus-config-check`を追加した。さらにbind-mounted fileだけのGit変更をcontainerへ反映できない
  reconcile/rollbackの不具合をPR #21で修正し、選択projectをforce-recreateするfixtureを追加した

## ローカル検証済み

- Apps VM Terraform (`bpg/proxmox 0.111.1`) とTailscale Terraform (`tailscale 0.29.2`)の
  `fmt`, `init`, `validate`
- Ansible lint `production` profileとplaybook syntax check（warning 0）
- 7 Compose projectsの`docker compose config`
- ShellCheck、平文secret/state scan、state-backup/restore fixture（既存state、不正JSON、不正pathの拒否を含む）
- 公式AdGuard Home v0.107.79 binary/checksumによるschema 34 config check
- digest固定の公式Caddy 2.11.4からCloudflare module入りimageをbuildし、Caddyfileを実バイナリで検証
- Gatus v5.36.0実コンテナで設定と10 endpointを読み込み、DNS probeの送信先解釈を検証
- Samba設定を`testparm` で検証
- 実際のage identityを使ったSOPS暗号化・復号と`state-backup-preflight`。既存のlocal Terraform
  state 7ファイルはGit非追跡を確認し、modeを`0600`へ修正済み
- toolbox UID fixture、cloud-init schema fixture、Ansible bootstrap path fixture。Debian 13 minimal imageで
  不足するpasswd、systemd drop-in、Docker config directory、`python3-debian`依存を検証済み

これらはローカルの構文・fixture検証であり、実データのread/writeやFQDN、TLS、Discord通知を
検証したことを意味しない。

2026-09-05のPhase 2B cutoverで、この限界が実際に露見した。`make adguard-config-check`は
静的なconfig（手で書いたfixture相当）しか検証しておらず、Ansibleが`trim_blocks=True`の下で
実際にレンダリングする出力を検証していなかったため、AdGuardHome.yaml.j2のYAML生成不正を
事前に検出できなかった。同じ原因のsystemd unit templateの改行消失も、`ansible-lint`や
`ansible-check`のsyntax checkでは検出できていない。**Jinja2 templateのレンダリング後出力を
検証する仕組みは現時点で存在せず、既知の弱点として残る。** PR #19では顕在化した3件を
個別に修正したのみで、検証手段そのものは追加していない。

## 実機で確認済み

- Proxmox `pve1` 9.2.3、kernel `7.0.6-2-pve`、単一node、Ryzen 9 5900X 12コア/24スレッド、
  RAM 125 GiB（available約30 GiB）
- `local`空き約64 GiB、`local-lvm`空き約794 GiB、`vmpool`空き約582 GiB。VMID `112`は4 vCPU、12 GiB RAM、
  40 GiB disk、VLAN 10の`.10.42/24`、アドレスレスVLAN 11 NICでapply済み
- `vmbr0`は`nic0`接続、VLAN-aware `2-4094`。`vmbr0.11`の`192.18.11.11/24`とKubernetes側
  `192.168.11.21-.23`の不一致は要確認
- NFS親export 4つ、利用path 7つは存在し、2026-09-05にmarker 7つを作成済み。ZFS poolはすべて`ONLINE`
  （PVC実使用量はSillyTavern 148 MiB、stashPad prod 56 MiB、staging 57 MiB。mediaは`du` timeoutで未計測）
- Kubernetes `v1.36.1`の3 nodeはすべて`Ready`。LoadBalancerはingress `.11.100`、Unbound `.11.101`、
  Samba `.11.103`
- 正式stashPad FQDNは`200`かつ証明書正常、SillyTavernは想定どおり`401`。短縮aliasは自己署名で、
  `prod.kojigenba-srv.com`/`staging.kojigenba-srv.com`はIngress TLS SAN不足による自己署名証明書エラー
- Unbound旧Replicaは稼働中だが新Replicaは不正な`hagezi-tif` RPZでCrashLoop、blocklist Jobは直近3回失敗。
  手動DNS record 10件はAdGuard templateへ保持済み。OpenLDAP/phpLDAPadmin/LDAPS workload/serviceはなし
- Tailscale `home-gateway`（VM名`tailscale-gateway`）はversion `1.98.3`、IPv4 forwarding有効、
  routeは`0.0.0.0/0`、`::/0`、`192.168.10.0/24`、`192.168.11.0/24`。exit nodeは現行機能として保持する
- PVEに`terraform@pve`、`HomelabTerraform` role、`apps-vm` API tokenを作成済み。ACLは
  `/vms/112`、`/storage/local`、`/storage/vmpool`、`/nodes/pve1`、`/sdn/zones/localnetwork`に限定し、
  tokenの有効期限は2026-12-04 23:59 JST。applyには`Sys.AccessNetwork`と`vmbr0/10`、`vmbr0/11`の
  SDN child ACLも必要だったため、対象へ限定して追加した
- Discord webhookとHealthchecks.ioの`homelab-apps` check/Discord integrationを手動作成済み。
  endpointはSOPS bundleへ格納し、Apps VMからのGatus障害・復旧通知とHealthchecks.ioのDOWN・UP通知を検証済み
- NFS利用pathのmount、数値UID/GID、mode、ACL/xattr、snapshot、現行clientを再確認した。ZFSは
  `noacl`でmarker作成前のxattrはなく、Kubernetes worker 2台を現行NFS clientとして確認した。
  markerは`root:root`、`0644`で作成し、両workerからNFS越しに全内容を検証済み
- mergerfs `/mnt/shared`と直接HDD exportが同じ`tank-gen2/data/shared` rootを見せるため、両者の
  marker名を分離した。markerはcache側ではなくHDD側へ置き、mergerfs越しの可視性も確認済み
- `tank-gen2/data/shared`には2026-09-05時点で26 snapshotがある（`mover.sh`によるもの。詳細は後述）
- ED25519 host keyは、信頼済みPVE access経由のQEMU guest agentから取得したfingerprintと、network上の
  `ssh-keyscan`で独立に観測したfingerprint `SHA256:crmNjtlEWlIzTu4VKVR6/ArBqsAZV6qUW95uyOvFLUw`が一致することを
  確認してから`known_hosts`へ追加済み
- 初回Ansibleは`ok=61 changed=29 failed=0`、再実行は`ok=58 changed=0 failed=0`。再起動後はhostname `apps`、
  failed unit 0、7 NFS mountが`nfs4` read-onlyでmarker一致、mount guard enabled/active、Compose/reconcile/
  Healthchecks/legacy-address unit disabled/inactive、container 0個を確認した
- cloud-init snippet driftは、PR #16（main commit `1171e5cbc178a9db3920ed55fa5c5058daec71f7`、validation run
  `33952996065`）のlifecycle guardによりVM replacementなしで反映済み。saved plan hashは
  `217241ca872aaec0de7d40bd9ce45fca070369e9d3c0f5a241ea87e64d98cc47`で、machine checkは
  `proxmox_virtual_environment_file.cloud_config`の`[delete,create]`だけ（1 add/0 change/1 destroy、VM 112差分なし）。
  apply後にplanは削除し、state-backup remote先頭は`39ee06b5028ae318676c736dfb432f73404a95ca`になった。
- live PVE snippetのschemaは`hostname: apps`、deploy userの`lock_passwd: true`、top-level `lock_passwd`なしを確認した。
  VMは同じboot time `16:15:42`のまま稼働し、MAC/disk/config、SSH trusted keyを維持した。service-side IPv4は`.10.42`だけで、
  cloud-init clean/reinitは実行していない。
- `/mnt/shared`はmergerfsで`category.create=ff`のため、新規書き込みは先頭branchの
  `cache-pool`（`/mnt/cache-sata`）に着地する。pve1のroot crontabにある`/usr/local/bin/mover.sh`
  （05:00起動）がcache→`tank-gen2/data/shared`へrsyncした後にsnapshotを作成・世代destroyする、
  Kubernetesとは独立した第3のwriterであることを確認した。cutover後も運用を継続する
- `tank-gen1/data/archive`と`tank-gen2/data/k8s-volumes`はsnapshot 0件で、`sanoid`/`zfs-auto-snapshot`/
  `znapzend`等の自動snapshot機構も未導入だった。cache branchである`cache-pool`にもsnapshotはない。
  cutover直前に4 dataset（`tank-gen2/data/k8s-volumes`、`tank-gen1/data/archive`、
  `tank-gen2/data/shared`、`cache-pool`）へ`@pre-compose-cutover-20260905`を取得し、4件そろったことを
  確認済み。Phase 3の再構築試験に合格するまで削除しない
- 移行文書が管理する7 pathの外に、NFS上へ実データを持つ未記録pathが8件あることを確認した。うち
  `external-dns-blocklist-data-pvc-8e7db6e1-...`はexternal-unbound Deploymentとblocklist-updater
  CronJobの2系統がwriterを持つ現用workloadで、cutover時にwriter停止対象へ追加した（AdGuard Home移行後は
  不要）。残り7 directory（openldap 3世代、旧blocklist 2世代、旧stashpad prod/staging各1世代）は
  writerが存在しないorphanで、Phase 2Bでは削除せずsnapshotで保全した
- kube-proxyがIPVSモードで、live ConfigMapの`strictARP: false`であることを確認した。kubespray
  inventoryの宣言値`kube_proxy_strict_arp: true`とdriftしており、MetalLB speakerを停止しても
  nodeが`kube-ipvs0`経由でLoadBalancer IPへのARPを返し続けたため、service IP解放にはServiceの
  ClusterIP化が別途必要だった
- IX2215のBVI11は`192.168.11.1/25`で、`server_app-dhcp`のDHCP leaseは実測で0件だった
  （Phase 2A調査時点の観測値。歴史的記録として残す）。影響を受けるclientがないことを確認した上で
  `interface BVI11`の`ip dhcp binding server_app-dhcp`を解除した。2026-09-05にユーザーが
  `write memory`を実行し、解除後のrunning-configをstartup-configへ保存済みである。同日、
  BVI11の`ip address`を`/25`から`/24`へ修正済みである（詳細は後述の
  「IX2215構成ドリフトの解消（2026-09-05）」）

## フェーズ1 apply・受入確認済み

- Caddyを含む7 projectすべてのimageを公開manifest digestへ固定済み
- SSH公開鍵のfingerprintをPVEの`authorized_keys`と照合し、SSH agent経由のroot接続を確認済み。
  `origin`はfetchをHTTPS、pushをSSHに設定
- age identity/recipientとProxmox tokenをKeePassXCへ保存し、実値の`runtime.sops.yaml`を作成済み
- `make state-backup-preflight`は2026-09-05に成功
- NFS marker 7つをserver側へ作成し、Kubernetes clientから検証済み
- Terraform VMID 112をapplyし、state-backup remote先頭`a209ba9f9b3cddf57de48deb9b9f9168fbd21188`を確認済み
- VMのhost keyをOOB確認後に`known_hosts`へ追加し、Ansible applyと再起動後のread-only/non-writer受入確認を完了
- （フェーズ1完了時点の記録）Kubernetesを唯一のwriterとして維持し、legacy IP、NFS write、Tailscale、
  VLAN/network cutoverは未実施だった。この状態は下記のPhase 2B実施により変わっている

## Phase 2Bの実施結果（application cutover、2026-09-05）

`phase2a-inventory.md`の読み取り専用調査とユーザー判断（同文書9.1節）に基づき、同日中に
application cutoverを実施した。実施した操作は次のとおりで、各段階の確認欄を満たしてから
次へ進んだ（詳細な手順と確認結果は[phase2a-inventory.mdの7節](phase2a-inventory.md)を参照）。

1. IX2215から`.11.100/.101/.103`へpingしbaseline応答を記録
2. IX2215で`interface BVI11`の`no ip dhcp binding server_app-dhcp`を実行（`write memory`は未実行のまま）
3. Flux Kustomization 3件（stashpad-prod、stashpad-staging、sillytavern）をsuspend
4. `blocklist-updater` CronJobをUnbound停止より先にsuspend
5. Deployment 6件（stashpad prod/staging、sillytavern、samba、external-unbound、
   ingress-nginx-controller）を`--replicas=0`
6. NFS server側でstashPad DBのopen writerが0件になったことを確認
7. MetalLB speaker DaemonSetを到達不能な`nodeSelector`へpatchして停止（Service objectは変更せず、
   rollback時に同じIPを再割り当てできるようにした）
8. IX2215から3 IPへ再pingし無応答を確認、`show arp entry`のBVI11が`.11.22`のみになったことを確認
9. 4 dataset（`tank-gen2/data/k8s-volumes`、`tank-gen1/data/archive`、`tank-gen2/data/shared`、
   `cache-pool`）へ`@pre-compose-cutover-20260905`を取得し、4件そろったことを確認
10. Ansible flagを`legacy_service_addresses_enabled: true`、`legacy_service_cutover_confirmed: true`、
    `application_cutover_confirmed: true`へ変更してapply（`network_migration_complete`は`false`を維持）。
    pre-task gateが通過し、`homelab-service-addresses`の`arping -D`が重複を検出せず起動した
11. Caddy、AdGuard Home、Samba、stashPad prod/staging、SillyTavern、Gatusの7 Compose projectを起動

cutover適用中に、AdGuardHome.yaml.j2のYAML生成不正によるDNS起動失敗を含む3件の実装バグを
実機で初めて検出し、PR #19（`e1117b3`、`4e28a08`でmain merge済み）で修正した。詳細は
[「Gitに実装済み」](#gitに実装済み)と[next-session.mdの該当節](next-session.md)を参照。

実施後に確認できた状態は次のとおりである（2026-09-05 19:11時点、詳細は
[next-session.mdの「現在のシステム状態」](next-session.md)）。

- Apps VMの`ens19`が`192.168.11.100/.101/.103`を保持し、`eth0`は管理用`192.168.10.42/24`のまま
- NFS 7 mountのうち`stashpad-media`のみ`ro`、他6つが`rw`
- `homelab-apps.service`は`active`、7 Compose project全containerがhealthy/稼働
- 稼働中imageのdigestはGit宣言（`origin/main` `4e28a08`）と一致
- Kubernetes側はVM起動のままFlux 4件suspend、Deployment 6件replicas=0、MetalLB speaker停止、
  3 ServiceがClusterIP化されwriterではない

自動確認できた受入項目は合格した。7 FQDNのLet's Encrypt証明書、DNSの通常応答・内部record・
ブロック、stashPad prod/stagingの`200`、SillyTavernの`401`、SMB 445の到達性、稼働image digestと
Git宣言の一致。2026-09-05にユーザーが7 FQDNの動作確認とIoT/Guest/Internetから管理UI、SSH、SMBへ
到達できない隔離テストの完了を申告した。FQDN確認の操作内訳は未記録のため、application別の
read/write項目は未了のまま「今後の残作業」に記載する。

同日20:54の読み取り再確認では、Apps VMの7 container、3 service IP、7 NFS mount、mount guard、
reconcile timerが正常だった。旧KubernetesはFlux Kustomization 4件suspend、CronJob suspend、
Deployment 6件replicas=0、MetalLB speaker停止、3 ServiceのClusterIP化を維持していた。NFS server側で
Kubernetes workerに残るopenは旧Unbound RPZへのread-onlyだけで、rw openはApps VMのstashPad
prod/staging DBだけだった。

21:09までにPR #20（Gatus Caddy probe修正）とPR #21（bind mount更新時のreconcile/rollback修正）を
mainへmergeし、Apps VMへ反映した。Gatus containerは手動force-recreate後、Caddy probeを`HTTP 308`、
`success=true`として観測した。Ansible適用は`failed=0`で、reconcile/rollback helper 2本を更新し、
runtime入力に差分がなかったため全Compose projectの再作成は発生しなかった。PR #22の文書更新も
mainへmergeし、Apps VMのcheckoutは`origin/main` `e272c75`と一致している。

## IX2215構成ドリフトの解消（2026-09-05）

2026-09-05にユーザーがIX2215のCLIで次を実施し、`write memory`まで完了した。

1. `interface BVI11`の`ip address`を`192.168.11.1/25`から`/24`へ変更した。新しい`ip address`の
   投入で上書きされ、`no ip address`は不要だった。`show ip route`で
   `C 192.168.11.0/24 ... BVI11`を確認した。
2. ACL 3本の`192.168.11.0/25`を`/24`へ更新した。`server_app-out`（srcの5エントリ）、
   `default-out`（destの1エントリ）、`guest-out`（destの1エントリ）。`iot-out`、`main-out`、
   `server-out`は元から`/24`で無変更だった。
3. **IX2215のACLは投入順に末尾追加され、エントリ単位のシーケンス番号や途中挿入の構文がない。**
   そのため個別エントリを`no`で消して再投入すると、末尾の`permit ip src any dest any`の後ろに
   回り、永久に評価されなくなる。実際に`default-out`と`guest-out`でこれが発生し、VLAN 63 →
   VLAN 11とGuest VLAN 40 → VLAN 11のdenyが一時的に無効化された。変更前は`/25`のdenyが
   `permit any`より前にあって有効だったため、**一時的にcutover前より弱い状態を作った**。
4. 復旧方法（`server_app-out`では最初からこの方法を用いた）は次の順序である。インターフェースから
   `ip filter`のバインドを外す → `no ip access-list <名前>`でリストごと削除する →
   `option optimize`を先頭に、正しい順序で全エントリを再投入する → `ip filter`を再バインドする。
   フィルタを先に外すのは、空または未定義のACLを`ip filter`が参照した場合の挙動をNEC公式資料で
   確認できなかったため、無フィルタ＝素通りという既知の状態に倒して通信断を避ける意図である。
5. 事後確認として、BVI63に`ip filter default-out 10 in`、BVI40に`ip filter guest-out 10 in`が
   戻っていることと、Guest VLAN 40の端末から`192.168.11.100`へ到達できないことをユーザーが
   実測した。そのうえで`write memory`を実行した。
6. 実機のソフトウェアバージョンは**10.11.6**（`Compiled May 22-Thu-2025`）であり、記録上の
   10.7.18とドリフトしていた。`config.txt`と`README.md`を10.11.6へ更新済みである。
7. 実機にある`system interfaces bvi 64`が記録に無かったため`config.txt`へ追加した。`sflow`の
   2行は実機にも存在し、記録上の位置だけがずれていたので実機の順序へ移動した。
8. 実機の`show running-config`全文を`config.txt`と照合した。注釈コメントと`!`の区切り行を
   除く293行は、両者で行の集合が完全に一致する。
9. 照合の過程で、`config.txt`に実機へ存在しない`interface GigaEthernet2.0`の重複定義
   （`no ip address`と`shutdown`のみを持つblock）が残っていることが判明したため削除した。
   実機のGigaEthernet2.0は`bridge-group 63`かつ`no shutdown`である。**この重複を残したまま
   `config.txt`を実機へ投入すると、untaggedポートを`shutdown`する危険があった。**
10. `config.txt`は注釈付きの記録であり、`show running-config`の逐語dumpではない。内容は一致するが
    blockの並び順が3箇所で異なる。`device GigaEthernet2`内のsflowとvlan-groupの順、
    `interface GigaEthernet2.0`の位置、`interface GigaEthernet2:1.0`から`2:6.0`までの位置である。
    次回照合する際は行の並びではなく行の集合として比較すること。
11. `interface BVI11`の`ip dhcp binding server_app-dhcp`は解除済みのまま（今回変更していない）。
    `ip dhcp profile server_app-dhcp`の定義自体は残してある。
12. BVI11が`/24`になったことで、MetalLB pool（`.100-.200`）が`/25`を超えているという既知の
    不整合は解消した。

## Kubernetes VMの停止（2026-09-05）

Phase 2B application cutoverの受入試験と、IX2215構成ドリフトの解消が完了したため、
Kubernetes VM 3台を停止した。**停止のみであり、VM、disk、PVC、NFS data、ZFS snapshotは削除していない。**
Phase 3の再構築試験に合格するまで削除しない。

### 停止前に取得したもの

停止すると`kubectl`が使えなくなるため、rollbackに必要な値を
[rollback用 状態スナップショット](k8s-rollback-state.md)へ恒久保存した。Service 3件の完全なJSON、
Deployment replicas、`metallb-speaker`のnodeSelector、Flux suspend状態、PVC/PV一覧、
NFS open stateのベースラインを含む。それまで変更前のService定義はセッションのscratchpadにしか
存在せず、恒久保存されていなかった。

あわせて、これまでの記録にあった**Unbound復旧手順の誤りを訂正した**。「旧ReplicaSet
`external-unbound-588bcf9d7c`（revision 129）が正常な世代」という記述は誤りである。
Deploymentの`revisionHistoryLimit`は`10`で、当該ReplicaSetはとうに回収されて存在しない。
現存する11件（revision 278〜288）はpod templateが完全に同一であり、差分は
`kubectl.kubernetes.io/restartedAt` annotationと`pod-template-hash`だけである
（template本体のhashは全件`edb261e79bf9d3d6`、imageは全件`ghcr.io/koji-genba/external-unbound:v1.8`）。
CrashLoopの原因はReplicaSetではなくPVC上の`rpz/hagezi-tif.txt`であり、中身はRPZ zoneではなく
GitHub側のサイズ超過エラー文（143 bytes）だった。`blocklist-updater`のdownloaderがHTTPエラー本文を
そのままファイルへ保存したことが原因である。正しい復旧手順はスナップショット文書に記載した。

### 停止前のベースライン（すべて合格）

- Compose 7 containerすべて`Up`、`homelab-apps.service`は`active`、failed unit 0件
- `ens19`に`192.168.11.100` `.101` `.103`を保持
- 7 FQDNのHTTPS: stashPad prod/staging系4件が`200`、SillyTavern `401`、dns `302`、status `401`。
  TLS検証は全件`ssl_verify_result=0`
- DNS: 外部名前解決、内部record（`prod.stashpad` → `192.168.11.100`）、ブロック
  （`ads.doubleclick.net`と`analytics.google.com`がNXDOMAIN）すべて正常
- SMB `192.168.11.103:445`到達可
- VM 101/102/103は`Ready`、QEMU guest agentが3台とも応答

**apexの`doubleclick.net`はブロックされず実IPを返すが、これは正常である。**
hagezi側でapexが許可されているためであり、ブロック機能の確認には
`ads.doubleclick.net`など実際にリストへ載るFQDNを使うこと。

### 停止の実施

worker → control planeの順で`qm shutdown --timeout 180`を実行した。guest agentが応答したため
3台ともクリーンに停止し、`qm stop`による強制停止は不要だった。

| 順 | VMID | name | 所要 |
| --- | --- | --- | --- |
| 1 | 103 | `k8s-worker02` | 約16秒 |
| 2 | 102 | `k8s-worker01` | 約4秒 |
| 3 | 101 | `k8s-master01` | 約4秒 |

### 停止後の確認（すべて合格）

- VM 101/102/103が`stopped`。112 `apps`、105、110、111は`running`のまま
- Compose 7 containerは再起動なしで`Up`を継続。failed unit 0件、service IP 3つを保持
- 7 FQDNのHTTPSは停止前と同一の結果（`200`×4、`401`、`302`、`401`、TLS検証すべて`0`）
- DNSの外部解決・内部record・ブロックいずれも停止前と同一
- SMB 445到達可

### NFS open stateの扱い（想定と異なるが正常）

停止後もworker01/02のclient entryと`rpz/hagezi-pro.txt`へのread-only openが`states`に残る。
これはLinux nfsdの**courteous server**によるもので、`info`の`status`が`confirmed`から
`courtesy`へ遷移している。lease期限を過ぎてもread openやdelegationしか持たないclientは
即座にexpireせず、最大24時間保持される仕様である。

| client | 停止前 | 停止後 | open |
| --- | --- | --- | --- |
| `192.168.10.42` apps | `confirmed`、callback UP | `confirmed`、callback UP | stashPad prod/staging DBのrw open + write delegation 計20件 |
| `192.168.10.22` k8s-worker01 | すでに`courtesy`（last renewから17896秒） | `courtesy` | `rpz/hagezi-pro.txt`へのread-only open 6件 |
| `192.168.10.23` k8s-worker02 | `confirmed` | `courtesy` | `rpz/hagezi-pro.txt`へのread-only open 4件 |

worker01は停止前の時点ですでに`courtesy`だった。つまりこのstateは今回の停止で生じたものではなく、
以前scale downした旧Unbound Podが残したものである。いずれもread-onlyでdataへの影響はなく、
競合するアクセスがあればnfsdがrevokeする。**`ctl`への書き込みによる強制expireは行っていない。**
24時間以内に自然消滅するため、`states`から消えたことの確認はPhase 3の作業時に行えばよい。

### 併せて判明したこと（停止とは無関係の既存事象）

Apps VMのhost側resolverは`systemd-resolved`で、`eth0`のuplink DNSが`192.168.10.1`と`1.1.1.1`に
なっている。`192.168.10.1`はTCP/UDP 53を`connection refused`で拒否し、`1.1.1.1`は内部recordを
持たないため、**Apps VM自身のhost namespaceからは`*.kojigenba-srv.com`を解決できない。**
`192.168.11.101`のAdGuardへ明示的に問い合わせれば正しく解決する。

これはKubernetes VMの停止によるものではない。いずれのuplinkもKubernetesに依存していないためである。
実害も現時点ではない。Gatusはcontainer名（`http://caddy:80`等）で監視し、Docker内のcontainerは
public名の解決だけをhost resolverに依存するためである。**ただしhost側でFQDNを解決する運用スクリプトを
追加する場合はこの前提が崩れる。** Phase 4でApps VMを`192.168.10.101`へ集約し
global nameserverを移す際に解消される見込みである。

## 今後の残作業

### 受入試験の残項目

- [x] stashPad prod/stagingで閲覧・更新・upload・共有mediaを確認する（2026-09-05、ユーザー確認）
- [x] stashPad prod/stagingのmetadataが分離されていることを確認する（2026-09-05、ユーザー確認）
- [x] SillyTavernでlogin・会話・設定保存を確認する（2026-09-05、ユーザー確認）
- [x] Samba 3 shareを既存userでread/writeできることを確認する（2026-09-05、ユーザー確認）
- [x] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できないことを確認する（2026-09-05、ユーザー確認）
- [x] Apps VM reboot後にmountと全serviceが自動復旧することを確認する（2026-09-05 21:28、failed unit 0）
- [x] NFS未mountまたはmarker不一致でapplicationが起動しない（fail-closed）ことを確認する
  （2026-09-05、mount namespace内で実mount/markerを変更せず確認）
- [x] Gatusが障害と復旧をDiscordへ通知することを確認する（2026-09-05、Caddy/Public TLS certificateの障害・resolved通知をDiscordで受信確認）
- [x] Healthchecks.ioがdead-man停止を通知することを確認する（2026-09-05、DOWN/UP通知をDiscordで受信確認）

2026-09-05 21:21からCaddyだけを停止し、Gatusが3回連続失敗後にCaddyとPublic TLS certificateの
Discord障害通知を送信するログを確認した。Caddy復旧後は2回連続成功し、両endpointのresolved通知送信ログを
確認した。CaddyとPublic TLS certificateの障害・resolved通知はいずれもDiscordで受信確認した。21:27から
Healthchecks timerを約10分停止し、21:37にtimer再開と即時ping成功を確認した。Healthchecks.ioは5分periodと
grace経過後のDOWN通知、およびping復旧後のUP通知をDiscordで受信確認した。

同じwindowで、Apps serviceを停止してmount namespace内だけでstashPad prod mountを非NFS mountで覆う試験と、
markerを`/dev/null`で覆う試験を実施した。両方でmount guardとCompose起動が失敗し、container 0件を維持した。
namespace終了後に実mount/markerが正常なことを確認した。続くApps VM rebootではboot IDが変わり、7 NFS mount
（stashPad mediaだけro）、3 legacy service IP、7 Compose project、mount guard、reconcile timer、
Healthchecks timerが自動復旧し、failed unitは0件だった。管理端末のTailscaleはユーザーが切断し、作業は
Apps VM/PVEのLAN IP直指定で実施した。

### 受入試験の合格後

- [x] IX2215で`write memory`を実行し、DHCP binding解除を保存する（2026-09-05、ユーザー実行）
- [ ] Kubernetes VMを停止する（削除はしない。安定を確認してからでよい）

### Phase 3: 再構築性の証明

Kubernetes VMの14日保持期間を開始する前に実施する。手順は
[k8s-to-compose.mdのフェーズ3](k8s-to-compose.md)に従い、snapshot restoreで代替しない。
**合格した日が、Kubernetes VM 14日保持期間の開始日である。この14日はまだ開始していない。**

### Phase 4: ネットワーク移行

別のmaintenance windowで実施し、application cutoverへ混ぜない。含まれるのは次である。

- `files/infrastructure/network/README.md`と`config.txt`の反映（ユーザー管理）。BVI11の`/24`化と
  実機バージョン整合は2026-09-05に反映済みのため、Phase 4で残るのはVLAN 10/20/30/40再編に伴う
  変更に限る
- Tailscale live ACLのTerraform import、global nameserverの`192.168.10.101`への変更
- VLAN 10/20/30/40への再編、ECW5211の設定、Apps VMの`192.168.10.101`への集約

### Phase 5: 廃止

Phase 3合格から14日経過し、rollbackが発生していないことを条件とする。`k8s-volumes`配下の
orphan directory 7件（openldap 3世代、旧blocklist 2世代、旧stashpad prod/staging各1世代）の
削除判断もここで行う。

## 後続のゲート

Phase 3の再構築性試験（Apps VMをTerraform/Ansible/Gitから実際に削除・再構築する試験）に
合格した日から14日間の安定稼働を確認してからKubernetesを廃止する。**この14日保持期間は
まだ開始していない。** application flagをfalseへ戻すrollbackが必要な場合は、Apps VMの
`homelab-apps.service`停止とservice IP解放、NFS open state 0件の確認、MetalLB/Service/Flux/
Unboundの復旧を、新旧を同時にwriterにしないことを最優先して行う。手順の詳細は
[next-session.mdのrollback手順](next-session.md)を参照。

VLAN 10/20/30/40への再編（Phase 4）は別maintenance windowで実施する。
Tailscale live ACLのimport、Apps VMの最終`.10.101`への統合、ECW5211の設定はいずれも未着手であり、
現時点では期待状態と手順のみがGit管理されている。
