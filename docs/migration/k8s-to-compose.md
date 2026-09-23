# KubernetesからComposeへの移行手順書

- 状態: **フェーズ0〜4完了。フェーズ5はVM・旧データ・DNS廃止を実施し、credential・受入確認が残る。**
- 更新日: 2026-09-23
- 目標設計: [目標アーキテクチャ](../architecture/target-state.md)
- 実施記録: [archive/実装状況](archive/implementation-status.md)
- 現在の作業指示: [次セッションへの作業指示](next-session.md)

この手順書は停止時間を許容する。一度にapplication runtimeとVLAN設計を変更せず、rollbackの
境界を単純にする。各check欄には実施日時、操作者、結果、関連commitを記録する。

| フェーズ | 状態 |
| --- | --- |
| 0 インベントリと安全確認 | 完了（2026-09-05） |
| 1 サービス所有権を持たないApps VMの構築 | 完了（2026-09-05） |
| 2 現在のVLANでのアプリケーション切替 | 完了（2026-09-05） |
| 3 再構築性の証明 | 完了（2026-09-06、合格） |
| 4 ネットワーク移行 | 完了（2026-09-13。Port 4のVLAN 10 access化は2026-09-19） |
| **5 廃止** | **2026-09-23実施中。VM・旧データ・NFS exportは完了** |

## フェーズ 0: インベントリと安全確認

- [x] Proxmox VM/LXC、IP、MAC、bridge、VLAN tagを実機から取得し、Git inventoryと照合する。
- [x] IX2215のrunning/startup configとDHCP leaseを取得する。
- [x] `.10.42`、`.11.100`、`.11.101`、`.11.103`についてARP/ping/DHCP/Proxmoxの重複を確認する。
- [x] ECW5211のSSID/VLAN/management IPと接続portを記録する。
- [x] 現在のcontainer image digest、UID/GID、data容量、file count、ACL/xattrを記録する。
- [x] 現行FQDN、certificate、Tailscale DNS/route/grantをexportする。
- [x] 現行secretとcredentialのinventoryを作り、移行後にrotateする対象を記録する。
- [x] NFS/ZFSが別手順で復旧可能であることを確認する。本runbookではその復旧を実施しない。
- [x] PVE local consoleまたは確実なout-of-band accessを確保する。

ゲート: inventoryに不明なwriter、IP競合、未記録の必須機能がある場合はフェーズ1へ進まない。

**完了（2026-09-05）。** 調査結果は[archive/Phase 2A事前調査結果](archive/phase2a-inventory.md)にある。
移行文書が管理する7 pathの外に、NFS上へPVデータを持つ未記録のworkloadが2系統
（`openldap`、`external-dns-blocklist`）あることがここで判明した。

## フェーズ 1: サービス所有権を持たないApps VMの構築

1. 管理端末へGit、Docker、Make、SSH鍵、age鍵を用意する。
2. 管理ツールコンテナをbuild/pullし、validationを実行する。
3. SOPS secret exampleから実値を作り、暗号化して保存する。
4. Terraform planでApps VM以外を変更しないことを確認する。
5. 暫定管理IP `.10.42`でDebian 13 Apps VMを作る。
6. AnsibleでDocker、NFS mount、nftables、systemd、Compose定義を配置する。
7. Apps VMからNFSをread-only/非writer状態で検証する。
8. Compose、Caddy、AdGuard Home、Gatus、Sambaの設定をoffline検証する。既存dataを使うstateful
   containerは、この段階ではshadow起動しない。

この段階では`.11.100/.101/.103`をclaimせず、旧Kubernetesを唯一のwriterに保つ。

ゲート: VM reboot後もmount guardが機能し、全設定のoffline検証が通ること。stateful serviceの
実probeはwriter fencing後のフェーズ2で行う。

**完了（2026-09-05）。**

## フェーズ 2: 現在のVLANでのアプリケーション切替

### 準備

- [x] Git mainのcutover commitと全image digestを記録する。
- [x] 対象datasetのZFS snapshotを取得する。
- [x] IX2215のVLAN 11 DHCPを停止するか、`.100/.101/.103`を確実に除外する。
- [x] Flux reconciliationをsuspendする。

### writerの隔離

1. stashPad prod/staging、SillyTavern、Samba、Unboundを停止する。
2. Podが停止し、NFSへのopen writerがないことを確認する。
3. ingress/MetalLBの`.11.100/.101/.103` ownershipを停止する。
4. ARP entryの消失をrouter/clientから確認する。
5. 必要なfinal syncを`rsync -aHAX --numeric-ids`で行う。最初から`--delete`は使わない。

### 新しいサービス所有権

