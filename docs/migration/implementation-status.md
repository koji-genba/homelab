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
IX2215はVLAN 11のDHCP bindingを解除したが`write memory`は未実行、Tailscaleはlive ACLのexport・reviewは
済んだがTerraformへのimportは済んでおらず`manage_tailnet=false`を維持、ECW5211とVLAN 10/20/30/40への
再編（Phase 4）は未着手である。NFS serverのexport設定と既存dataはmount guard用marker追加以外変更していない。
ProxmoxのTerraform認証、SOPS/age、Discord webhook、Healthchecks.io checkは準備済みだが、受入試験のうち
実serviceからの通知確認や一部のread/write確認は未検証のまま残っている。2026-09-05にユーザーから
7 FQDNの動作確認とIoT/Guest/Internet隔離テストの完了申告があった（詳細は「今後の残作業」）。

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
  endpointはSOPS bundleへ格納したが、Apps VMからの通知は未検証
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
- IX2215のBVI11は`192.168.11.1/25`（期待値`/24`との不一致は既知でPhase 4修正対象）で、
  `server_app-dhcp`のDHCP leaseは実測で0件だった。影響を受けるclientがないことを確認した上で
  `interface BVI11`の`ip dhcp binding server_app-dhcp`を解除した（`write memory`は未実行）

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

## 今後の残作業

### 受入試験の残項目

- [ ] stashPad prod/stagingで閲覧・更新・upload・共有mediaを確認する（ユーザー確認）
- [ ] stashPad prod/stagingのmetadataが分離されていることを確認する（ユーザー確認）
- [ ] SillyTavernでlogin・会話・設定保存を確認する（ユーザー確認）
- [ ] Samba 3 shareを既存userでread/writeできることを確認する（ユーザー確認）
- [x] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できないことを確認する（2026-09-05、ユーザー確認）
- [ ] Apps VM reboot後にmountと全serviceが自動復旧することを確認する（サービス断を伴う）
- [ ] NFS未mountまたはmarker不一致でapplicationが起動しない（fail-closed）ことを確認する（サービス断を伴う）
- [ ] Gatusが障害と復旧をDiscordへ通知することを確認する（発火が必要）
- [ ] Healthchecks.ioがdead-man停止を通知することを確認する（発火が必要）

### 受入試験の合格後

- [ ] IX2215で`write memory`を実行し、DHCP binding解除を保存する
- [ ] Kubernetes VMを停止する（削除はしない。安定を確認してからでよい）

### Phase 3: 再構築性の証明

Kubernetes VMの14日保持期間を開始する前に実施する。手順は
[k8s-to-compose.mdのフェーズ3](k8s-to-compose.md)に従い、snapshot restoreで代替しない。
**合格した日が、Kubernetes VM 14日保持期間の開始日である。この14日はまだ開始していない。**

### Phase 4: ネットワーク移行

別のmaintenance windowで実施し、application cutoverへ混ぜない。含まれるのは次である。

- BVI11の`/25`→`/24`修正と、それに伴うACL（`server_app-out`）の更新
- `files/infrastructure/network/README.md`と`config.txt`の反映（ユーザー管理。本作業では触っていない）
- Tailscale live ACLのTerraform import、global nameserverの`192.168.10.101`への変更
- VLAN 10/20/30/40への再編、ECW5211の設定、Apps VMの`192.168.10.101`への集約
- MetalLB pool（`.100-.200`）が`/25`を超えている不整合の解消（MetalLB廃止で自然に解消）

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

VLAN 10/20/30/40への再編（Phase 4）は別maintenance windowで実施する。BVI11の`/25`→`/24`修正、
Tailscale live ACLのimport、Apps VMの最終`.10.101`への統合、ECW5211の設定はいずれも未着手であり、
現時点では期待状態と手順のみがGit管理されている。
