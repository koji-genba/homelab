# KubernetesからComposeへの移行手順書

- 状態: 実装用ドラフト手順書
- 目標設計: [目標アーキテクチャ](../architecture/target-state.md)

この手順書は停止時間を許容する。一度にapplication runtimeとVLAN設計を変更せず、rollbackの
境界を単純にする。各check欄には実施日時、操作者、結果、関連commitを記録する。

## フェーズ 0: インベントリと安全確認

- [ ] Proxmox VM/LXC、IP、MAC、bridge、VLAN tagを実機から取得し、Git inventoryと照合する。
- [ ] IX2215のrunning/startup configとDHCP leaseを取得する。
- [ ] `.10.42`、`.11.100`、`.11.101`、`.11.103`についてARP/ping/DHCP/Proxmoxの重複を確認する。
- [ ] ECW5211のSSID/VLAN/management IPと接続portを記録する。
- [ ] 現在のcontainer image digest、UID/GID、data容量、file count、ACL/xattrを記録する。
- [ ] 現行FQDN、certificate、Tailscale DNS/route/grantをexportする。
- [ ] 現行secretとcredentialのinventoryを作り、移行後にrotateする対象を記録する。
- [ ] NFS/ZFSが別手順で復旧可能であることを確認する。本runbookではその復旧を実施しない。
- [ ] PVE local consoleまたは確実なout-of-band accessを確保する。

ゲート: inventoryに不明なwriter、IP競合、未記録の必須機能がある場合はフェーズ1へ進まない。

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

## フェーズ 2: 現在のVLANでのアプリケーション切替

### 準備

- [ ] Git mainのcutover commitと全image digestを記録する。
- [ ] 対象datasetのZFS snapshotを取得する。
- [ ] IX2215のVLAN 11 DHCPを停止するか、`.100/.101/.103`を確実に除外する。
- [ ] Flux reconciliationをsuspendする。

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

<a id="phase-4-network-migration"></a>

## フェーズ 4: ネットワーク移行

application cutoverの安定後、別のメンテナンス時間帯に実施する。
一括の事前確認は作らず、各対象を変更する直前に必要な値だけを確認する。進捗と実施手順の詳細は
[次セッションへの作業指示のPhase 4](next-session.md)にある。

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
    `default-dhcp`を削除する。空きport 4～7はGuest VLAN 40のaccess portとする。
12. VLAN 11、旧DHCP、旧ACLを削除する。実施時はユーザー判断により14日保持期間の満了を待たず、
    Kubernetes rollbackにはVLAN 11の先行復元が必要になることを記録したうえで2026-09-13に完了した。
13. Apps VM自身のhost resolverをAnsibleで明示管理し、内部FQDNの解決を確認する。

access portに対応するtagged subinterfaceは作らず、tagged frameを別zoneへ転送しない。trunkのuntaggedも
どのzoneにも収容しない。同一物理port上で同じzoneをtagged/untaggedの両方へ収容しない。

ゲート: 各zoneのallow/deny test、LAN/Tailscaleのservice test、Guest isolationが合格すること。
IX/VLAN/ECW部分は2026-09-13に合格済み。Apps VM host resolverは残作業とする。ElastiFlowの取り込み障害
（[#34](https://github.com/koji-genba/homelab/issues/34)）は2026-07-07からの既存障害で、このゲートの対象外である。

## フェーズ 5: 廃止

再構築試験から14日経過し、rollbackが発生していないことを条件とする。

- [ ] Kubernetes VMを削除する。
- [ ] k8s Terraform、Kubespray、Flux、manifestをactive treeから削除する。
- [ ] 旧PVC dataは保持期限とsnapshotを確認してから削除する。
- [ ] 旧NFS exportをApps VM `/32`だけへ狭める。
- [ ] 不要なDNS recordとcertificateを削除する。
- [ ] 旧Proxmox/Kubernetes/Cloudflare/registry credentialをrotate/revokeする。
- [ ] 平文state/secretがGit履歴に混入していないことを再確認する。
- [ ] READMEとrecovery runbookだけで現行構成を辿れることを確認する。

<a id="acceptance"></a>

## 受入試験

- [ ] stashPad prod/stagingで閲覧、更新、upload、共有mediaを確認する。
- [ ] stashPad prod/stagingのmetadataが分離されている。
- [ ] SillyTavernでlogin、会話、設定保存を確認する。
- [ ] Samba 3 shareを既存userでread/writeできる。
- [ ] Trusted LANとTailscaleから既存FQDN/TLSへ接続できる。
- [ ] 通常DNS、内部record、block、allowlistが期待どおり応答する。
- [ ] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない。
- [ ] Apps VM reboot後にmountと全serviceが自動復旧する。
- [ ] NFS未mountまたはmarker不一致ならapplicationが起動しない。
- [ ] Gatusが障害と復旧をDiscordへ通知する。
- [ ] Healthchecks.ioがdead-man停止を通知する。
- [ ] running commit/image digestがGit宣言と一致する。