1. Apps VMへ`.11.100/.101/.103`を追加する。
2. Caddy、AdGuard Home、Samba、applications、Gatusの順に起動する。
3. [受入試験](#acceptance)を実施する。
4. 問題がなければKubernetes VMを停止するが削除しない。

### ロールバック

1. Apps VMの`homelab-apps.service`を停止し、Compose projectをdownする。
   Ansibleでapplication flagをfalseへ戻す場合も、pre-taskがこの停止（ExecStopを含む）の
   成功を確認してからNFSをread-onlyへremountする。
2. Apps VMからservice IPを外し、ARP entry消失を確認する。
3. rollback中に新側へ書かれたdataを記録し、必要なら旧dataへreconcileする。
4. MetalLB/ingress/serviceとFluxを復元する。
5. 現行FQDNから旧serviceを検証する。
6. `make rollback-app` が成功した場合は、自動reconcileが停止したまま
   `/var/lib/homelab/reconcile.pending` に現在の `origin/main` SHA と対象projectが
   重複排除して記録される。原因とdata/schema互換性を確認した後にだけ
   `reconcile.paused` を削除し、reconcileを一度起動する。reconcileはmainを再fetchし、
   pending projectを現行定義へ戻してからpendingを消化したことを
   `deployments.log` で確認する。

ゲート: 全受入項目合格後もKubernetes VMは14日間保持する。

**完了（2026-09-05）。** Apps VMが唯一のwriterとなり、7 Compose projectが稼働を開始した。
同日Kubernetes VM 101/102/103を`qm shutdown`で停止した（削除はしていない）。
実機適用で初めて顕在化した実装バグ4件（AdGuardHome.yaml.j2のYAML生成不正、systemd unit templateの
改行消失、Samba HEALTHCHECKの誤検知、Gatus Caddy probeのredirect誤検知）と、bind-mounted fileだけの
変更をcontainerへ反映できないreconcileの不具合はPR #19〜#21で修正済みである。
詳細は[archive/実装状況](archive/implementation-status.md)にある。

## フェーズ 3: 再構築性の証明

Kubernetes VMの14日保持期間を開始する前に、Apps VMの再構築試験を行う。

1. applicationを停止する。
2. deploy commit、local state backup、NFS markerを確認する。
3. Apps VMをTerraformで削除する。
4. freshなApps VMをTerraformとAnsibleで再作成する。
5. NFS dataを再接続し、Compose projectを復旧する。
6. [受入試験](#acceptance)を再実施する。

snapshot restoreで代替してはならない。この試験はGitとIaCから復旧できることの証明である。

ゲート: 合格日をKubernetes VM 14日保持期間の開始日とする。

**完了（2026-09-06、受入試験12項目すべて合格）。保持期間は2026-09-20に満了する。**
この試験は、Proxmoxのuser・role・API token・ACLがGitにもTerraformにも宣言されていない
手動作成の資産であり、しかも`/vms/<vmid>`のACLがVMのdestroyで道連れに消えることを明らかにした。
**「GitとIaCだけから復旧できる」という前提は現状では成立していない。**
前提条件と403の診断手順は[Apps VM復旧手順](../operations/apps-vm-recovery.md)にある。
恒久対策は未実施で、残作業として[次セッションへの作業指示](next-session.md)が追跡する。

<a id="phase-4-network-migration"></a>

## フェーズ 4: ネットワーク移行

application cutoverの安定後、別のメンテナンス時間帯に実施する。
一括の事前確認は作らず、各対象を変更する直前に必要な値だけを確認する。実施手順と実測値は
[archive/実装状況](archive/implementation-status.md)、ACLの設計と投入手順は
[IX2215 ACL stateful化 実施手順書](../network/ix-acl-stateful-runbook.md)にある。

1. IX2215のstartup/running config、DHCP/ARP、IPv6、port inventoryを確認する。
2. ECW5211のbackupはECW変更直前、Tailscale live exportはTerraform import直前に取得する。
3. Tailscaleの既存ACLとMagicDNSをTerraformへimportし、no-op planを確認する。
4. Server VLAN 10 DHCPを現行`.100-.200`から初期設定用`.250-.254`へ縮小し、
   IPAMのstatic assignmentとlease 0件を確認する。
5. Tailscale gatewayを`.30`から`.102`、ElastiFlowを`.40`から`.103`へ個別に移動する。
   ElastiFlowではsFlow collectorも同じ作業単位で切り替える。
6. Appsの管理IPを`.42`から`.101`へ移動し、その後にserviceを単一`.101`へ集約する。
7. `.101`のDNS/SMB/HTTPSをLANとtailnetから確認してから、Tailscale global DNSを`.101`へ変更し、
   `192.168.11.0/24`の広告を外す。既存exit nodeは維持する。
8. ACLをServer/Trusted/IoT/Guestのstateful policyへ変更する。
9. SSIDをVLAN 20/30/40へ割り当て、AP管理をVLAN 10へ移し、Guest SSIDのclient isolationを有効にする。
10. IPv6 forwarding、RA、DHCPv6が稼働していないことを確認する。
11. access portを1つのuntagged VLAN、PVE/APのtrunkを必要なtagged VLANだけに分け、VLAN 63と
    `default-dhcp`を削除する。port 3/4はServer VLAN 10、空きport 5～7はGuest VLAN 40のaccess portとする。
12. VLAN 11、旧DHCP、旧ACLを削除する。実施時はユーザー判断により14日保持期間の満了を待たず、
    Kubernetes rollbackにはVLAN 11の先行復元が必要になることを記録したうえで2026-09-13に完了した。
13. Apps VM自身のhost resolverをAnsibleで明示管理し、内部FQDNの解決を確認する。

access portに対応するtagged subinterfaceは作らず、tagged frameを別zoneへ転送しない。trunkのuntaggedも
どのzoneにも収容しない。同一物理port上で同じzoneをtagged/untaggedの両方へ収容しない。

ゲート: 各zoneのallow/deny test、LAN/Tailscaleのservice test、Guest isolationが合格すること。
IX/VLAN/ECW部分とApps VM host resolverは2026-09-13に完了した。ElastiFlowの取り込み障害
（[#34](https://github.com/koji-genba/homelab/issues/34)）は2026-07-07からの既存障害で、このゲートの対象外である。

## フェーズ 5: 廃止

**2026-09-23に着手。未完了の項目は下のチェック欄に残す。**
再構築試験から14日経過し、rollbackが発生していないことを条件とする。
合格日は2026-09-06、**保持期間の満了は2026-09-20**である。それ以前に着手しない。
判断が要る点は[次セッションへの作業指示](next-session.md)にまとめてある。

- [x] Kubernetes VM 103 → 102 → 101をProxmoxから削除。disk残存なし（2026-09-23）。
- [x] k8s Terraform、Kubespray、Flux、manifestをactive treeから削除（このブランチ）。
- [x] 旧PVC dataは保持期限とsnapshotを確認してから削除。削除直前に
  `tank-gen2/data/k8s-volumes@pre-phase5-retire-20260923`を追加し、未使用8 directoryを削除。
  現行アプリが使う3 directoryは保持。Phase 2B/3以前のrollback用snapshot 8件は削除し、
  Phase 5直前snapshotだけを保持（2026-09-24）。
- [x] 旧4 NFS exportをApps VM `192.168.10.101/32`へ狭める。`ai` exportはDGX Spark用に
  `192.168.10.0/24`を維持（2026-09-23）。
- [x] 不要なDNS recordとcertificateを削除する。旧LDAP/phpadmin/LDAPS rewriteは定義と
  AdGuard実機から削除（設定backupはApps VMの
  `/etc/homelab/adguard/AdGuardHome.yaml.pre-phase5-20260923`）。3件ともA recordが解決されず、
  現行`prod`の解決が続くことを確認。公開DoHでも旧3件のA recordは空。Caddy保存領域の
  certificateは現行Caddyfileにある7 FQDNだけ（2026-09-23）。
- [ ] 旧Proxmox/Kubernetes/Cloudflare/registry credentialをrotate/revokeする。GitHubの旧Flux専用
  deploy key（ID 156354019）は2026-09-23に失効、key 0件を確認。Proxmoxに旧Kubernetes専用user/ACLは
  なく、GitHub Actionsのカスタムsecretも0件。Caddy専用Cloudflare tokenは作成、権限検証、
  SOPS/Apps VMへの反映、Caddy再作成とHTTPS確認まで完了。旧cert-manager tokenのUI上の失効だけが残る。
- [x] 平文state/secretがGit履歴に混入していないことを再確認する。`make secrets-scan`と
  全branchの履歴中の対象filename・既知token/private key pattern検査に合格（2026-09-23）。
- [x] READMEを現行構成に更新し、recovery runbookへの導線を確認する（このブランチ）。

実機の確認ではApps VMの7 container、8 NFS mount、`homelab-apps.service`とreconcile timerが
稼働していた。旧4 exportの変更前設定はpve1の`/etc/exports.pre-phase5-20260923`に保管した。
旧Kubernetesのcloud-init snippetは参照元を確認して退避した後、2026-09-24に削除した。
Phase 5変更はPR #50でmainへmergeし、Apps VMのreconcile後に稼働commitがmainと一致することを確認した。
同日にstashPad更新をstagingで確認してPR #51でproductionへ昇格し、prod/stagingの実image digest、
health、4つのHTTPS endpointを照合した。

<a id="acceptance"></a>

## 受入試験

**Phase 2B（2026-09-05）とPhase 3（2026-09-06）で、12項目すべて合格した。**
Phase 5の完了確認でも同じ行列を使う。

- [x] stashPad prod/stagingで閲覧、更新、upload、共有mediaを確認する。
- [x] stashPad prod/stagingのmetadataが分離されている。
- [x] SillyTavernでlogin、会話、設定保存を確認する。
- [x] Samba 3 shareを既存userでread/writeできる。
- [x] Trusted LANとTailscaleから既存FQDN/TLSへ接続できる。
- [x] 通常DNS、内部record、block、allowlistが期待どおり応答する。
- [x] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない。
- [x] Apps VM reboot後にmountと全serviceが自動復旧する。
- [x] NFS未mountまたはmarker不一致ならapplicationが起動しない。
- [x] Gatusが障害と復旧をDiscordへ通知する。
- [x] Healthchecks.ioがdead-man停止を通知する。
- [x] running commit/image digestがGit宣言と一致する。
