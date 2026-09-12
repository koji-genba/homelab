# 次セッションへの作業指示

- 更新日: 2026-09-12
- 対象リポジトリ: `/home/s-sato/homelab`
- 作業ブランチ: **`docs-phase4-prep`**（`origin/main`から分岐、PR未作成）。mainにはPR #23、#24、#25が
  merge済みである。**この文書にSHAを固定で書かない。** merge のたびに陳腐化して罠になるためである。
  現在地は`git log --oneline origin/main -1`と`git log --oneline origin/main..HEAD`で確認する。
- **2026-09-12時点で、`docs-phase4-prep`にはpush済みのcommitが2件あり、さらに未commitの変更がある。**
  未commitの内容は、Phase 4設計の詳細化（ADR-0003、目標ゾーン設計、移行手順、この文書）、
  `.gitignore`へのrepo直下`/tmp/`の追加、tailscale-gateway rootの`ip_address`変数化である。commit、push、PRはユーザーの指示を受けてから行う。
- 現在地: **Phase 3の再構築性試験を2026-09-06に実施した。** Apps VM（VMID 112）をTerraformで
  destroyし、Terraform・Ansible・Gitから再構築して復旧させた。**Apps VMが唯一のwriterで、
  7 Compose projectが稼働中。** IX2215の構成ドリフトは2026-09-05に解消済み。
  Kubernetes VM 3台は2026-09-05に停止済み（削除はしていない）。
- **受入試験は12項目すべて合格した**（自動確認5項目と、2026-09-06にユーザーが確認した7項目）。
  **Kubernetes VM 14日保持期間は2026-09-06に開始し、2026-09-20に満了する。**
- **Phase 4のネットワーク移行が進行中である。** 段階1（IX2215採取）が完了し、段階2（Tailscale import）は
  ACL整形差分のapply待ちである。詳細は「Phase 4: ネットワーク移行」の「現在地」にある。
  満了日までにrollbackが発生しなければ、その後にPhase 5の廃止へ進む。
- **Phase 3は、Proxmoxのuser・role・API token・ACLがGitにもTerraformにも宣言されておらず、
  しかも`/vms/<vmid>`のACLはVMのdestroyで道連れに消えることを明らかにした。
  「GitとIaCだけから復旧できる」という前提は現状では成立していない。** 詳細は
  [実装状況の「Phase 3: 再構築性の証明」](implementation-status.md)と
  [Apps VM復旧手順の「Terraform実行前のProxmox側準備」](../operations/apps-vm-recovery.md)にある。

この文書は、会話履歴がない次セッションが安全に作業を再開するための指示書である。
進捗の羅列ではなく、ここに記載した順序、ゲート、停止条件に従うこと。

## セッション開始時に必ず行うこと

1. この文書を最後まで読み、次を確認する。
   - [Phase 2A事前調査結果](phase2a-inventory.md) — 実測値、cutover/rollback手順、ユーザー判断
   - [実装状況](implementation-status.md)
   - [KubernetesからComposeへの移行手順](k8s-to-compose.md)
   - [Apps VM復旧手順](../operations/apps-vm-recovery.md)
   - [rollback用 状態スナップショット](k8s-rollback-state.md) — Kubernetes VM停止直前に取得した
     Service定義、replicas、nodeSelector、Flux suspend状態、NFS open stateのベースライン
2. worktreeとbranchを読み取り専用で確認する。protectedなnetwork 2ファイルを触らない。

   ```sh
   git status --short --branch
   git log --oneline --decorate -10
   ```

3. 実機の現在状態を読み取り専用で確認する（後述の「現在のシステム状態」と一致するか）。
4. 次の作業はPhase 4のネットワーク移行である。**「Phase 4: ネットワーク移行」の
   「現在地」と「段階別のゲート」を先に読み、その段階のゲートを満たせないなら破壊的な操作へ進まない。**
   **Phase 1〜3はすべて完了しており、再実施しない。**
   **2026-09-20の満了日まで、Kubernetes VM・disk・PVC・NFS data・ZFS snapshotを削除しない。**
5. Phase 4は複数の独立した破壊的変更の集合である。**一度の窓で全部やろうとしない。**
   後述の段階分けに従い、各段階の後で到達性を確認してから次へ進む。

## 目的とフェーズ境界

- KubernetesをDebian 13の単一Apps VMとDocker Composeへ置き換え、現在の機能を減らさない。
- Proxmoxインストール済みの状態からGit、Terraform、Ansible、Compose、SOPS/ageで再構築可能にする。
- NFS上の既存dataを最優先で保護し、新旧を同時writerにしない。
- VLAN 10/20/30/40への再編（Phase 4）は別windowで行う。application cutoverへ混ぜない。
- **Apps VMの削除・IaC再構築試験（Phase 3）に合格した日から14日間は旧Kubernetes VMを保持する。**
  合格日は2026-09-06であり、**保持期間は2026-09-20に満了する**。
- `stashPadDev`（VMID 111）は作業用VMであり、この移行の対象外とする。

## 絶対に維持する安全条件

**以下は2026-09-06のPhase 3合格後の状態を前提とする。Phase 4で意図的に変更するものを除き、
すべて維持する。**

- **Apps VMが唯一のwriterである。Kubernetes側のworkloadを再開させない。**
  Flux Kustomization 4件はsuspend、対象Deployment 6件はreplicas=0、MetalLB speakerは停止、
  3つのLoadBalancer ServiceはClusterIP化されている。この状態を維持する。
- **Kubernetes VM 101/102/103は2026-09-05に停止した。削除はしていない。**
  Phase 3は2026-09-06に合格したため、**2026-09-20の満了日まで**VM、disk、PVC、NFS data、
  ZFS snapshotのいずれも削除しない。**rollback以外の目的でVMを起動しない。**
  起動した場合も、Fluxをresumeせず、Deploymentをscale upせず、ServiceをLoadBalancerへ戻さない。
- 次のAnsible flagは現在の値を維持する。`network_migration_complete`をtrueにしない。
  - `legacy_service_addresses_enabled: true`
  - `legacy_service_cutover_confirmed: true`
  - `application_cutover_confirmed: true`
  - `network_migration_complete: false`
- Tailscaleはlive設定の完全なexport、review、importが終わるまで`manage_tailnet=false`を維持する。
  global nameserverの実機値は`192.168.11.101`であり、Terraform変数`final_apps_ip`の
  `192.168.10.101`はPhase 4の期待値である（`variables.tf`のvalidationでこの値に固定されている）。
  **Apps VMが`192.168.10.101`で稼働を始める前に`enable_adguard_dns=true`でapplyすると、
  tailnet全体のDNSが即座に解決不能になる。**
- **`files/infrastructure/terraform/tailscale/`にはstateが存在しない。** このrootは一度も
  applyもimportもされていない。他のroot（apps-vm、tailscale-gateway、elastiflow、
  stashpad-dev、k8s-cluster）にはstateがある。**いきなりapplyせず、importから始める。**
- Apps VMのcloud-init warning履歴を消す目的で`cloud-init clean`やreinitを行わない。
- Terraform planにVMID 112のreplace、想定外resource、Apps VM以外の変更が出たらapplyしない。
- secret、API token、age秘密鍵、復号済み設定、Terraform stateの実値を会話、ログ、Git、tfvarsへ出力しない。
- ZFS snapshot `@pre-compose-cutover-20260905`と`@pre-phase3-20260906`（各4 dataset）を、
  Kubernetes VMの14日保持期間が満了するまで削除しない。
- **Apps VMを再びdestroyする場合は、applyの前にProxmoxのACL `/vms/112`を再付与する。**
  Proxmoxはdestroy時に`/vms/<vmid>`のACLをVMと一緒に削除するため、そのままapplyすると
  `HTTP 403 Permission check failed`で失敗する。2026-09-06に実際に発生した。手順は
  [Apps VM復旧手順の「Terraform実行前のProxmox側準備」](../operations/apps-vm-recovery.md)にある。

## 現在のシステム状態（2026-09-06 再確認、Phase 3再構築後）

### Apps VM（VMID 112、`192.168.10.101`）

- 7 Compose projectがすべて稼働。`homelab-apps.service`は`active`。

  | project | container | 状態 |
  | --- | --- | --- |
  | edge | `homelab-edge-caddy-1` | healthy |
  | dns | `homelab-dns-adguard-1` | 稼働 |
  | samba | `homelab-samba-samba-1` | healthy |
  | stashpad-prod | `homelab-stashpad-prod-stashpad-prod-1` | healthy |
  | stashpad-staging | `homelab-stashpad-staging-stashpad-staging-1` | healthy |
  | sillytavern | `homelab-sillytavern-sillytavern-1` | 稼働 |
  | monitoring | `homelab-monitoring-gatus-1` | 稼働 |

- `ens19`に`192.168.11.100/24`、`192.168.11.101/24`、`192.168.11.103/24`を保持。
  `eth0`は管理用`192.168.10.101/24`（2026-09-12にPhase 4で`.42`から変更）。
- NFS 7 mountのうち`stashpad-media`だけが`ro`、他6つが`rw`。これが正しい状態である。
- `/opt/homelab`は`origin/main`のcleanなcheckoutである。`homelab-app-reconcile.timer`は
  enabled/activeで、15分間隔でmainへfast-forwardする。**Compose定義に差分が無ければ
  containerは再作成されない**（PR #21で、bind mountしたファイルだけが変わった場合に
  選択projectをforce-recreateするよう修正済み）。追従先の確認は
  `git -C /opt/homelab rev-parse HEAD`を`origin/main`と突き合わせる。
- 稼働中imageのdigestはGit宣言と7/7一致している。
- **2026-09-06のPhase 3で再構築されたVMである。** 次の値が変わった。
  - NICのMAC。`net0`（eth0、VLAN 10）が`BC:24:11:D7:47:A2`、`net1`（ens19、VLAN 11）が`BC:24:11:2E:FB:64`。
    旧値はそれぞれ`BC:24:11:9E:9B:29`と`BC:24:11:84:F3:EA`である。
  - SSH host key。現在の値は`SHA256:9U1BvsqDUUQASaGfCqLSei5HdOV17gkNUsUa1ahEpys`で、
    QEMU guest agent経由と`ssh-keyscan`の2経路で一致を確認して`known_hosts`へ登録した。
  - TLS証明書。Let's Encryptから再取得された（`prod.stashpad`の有効期限は2026-12-05）。
- Apps VMへのSSHは`deploy@192.168.10.101`である（`files/infrastructure/ansible/apps/inventory/hosts.yml`の
  `ansible_user`）。秘密鍵の指定はなく、既定の`~/.ssh/id_ed25519`とssh-agentに委ねる設計である。
- GatusのCaddy probeは`HTTP 308`を成功として観測している。PR #20の設定変更は、旧bind mount inodeを
  保持したcontainerを手動でforce-recreateして反映した。PR #21のreconcile/rollback修正もAnsibleで
  Apps VMへ反映済みである。
- NFS server側のopen stateは、Apps VMがstashPad prod/staging DBのrw openを保持する一方、
  Kubernetes worker 2台に残るのは旧Unboundの`hagezi-pro.txt`に対するread-only openだけである。
  想定外のwriterは観測されていない。VM停止後もworker 2台のentryは`states`に残るが、
  `info`の`status`が`courtesy`へ遷移しており、これはLinux nfsdのcourteous serverによる
  最大24時間の保持である。詳細は後述の「Kubernetes VM停止後のNFS open state」を参照。
- **Apps VM自身のhost resolverでは`*.kojigenba-srv.com`を解決できない。** `systemd-resolved`の
  `eth0` uplinkが`192.168.10.1`（53をrefuse）と`1.1.1.1`（内部record非保持）のためである。
  Kubernetes停止とは無関係の既存事象で、実害は現時点でない。host側でFQDNを扱う確認は
  `192.168.11.101`を明示指定するか`curl --resolve`を使うこと。

### Kubernetes（VM停止済み）

- **VM 101/102/103は`stopped`である。** 2026-09-05にworker → control planeの順
  （103 → 102 → 101）で`qm shutdown --timeout 180`を実行し、guest agent応答により3台とも
  クリーンに停止した。強制停止（`qm stop`）は使っていない。VMもdiskも削除していない。
- 以下のKubernetes側の状態は、VM停止前に確認した最終値である。rollbackで起動した際の
  前提として保持する。完全な値は[rollback用 状態スナップショット](k8s-rollback-state.md)にある。
- Flux Kustomization `stashpad-prod` `stashpad-staging` `sillytavern` `flux-system` はsuspend。
- CronJob `external-dns/blocklist-updater` はsuspend。
- Deployment 6件（stashpad prod/staging、sillytavern、samba、external-unbound、
  ingress-nginx-controller）は`replicas=0`。
- DaemonSet `metallb-speaker` は`nodeSelector`に`homelab.io/metallb: disabled`を追加して停止。
  **元の値は`{"kubernetes.io/os":"linux"}`である。**
- 3つのServiceはtypeを`ClusterIP`へ変更済み。rollback用に`spec.loadBalancerIP`を固定してある。

  | Service | namespace | 固定IP |
  | --- | --- | --- |
  | `ingress-nginx-controller` | ingress-nginx | `192.168.11.100` |
  | `external-unbound-dns` | external-dns | `192.168.11.101` |
  | `samba-smb` | samba | `192.168.11.103` |

  変更前後の完全なService定義JSONは[rollback用 状態スナップショット](k8s-rollback-state.md)へ
  恒久保存済みである。Kubernetes VM停止後は`kubectl`が使えないため、そちらを参照すること。
- Unboundは、PVC上の`rpz/hagezi-tif.txt`が不正なためscale upするとCrashLoopする。
  **かつて記録していた「旧ReplicaSet `external-unbound-588bcf9d7c`（revision 129）が正常な世代」は誤りである。**
  当該ReplicaSetはすでに存在せず、現存する11件はpod templateが完全に同一である。詳細と正しい復旧手順は
  [rollback用 状態スナップショット](k8s-rollback-state.md)にある。

### ネットワーク

- 管理端末のTailscaleは、Apps VM停止中にtailnet DNSへ依存しないようユーザーが切断済み。
  作業はApps VM `192.168.10.42`とPVE `192.168.10.11`へのLAN直指定で実施した。
- IX2215のBVI11は`192.168.11.1/24`。2026-09-05にユーザーが`/25`から`/24`へ修正し、
  `write memory`でstartup-configへ保存済みである。
- `interface BVI11`の`ip dhcp binding server_app-dhcp`を解除済み。2026-09-05にユーザーが
  `write memory`を実行し、解除後のrunning-configをstartup-configへ保存した。
- VLAN 11のDHCP leaseは解除前から0件で、影響を受けるclientはない。
- `vmbr0.11`は`192.18.11.11/24`のまま（記録のみ、修正しない）。
- **Apps VMはTailscaleノードではない。** 2026-09-06に実測で確認した。`tailscale`コマンドも
  `tailscaled`も存在せず、`100.x`のアドレスも持たない。tailnetに居るのは別VMの
  `tailscale-gateway`（VMID 105、`192.168.10.30`、VLAN 10。**tailnet上のhostnameは
  `home-gateway`**でありPVEのVM名とは異なる）であり、これがsubnet routerとしてLANを代理している。
- **したがって、外部からSMB・HTTPS・DNSへ届くための唯一の経路は
  `home-gateway`のAdvertiseRoutesである。** 現行の広告は`0.0.0.0/0`、`::/0`、
  `192.168.10.0/24`、`192.168.11.0/24`の4件である。
  **`192.168.10.0/24`と`192.168.11.0/24`を外すと、tailnet越しに宅内サービスへ到達できなくなる。**
  名前解決はAdGuardが担うのでDNSは成功し続け、接続だけがtimeoutするという分かりにくい壊れ方をする。
- **exit node（`0.0.0.0/0`、`::/0`）はsubnet routeの代替にならない。** exit nodeはclientが
  明示的に選択したときだけ全traffic を流す機能であり、常用の接続でLAN宛が流れるわけではない。

### ZFS snapshot

cutover直前に4 datasetへ`@pre-compose-cutover-20260905`を、Phase 3のdestroy直前に
同じ4 datasetへ`@pre-phase3-20260906`を取得済み。**どちらも14日保持期間の満了まで削除しない。**

- `tank-gen2/data/k8s-volumes`（それまでsnapshot 0件）
- `tank-gen1/data/archive`（それまでsnapshot 0件）
- `tank-gen2/data/shared`
- `cache-pool`（mergerfsのcache branch。HDD側datasetのsnapshotだけでは直近の書き込みを保護できない）

pve1のroot crontabにある`/usr/local/bin/mover.sh`（05:00）は`tank-gen2/data/shared`のみを
対象とする自家製snapshot/tieringである。cutover後も運用を継続する。

## 次に行う作業

**1〜4はすべて完了済みの記録である。再実施しない。次の作業は
[5のPhase 4](#5-phase-4-ネットワーク移行次作業)である。**

1〜4は進捗の羅列ではなく、**今後も守るべき手順と、繰り返してはならない失敗の記録**である。
特に次はPhase 4で直接使うので読み飛ばさないこと。全経緯は
[実装状況](implementation-status.md)にある。

- **2のIX2215のACL編集手順。** Phase 4のACL再編でそのまま使う。
- **3のNFS courtesy stateの扱い。** 想定外のwriterと見誤らないため。
- **4の再びApps VMをdestroyする場合の注意と、Proxmox権限がIaCの外にあること。**
  Phase 4のApps VM IP変更でTerraform applyを行うため、403の診断手順を知っておく必要がある。

### 1. 受入試験の結果（合格、2026-09-05）

自動確認できる範囲は合格済みである（7 FQDNのTLS、DNSの通常応答・内部record・ブロック、
stashPad prod/stagingの`200`、SillyTavernの`401`、SMB 445の到達性、image digestの一致）。

2026-09-05にユーザーが次の完了を申告した。

- 7 FQDN（`prod.stashpad.kojigenba-srv.com`、`staging.stashpad.kojigenba-srv.com`、
  `prod.kojigenba-srv.com`、`staging.kojigenba-srv.com`、`sillytavern.kojigenba-srv.com`、
  `dns.kojigenba-srv.com`、`status.kojigenba-srv.com`）の動作確認
- IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない隔離テスト

ユーザーの確認が必要な項目。

- [x] stashPad prod/stagingで閲覧、更新、upload、共有mediaを確認する（2026-09-05、ユーザー確認）
- [x] stashPad prod/stagingのmetadataが分離されている（2026-09-05、ユーザー確認）
- [x] SillyTavernでlogin、会話、設定保存を確認する（2026-09-05、ユーザー確認）
- [x] Samba 3 shareを既存userでread/writeできる（2026-09-05、ユーザー確認）
- [x] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない（2026-09-05、ユーザー確認）

サービス断を伴うため実施タイミングの合意が必要な項目。

- [x] Apps VM reboot後にmountと全serviceが自動復旧する（2026-09-05 21:28、boot ID変更、failed unit 0）
- [x] NFS未mountまたはmarker不一致ならapplicationが起動しない（2026-09-05、mount namespace内で確認）

発火させないと確認できない項目。

- [x] Gatusが障害と復旧をDiscordへ通知する（2026-09-05、Caddy/Public TLS certificateの障害・resolved通知をDiscordで受信確認）
- [x] Healthchecks.ioがdead-man停止を通知する（2026-09-05、DOWN/UP通知をDiscordで受信確認）

### 2. IX2215構成ドリフトの解消（完了、2026-09-05）

BVI11の`ip address`を`192.168.11.1/25`から`/24`へ変更し、ACL 3本（`server_app-out`のsrc、
`default-out`と`guest-out`のdest）の`192.168.11.0/25`を`/24`へ更新した。`write memory`まで完了し、
`files/infrastructure/network/`の2ファイルは実機のrunning-config全文と照合済みである。
**実施内容と照合結果の全記録は[実装状況の「IX2215構成ドリフトの解消」](implementation-status.md)にある。
ここには、今後IX2215を触る際に必ず守るべき事項だけを残す。**

**再発防止のため、IX2215のACL編集手順として次を必ず守ること。**

IX2215のACLは投入順に末尾追加され、エントリ単位のシーケンス番号や途中挿入の構文がない。
そのため個別エントリを`no`で消して再投入すると、末尾の`permit ip src any dest any`の後ろに
回り、永久に評価されなくなる。今回の作業でも`default-out`と`guest-out`でこれが発生し、
VLAN 63 → VLAN 11とGuest VLAN 40 → VLAN 11のdenyが一時的に無効化された。変更前は`/25`のdenyが
`permit any`より前にあって有効だったため、一時的にcutover前より弱い状態を作ってしまった
（`server_app-out`は最初から下記の正しい手順で投入したため影響なし）。ACLエントリを書き換える
際は必ず次の順序で行う。

1. 対象インターフェースから`ip filter`のバインドを外す。
2. `no ip access-list <名前>`でリストごと削除する。
3. `option optimize`を先頭に、正しい順序で全エントリを再投入する。
4. `ip filter`を再バインドする。

フィルタを先に外すのは、空または未定義のACLを`ip filter`が参照した場合の挙動をNEC公式資料で
確認できなかったため、無フィルタ＝素通りという既知の状態に倒して通信断を避ける意図である。

**`config.txt`を実機と照合する際の注意。** `config.txt`は日本語の注釈が付いた記録であり、
`show running-config`の逐語dumpではない。内容は実機と一致するが、blockの並び順が3箇所で異なる
（`device GigaEthernet2`内のsflowとvlan-groupの順、`interface GigaEthernet2.0`の位置、
`interface GigaEthernet2:1.0`から`2:6.0`までの位置）。**行の並びではなく行の集合として比較すること。**
並び順の差分を「ドリフト」と誤認して`config.txt`を書き換えない。

### 3. Kubernetes VMの停止（完了、2026-09-05）

**削除はしていない。停止だけである。** Phase 3の再構築試験に合格するまで、VMもdiskもPVCも
NFS dataも消さない。実施内容と確認結果の全記録は
[実装状況の「Kubernetes VMの停止」](implementation-status.md)にある。

- [x] 停止前に、Apps VMの7 Compose projectが正常であることを確認する（2026-09-05、全項目合格）
- [x] 停止前にrollbackへ必要な値を[状態スナップショット](k8s-rollback-state.md)へ恒久保存する
- [x] pve1（`192.168.10.11`）でVMID 103 → 102 → 101を`qm shutdown --timeout 180`で停止する
      （2026-09-05、guest agent応答により3台ともクリーン停止。`qm stop`は不要だった）
- [x] 停止後にApps側の7 FQDN、DNS応答、SMB到達性を再確認する
      （2026-09-05、停止前と完全に同一の結果）
- [x] NFS serverの`/proc/fs/nfsd/clients/*/states`を確認する（2026-09-05、後述の通り想定と異なるが正常）

停止によりrollbackの所要時間が延びた。rollbackが必要になった場合は、
下記のrollback手順を実行する前にKubernetes VMを起動し、nodeがReadyになるまで待つこと。

#### Kubernetes VM停止後のNFS open state

停止後もworker01/02のclient entryと`rpz/hagezi-pro.txt`へのread-only openが`states`に残る。
**これは正常であり、対処しない。** `/proc/fs/nfsd/clients/<id>/info`の`status`が`confirmed`から
`courtesy`へ遷移しており、Linux nfsdのcourteous serverがread openやdelegationしか持たないclientを
最大24時間保持する仕様によるものである。worker01は停止前からすでに`courtesy`だった。

| client | `status` | open |
| --- | --- | --- |
| `192.168.10.42` apps | `confirmed`、callback UP | stashPad prod/staging DBのrw open + write delegation 計20件 |
| `192.168.10.22` k8s-worker01 | `courtesy` | `rpz/hagezi-pro.txt`へのread-only open 6件 |
| `192.168.10.23` k8s-worker02 | `courtesy` | `rpz/hagezi-pro.txt`へのread-only open 4件 |

**`/proc/fs/nfsd/clients/<id>/ctl`へ書き込んで強制expireしないこと。** 24時間以内に自然消滅する。
`states`から消えたことの確認はPhase 3の作業時に行えばよい。write openを持つのはApps VMだけであり、
「新旧が同時にwriterになりうる状態」は観測されていない。

### 4. Phase 3: 再構築性の証明（2026-09-06、全項目合格）

**実施済みであり、受入試験12項目すべてに合格した。再実施しない。**
Apps VM（VMID 112）をTerraformで実際にdestroyし、Terraform・Ansible・Gitから再構築して
復旧させた。snapshot restoreは使っていない。
**合格日2026-09-06からKubernetes VM 14日保持期間が始まり、2026-09-20に満了する。**
実測値と全経緯は[実装状況の「Phase 3: 再構築性の証明」](implementation-status.md)にある。
ここには、次セッションが知っておくべき結論だけを残す。

#### 結果の要約

- destroy対象は宣言どおりの3 resourceのみだった（`proxmox_virtual_environment_vm.apps`、
  `proxmox_virtual_environment_file.cloud_config`、`proxmox_download_file.debian_cloud_image`）。
  VMID 112以外は巻き込まれていない。Kubernetes VMのdiskも無傷である。
- 再構築後、7 Compose projectが稼働し、image digestはGit宣言と7/7一致、`/opt/homelab`は
  `origin/main` `e272c75`のclean checkoutである。
- 自動確認できる受入項目はすべて合格した。DNSの4種（通常解決、内部rewrite、block、allowlist）、
  7 FQDNのTLS、SMB 445、mount guardのfail-closed、reboot後の自動復旧、image digestの一致である。
- TLS証明書はLet's Encryptから**再取得**された。Cloudflare DNS-01によるACME経路が
  IaCだけから復元されることを示している。
- NFS serverでwrite openを持つclientはApps VMだけである。

#### この試験が明らかにした欠陥（次に手を打つべきもの）

**Proxmoxのuser `terraform@pve`、role `HomelabTerraform`、API token `terraform@pve!apps-vm`、
7つのACL pathは、GitにもTerraformにも宣言されていない手動作成の資産である。**
しかも`terraform destroy`でVMを削除すると、Proxmoxが`/vms/<vmid>`のACLをVMと一緒に削除する。
2026-09-06はこれにより再構築の1回目が`HTTP 403 Permission check failed`で失敗し、
ユーザーがpve1で`pveum acl modify /vms/112 --user terraform@pve --role HomelabTerraform`を
実行して復旧させた（削除前と同一スコープ、権限拡大なし）。

したがって「Proxmoxインストール済みの状態からGitとIaCだけで再構築できる」という
[目的とフェーズ境界](#目的とフェーズ境界)の前提は、**現状では成立していない。**
前提条件・投入コマンド・403の診断手順は
[Apps VM復旧手順の「Terraform実行前のProxmox側準備」](../operations/apps-vm-recovery.md)へ明文化した。
**恒久対策（Proxmox側の権限をTerraformまたは冪等なスクリプトで宣言する）は未実施であり、
Phase 4以降で扱う課題として残っている。**

#### ユーザー確認7項目（2026-09-06、すべて合格）

管理端末のTailscaleを再接続したうえで、ユーザーが次を確認して合格を申告した。

- [x] stashPad prod/stagingで閲覧、更新、upload、共有mediaを確認する
- [x] stashPad prod/stagingのmetadataが分離されている
- [x] SillyTavernでlogin、会話、設定保存を確認する
- [x] Samba 3 shareを既存userでread/writeできる
- [x] Tailscaleから既存FQDN/TLSへ接続できる
- [x] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない
- [x] GatusとHealthchecks.ioのDiscord通知が届いている
      （試験中の断で発火した。`homelab-healthchecks-ping.service`が12:30:55に失敗し
      12:32:02に成功へ復帰したことも観測済みで、復帰後のfailed unitは0件である）

**これで受入試験12項目すべてが合格し、2026-09-06が14日保持期間の開始日となった。**

#### 再びApps VMをdestroyする場合の注意

Phase 3は合格見込みだが、将来同じ操作を行う場合は次を必ず守る。実測で確認した事項である。

- **applyの前にProxmox ACL `/vms/112`を再付与する**（前述）。
- **`make`にdestroy targetは存在しない。** toolbox経由で
  `terraform -chdir=files/infrastructure/terraform/apps-vm destroy`を手動実行する。
  Makefileの`TOOLBOX_PROXMOX_RUN`と同じ呼び出しを再現すること。
- **destroyの前にDebian cloud imageのURLが生きていることを確認する。**
  `proxmox_download_file`はdestroyでimageも消すため、URLが失効していると再構築できない。
  2026-09-06はpve1から`200`と`Content-Length` 340262912を確認してから実行した。
- **destroyの前にwriterを解放する。** `homelab-apps.service`、`homelab-app-reconcile.timer`、
  `homelab-service-addresses`を停止し、NFS 7 mountをumountすると、NFS serverの
  `/proc/fs/nfsd/clients/`からApps VMのclient entryごと消える。ここまでやって初めて
  rw openとwrite delegationが完全に0になる。停止だけではmarkerへのread delegationが8件残る。
- **`ssh-keygen -R 192.168.10.42`で古いhost keyを消す。** 2026-09-06時点では
  `known_hosts`に3エントリあった（**かつて「25・26行目」と記録していたが、実際は25・26・27行目だった**）。
  新しい鍵はQEMU guest agent経由と`ssh-keyscan`の2経路で一致を確認してから登録する。
- `make state-backup-preflight`には`AGE_RECIPIENT`、`AGE_IDENTITY_FILE`、`SSH_AUTH_SOCK`が要る。
  `AGE_RECIPIENT`は`files/infrastructure/secrets/runtime.sops.yaml`のヘッダにある公開recipient、
  `AGE_IDENTITY_FILE`は`~/.config/sops/age/keys.txt`でよい。ssh-agentは起動して鍵を登録しておく。
- `proxmox_api_token`だけはユーザーしか供給できない。`terraform.tfvars`（`.gitignore`対象、mode 0600）か
  `TF_VAR_proxmox_api_token`のexportで与える。**destroyの前に`terraform plan`が実機をrefreshできることで
  token有効性を確認する。**

#### 再構築しても変わらないもの

Apps VMのhost resolverが`*.kojigenba-srv.com`を解決できない件は、Terraformの
`dns_servers`既定値が`["192.168.10.1", "1.1.1.1"]`であることに由来する宣言どおりの結果であり、
ドリフトではない。**直そうとしないこと。** 解消はPhase 4の
`192.168.10.101`集約とglobal nameserver変更で行う。

#### 失敗したとき

Kubernetes VM 101/102/103を起動し、nodeがReadyになるのを待ってから
後述のrollback手順を実行する。VMもdiskもPVCもNFS dataも残っている。


### 5. Phase 4: ネットワーク移行（作業中）

**この節がPhase 4の進捗と手順の唯一の情報源である。** 他の文書へ進捗を書かない。設計の根拠は
[ADR-0003](../adr/0003-four-network-zones.md)、目標状態は[目標ゾーン設計](../network/target-zones.md)、
手順の骨子は[移行手順書のフェーズ4](k8s-to-compose.md)にある。実施した手動変更の最終記録だけは
目標ゾーン設計末尾の「手動変更記録」へ書く。

影響を受けるのは宅内のユーザー1人だけである。短時間の停止は許容し、各段階の後に実際の疎通で
確かめて進める。全段階を1つの窓でやろうとしない。

#### 現在地（2026-09-12）

| 対象 | 状態 |
| --- | --- |
| IX2215の採取 | 完了（2026-09-06）。console loginも確認済み |
| ECW5211 | 完了。management VLAN tagged 10、SSID→VLAN 20/30/40、station isolation、config backup |
| Tailscale import | 完了（2026-09-12）。ACLとMagicDNSをimportし、整形差分をapply済み。state-backup取得済み |
| 実機のnetwork変更 | DHCP縮小、VM 3台のrenumber、Apps serviceの`.10.101`集約、Tailscale nameserver切替が完了（2026-09-12） |
| `.11.0/24`広告の撤去 | 完了（2026-09-12） |
| 残り | IX ACL再編、untaggedのGuest化、VLAN 11撤去、受入試験 |

次にやること: 下の「残りの手順」の8（IX2215のstateful ACL再編）から。Phase 4で唯一、事前にoffline手順書を作る段階である。

#### 残りの手順

各段階の後に疎通を確認し、問題があればその段階だけを戻す。

1. **Tailscale import。** 完了（2026-09-12）。ACLとMagicDNSをimportし、整形差分をapplyした。
   live policyは`acl-policy.live.json`と一致し、stateは暗号化してstate-backupブランチへ退避済み。
2. **Server DHCP poolの縮小。** 完了（2026-09-12）。`server-dhcp`は`.250-.254`、lease 3600秒、0 clients。
   このとき`default-dhcp`（VLAN 63）が0 clientsであること、`server_app-dhcp`（VLAN 11）がどのBVIにも
   bindされていないことも確認できた。段階9と10はこの分だけ軽い。
3. **Tailscale gatewayを`.102`へ。** 完了（2026-09-12）。**guestには一切手を入れず、Terraformだけで
   完結した。** 確立した手順は次のとおりで、段階4と5も同じでよい。

   1. rootの`ip_address`（Apps VMは`management_ip`）の既定値を最終IPへ変更する。
   2. `reboot_after_update = true`をVM resourceに明示する。
   3. `make terraform-plan TERRAFORM_ROOT=<root>`。**VMが`update in-place`であること**を確認する
      （cloud-init snippetの`must be replaced`は正常。同名で作り直され、VM側は`ignore_changes`で無視する）。
   4. `make terraform-apply TERRAFORM_ROOT=<root>`。providerがPVE経由で再起動し、cloud-initが
      新しいinstance-idを見てnetplanを描き直すので、guestのIPが切り替わる。
   5. 新IPで疎通、機能、再起動後の状態を確認し、最後に`make terraform-plan`で`No changes.`を見る。

   gatewayでは所要数分でtailnetのnode IP（`100.90.37.109`）、AdvertiseRoutes、exit node、`ip_forward`が
   すべて維持された。**再起動でSSH host鍵が作り直される**ので`ssh-keygen -R <旧IP>`が要る。
   cloud-initのruncmdが再実行され`/etc/sysctl.conf`のip_forward行が重複するが無害である。
4. **ElastiFlowを`.103`へ。** 完了（2026-09-12）。段階3と同じ手順で、planは`0 added, 1 changed,
   0 destroyed`だった（user-dataに差分が無くsnippetのreplaceも無し）。`/etc`に旧IPの直書きは無く、
   Elasticsearchは`0.0.0.0`、Kibanaは`0.0.0.0`、flowcollは`*:6343`で待ち受けていたため、
   IP変更でserviceは壊れなかった。IXの`sflow collector`を`.103`へ変更し、実際にsFlowv5の着信を確認済み。
   Kibanaは`http://192.168.10.103:5601`になった。
5. **Apps VMの管理IPを`.10.101`へ。** 完了（2026-09-12）。段階3と同じ手順で`0 added, 1 changed,
   0 destroyed`。再起動後、`eth0`は`.101`、`ens19`の`.11.100/.101/.103`は`homelab-service-addresses`
   unitが付け直し、NFS 7本と全7コンテナが自動復帰した。NFS exportは`192.168.10.0/24`単位なので
   export側の変更は不要だった。Ansibleの`ansible_host`と`apps_management_ip`、運用文書の参照も`.101`へ
   更新済み。なおこのVMはICMPを塞いでいるのでpingでの死活確認はできない（SSHで確認する）。
6. **Apps serviceを`.10.101`へ集約。** 完了（2026-09-12）。group_varsの3フラグを同時に反転した
   （`network_migration_complete=true`、`legacy_service_addresses_enabled=false`、
   `legacy_service_cutover_confirmed=false`）。`make ansible-apply`は`failed=0`で、`ens19`から
   `.11.x`が外れ、Caddy・AdGuard・Sambaが`.10.101`の443/53/445へ移った。AdGuardのrewriteも
   `.10.101`を返す。`prod.kojigenba-srv.com`はHTTP 200。
   **`make ansible-apply`には`AGE_IDENTITY_FILE`が要る**（SOPSの復号がcontroller側で走るため）。
   最初これを忘れてfirewallだけ適用された中途半端な状態で止まった。
7. **Tailscale nameserverの切り替え。** 完了（2026-09-12）。`tailscale-import-dns`でimportし、
   planは`nameservers`が`192.168.11.101 -> 192.168.10.101`の1件だけだった。apply後、tailnet経由の
   名前解決をユーザーが確認済み。あわせて`192.168.11.0/24`の広告も外した。gateway VMで
   `sudo tailscale set --advertise-routes=192.168.10.0/24 --advertise-exit-node`を実行し、
   Terraformの`advertised_routes`既定値も揃えてある。**ノードが広告するrouteはguestのprefsで、
   Terraformの`advertised_routes`はcontrol plane側の承認リストなので層が別である**
   （[#29](https://github.com/koji-genba/homelab/issues/29)）。
   `192.168.10.0/24`の広告は残す。Apps VMはtailnetノードではないため、宅外からのSMB/HTTPS/DNSと
   global nameserver `.10.101`への到達がこのrouteに依存している。hairpinはclient側の`accept-routes`で
   制御する（構造的な代替案は[#30](https://github.com/koji-genba/homelab/issues/30)）。
8. **IX2215のstateful ACL再編。** Phase 4で唯一、事前にofflineの手順書（投入・確認・rollbackコマンドと
   期待出力）を用意する段階である。現行ACLはTrusted→ServerとServer→Trustedをstatic permitしている
   だけでstatefulではない。逆方向のpermitを単に消すと応答も落ちるので、動的フィルタを入れてから
   逆方向の新規接続をdenyする。
9. **untaggedのGuest化とVLAN 63の撤去。** port 2/3以外のuntagged（`GigaEthernet2.0`と
   `GigaEthernet2:6.0`）をbridge-group 63から40へ移し、BVI63、`default-dhcp`、`default-out`を削除する。
   VLAN 63はKubernetesのrollback経路ではないので保持期間を待たない。変更後にGuest SSIDの疎通と、
   Guest clientのMACがflapしないことを見る。
10. **VLAN 11の撤去。** 2026-09-20の保持期間満了後、rollbackが無ければ撤去する。
11. **受入試験。** 各zoneのallow/deny、LAN/tailnetからのservice、Guest isolation。結果を
    [目標ゾーン設計](../network/target-zones.md)の「手動変更記録」へ記入する。

#### 変更直前に見るものだけ

一括のpreflightは作らない。その変更の入力とrollbackに要る値だけを直前に確認する。

| 変更 | 直前に見る |
| --- | --- |
| IXのDHCP縮小 | `show ip dhcp profile`でServer leaseが0件 |
| IXのIP関連変更 | `show arp entry`と`show ip dhcp lease`に対象IPがない |
| sFlow collector変更 | `show sflow information`の現行collector |
| IXのACL/管理制限 | consoleでloginでき、未保存変更をreloadで戻せる |
| VMのIP変更 | `qm config`/`qm status`、対象VMだけのplan、PVE console、新IPが未使用 |
| Tailscale DNS/route | 変更対象のlive値と、変更後の疎通 |

変更後に確認するのは対象機能だけでよい。Tailscaleならroute/exit node、ElastiFlowならsFlow受信、
AppsならSSH/DNS/HTTPS/SMBである。予防的な全service inventoryは作らない。

#### 採取済みの事実（再採取しない）

IX2215（2026-09-06、`tmp/ix/`）:

- software `10.11.6`。running-configはstartup-configと一致し保存済み。
- Server DHCP poolは`.100-.200`でlease 0件。`.10.101-.103`はARPにもDHCPにも無い。
- IPv6 routeもneighborも0件で、BVI/WANにIPv6 addressは無い。
- sFlowは`.10.40:6343`へ送信中、drop/errorは0。
- `tmp/ix/startup-config.txt`は認証hashを含むsession logで、復元元として使えるがそのままupload
  できるfileではない。Gitへは追加しない。

GE2の物理port:

| port | 接続先 | untagged | tagged |
| ---: | --- | --- | --- |
| 1 | pve1 | VLAN 63 | 10/11（group 6） |
| 2 | 管理端末 | VLAN 20 | なし |
| 3 | DGX Spark `.10.51` | VLAN 10 | なし |
| 4-7 | 未使用 | VLAN 63 | 10/11（group 6） |
| 8 | ECW5211-L `.10.2` | VLAN 63 | 10/11/20/30/40 |

port 8はvlan-group外なのでdefaultのサブIFに属し、ECWに必要なtaggedはすでに届いている。全VMのNICと
PVE host（`vmbr0.10`）はtaggedなので、untaggedのGuest化の影響を受けない。

Tailscale（2026-09-12）:

- live policyは`acl-policy.live.json`（整形済みJSON、Git管理外）。コメント付きの原本HuJSONは
  `tmp/tailscale/acl_json`にある。top-levelは`groups`/`acls`/`ssh`だけで、`autoApprovers`も
  `tagOwners`も無い。`acls`の先頭が`*`→`*:*`の全許可で、残り2件はそれに包含される。policyの
  見直しはPhase 4に含めない。
- MagicDNS有効、global nameserverは`.11.101`、Override DNS servers有効、Split DNSとsearch domainなし。
- **Override DNSが有効なので、tailnetに接続中の全clientは`.11.101`をDNSに使う。** `.11.101`を止める
  前にnameserverを`.10.101`へ変える順序を崩さない。
- ACLはimport後Terraformの管理下にある。Admin Consoleで直接編集せず、`acl-policy.live.json`を
  編集してplan/applyする。

3 VM（2026-09-06）: Apps 112 `.10.42`、Tailscale 105 `.10.30`、ElastiFlow 110 `.10.40`。いずれも
systemd-networkd + Netplan、NoCloud seedである。

Git管理外のローカルfile（機微情報を含むものはmode `0600`）:

| path | 内容 |
| --- | --- |
| `tmp/ix/` | IX2215のstartup-configと採取log（認証hashを含む） |
| `tmp/ecw/config-backup.conf` | ECW5211のconfig backup。Phase 4のECW変更をすべて反映済み |
| `tmp/tailscale/` | 原本のACL（HuJSON）、tailnet IDとDNS設定のメモ |
| `files/infrastructure/terraform/tailscale/acl-policy.live.json` | Terraformへ渡すlive ACL |
| `files/infrastructure/terraform/tailscale/terraform.tfvars` | tailnet ID |
| `files/infrastructure/terraform/tailscale/terraform.tfstate` | import済みstate。失っても再importできる |

#### コード側の実態（2026-09-06、静的調査）

- **Ansibleは実装済みで、追加のコード変更は要らない。** `network_migration_complete`を`true`にすると
  `compose.env.j2`、`AdGuardHome.yaml.j2`、`healthchecks-ping.sh.j2`、`homelab.nft.j2`が`.10.101`へ揃う。
  `site.yml`のassertがflagの単独変更を拒むので、`legacy_service_addresses_enabled=false`と
  `legacy_service_cutover_confirmed=false`を同じcommitで変える。
- **Terraform apps-vm rootで変えるのは2つだけである。** `management_ip`を`192.168.10.101/24`へ、集約後に
  `legacy_service_nic`を`false`へ。`management_vlan_id`は`10`のまま変えない。`outputs.tf`の
  `planned_final_management_address`はどこからも参照されていない記録用の出力である。
- **IX2215のVLAN 10/20/30/40はすでに稼働している。** Phase 4の実体は新規VLAN作成ではなく、ACLの
  stateful化とVLAN 11/63の撤去である。目標との差分は`server-out`/`server_app-out`のTrusted向け無条件
  permitと、`main-out`のIoT denyの2点で、`iot-out`の全denyと`guest-out`は目標どおりである。

#### 特に気をつける3点

1. **自分の足元を崩す操作がある。** Apps VMのIP変更、IXのACL変更、Tailscaleのnameserver変更。IXは
   console、VMはPVEのLAN直結access（`192.168.10.11`）を開いてから触る。
2. **DNSの順序。** 管理端末のTailscaleは、global nameserverを切り替え終えるまで切っておく。
3. **cloud-initの再実行で切り替わる（2026-09-12に実証）。** PVEのinstance-idはcloud-init設定の
   ハッシュなので、`ip_config`を変えて再起動するとcloud-initが新instanceとしてnetplanを描き直す。
   guestを手で触る必要はない。代わりに**SSH host鍵が作り直され、user-dataのruncmdも再実行される**ので、
   rootごとにuser-dataの再実行が安全かを確認してから行う。

#### Phase 4で直すもの

Apps VMのhost resolverが`*.kojigenba-srv.com`を解決できない件は、Terraformの`dns_servers`既定値が
`["192.168.10.1", "1.1.1.1"]`であることに由来する。Phase 3では宣言どおりの結果として直さなかった。
Tailscale global nameserverの変更はApps VM自身には作用せず、TerraformのDNS値もcloud-init/bootstrap専用である。
**`.10.101`集約に合わせてAnsibleで`systemd-resolved`を明示管理する実装を追加して解消する。**


### 6. Phase 5: 廃止

**2026-09-20（Phase 3合格日2026-09-06から14日）を経過し、rollbackが発生していないことを
条件とする。** それ以前に着手しない。詳細は移行手順書に従う。
`k8s-volumes`配下のorphan directory 7件（`openldap-*` 3世代、旧`external-dns-blocklist-*` 2世代、
旧stashpad prod/staging各1世代）の削除判断もここで行う。

## rollback手順

新旧を同時にwriterにしないことを最優先する。

**Kubernetes VMを停止済みの場合は、下記を始める前にVMID 101/102/103を起動し、
全nodeがReadyになりworkloadを受けられる状態になるまで待つこと。**

1. Apps VMで`homelab-apps.service`を停止し、全Compose projectがdownしたことを確認する。
2. `systemctl stop homelab-service-addresses`でservice IPを外し、
   `ip -4 addr show dev ens19`に`.11.x`がないことを確認する。
3. NFS serverで`/proc/fs/nfsd/clients/*/states`を確認し、Apps VM（`192.168.10.101`）の
   open stateが0件であることを確認する。
4. Apps VM側で発生したwriteを記録し、旧側へ戻すdata/schemaの扱いを決める。
5. `metallb-speaker` DaemonSetの`nodeSelector`を`{"kubernetes.io/os":"linux"}`へ戻す。
6. 3つのServiceのtypeを`LoadBalancer`へ戻す。`spec.loadBalancerIP`が固定してあるため
   MetalLBは同じIPを再割り当てする。
7. ingress-nginx、samba、sillytavern、stashpad-prod/stagingを`--replicas=1`へ戻す。
8. **Unboundは先にPVC上の不正なRPZファイルを退避してからscale upする。** ReplicaSetを選び直す操作は
   不要かつ不可能である（詳細は[rollback用 状態スナップショット](k8s-rollback-state.md)）。
   NFS server上の
   `/mnt/tank-gen2/data/k8s-volumes/external-dns-blocklist-data-pvc-8e7db6e1-.../rpz/hagezi-tif.txt`
   を改名で退避し、必要なら空zoneを置いたうえで`--replicas=1`へ戻す。
   `blocklist-updater` CronJobのresumeは、downloaderがHTTPエラー本文をファイルへ保存しないよう
   修正してから行う。修正前にresumeすると同じ事象を再発させる。
9. Flux Kustomization 4件をresumeする。
10. IX2215で`interface BVI11`に`ip dhcp binding server_app-dhcp`を再投入する。BVI11のprefixは
    `/24`のままでよい。rollbackで復帰する`.11.100`/`.11.101`/`.11.103`はいずれも旧`/25`の範囲内に
    あり、`/24`のままでも到達性に影響しないためである。
11. 現行FQDNから旧serviceが正常なことを確認する。

`make rollback-app`が成功した場合は、自動reconcileが停止したまま
`/var/lib/homelab/reconcile.pending`に現在の`origin/main` SHAと対象projectが記録される。
原因とdata/schema互換性を確認した後にだけ`reconcile.paused`を削除する。

## 直ちに停止する条件

- Apps VMと旧Kubernetesが同時にwriterになりうる状態が観測された。
- NFS serverの`states`に、想定していないclientのwrite openがある。
- Terraform planがApps VM以外を変更する、VMID 112をreplaceする、または説明できない差分を含む。
- state backup preflight、SSH host key、NFS source/fstype/mode/markerのいずれかを検証できない。
- imageがdigest固定されていない、または宣言digestと公開manifestが一致しない。
- Tailscale live ACL全体をexport・reviewせずに`manage_tailnet=true`へ変更しようとしている。
- **2026-09-20の14日保持期間満了前にKubernetes VMを削除しようとしている。**
- 実施対象に必要なrollback、console/OOB access、ユーザーの明示的な着手判断のいずれかがない。
- Apps VMをdestroyしようとしているのに、次のいずれかを満たしていない。
  - `proxmox_api_token`と`ssh_public_key`を供給できることを確認していない。
  - `make state-backup`でTerraform stateを退避していない。
  - destroy planに`proxmox_virtual_environment_vm.apps`、
    `proxmox_virtual_environment_file.cloud_config`、`proxmox_download_file.debian_cloud_image`
    以外のresourceが含まれている。
  - Debian cloud imageのURLが生きていることを確認していない。
- destroy後のapplyが403で失敗しているのに、ACL `/vms/112`の欠落を確認せず別の原因を探している。
- **Phase 4で、Apps VMが`192.168.10.101`で稼働を始める前に
  `enable_adguard_dns=true`のTailscale applyを行おうとしている。** tailnet全体のDNSが落ちる。
- **Phase 4で、Tailscale rootをimportせずにいきなりapplyしようとしている。**
  このrootにはstateが無く、applyは既存のlive設定を上書きする。
- **Phase 4で、live ACLをexport・reviewせずに`manage_tailnet=true`にしようとしている。**
- **IX2215を変更するのにconsole accessとstartup-config原本がない、またはECW5211を変更するのに
  ECW backupがない。** 別対象の未準備をPhase 4全体の停止条件にはしない。
- **Phase 4で、Ansibleの`network_migration_complete`を、
  `legacy_service_addresses_enabled`と`legacy_service_cutover_confirmed`をfalseにせずに
  trueへ変えようとしている。** `site.yml`のassertが拒否するが、そもそも設計を誤解している。
- **既存VMのTerraform `initialization.ip_config`変更だけでguest OSの実IPが切り替わる前提で
  applyしようとしている。** 3 VMとも旧新IPを一時併用し、guest側の永続設定と再起動後の到達性を
  確認してからTerraform宣言を合わせる。

## 作業対象外・worktree保護

- `files/infrastructure/network/README.md`
- `files/infrastructure/network/config.txt`

上記2ファイルにあった、この移行作業開始前からのユーザー変更（VLAN 11を`/25`から`/24`へ改める
期待値）は、2026-09-05にユーザーの明示的な承認のもとで実機へ適用したうえでcommit済みであり、
未commitの変更はもう残っていない。ただし両ファイルは引き続きユーザー管理であり、明示依頼なしに
編集、破棄、整形、stage、commitしない。選択的にstageし、commit前に
`git diff --cached --name-only`で対象を確認する。

次も現時点では行わない。**Phase 4はこれらのうちいくつかを解禁するが、
解禁されるのはユーザーとmaintenance windowを合意し、その段階の「段階別のゲート」を満たした後だけである。**

- Kubernetes VM、PVC、NFS data、ZFS dataset、snapshot 2世代の削除。
  **2026-09-20の14日保持期間満了までは、いかなる理由でも削除しない。**
- IX2215、ECW5211、VLAN、DHCPの変更。**Phase 4の対象だが、window合意前には行わない。**
- `vmbr0.11`の修正・削除（記録のみ。`192.18.11.11/24`のtypoも直さない）
- Tailscale DNS/ACL/routeのapply。**Phase 4の対象だが、live ACLのexportとreviewを
  終える前には行わない。stateが無いのでimportが先である。**
- `stashPadDev`（VMID 111）の変更

コード変更が必要な作業と、まとまった調査は、ユーザーの希望により可能な限りLunaの補助agentへ
委譲する。レート制限を意識し、primary agentは設計、監査、実機への破壊的操作の判断に専念する。
ただし、この指示書の最終編集と、実機を変更する操作の実行はprimary agentが行う。
**補助agentには読み取り専用の調査・検証だけを任せ、実機を変更する操作は委譲しない。**
設計・運用文書は日本語で記述する。

補助agentへ委譲する際の注意。今回のセッションでは、待機を伴う検証（`sleep`を挟んだ再確認）を
任せた補助agentが、バックグラウンドタスクの完了通知を待つループに入って報告を返さなかった。
**待機を含む手順は委譲せず、primary agent側で時間を置いて実行すること。**

コードまたは構成を変更した場合は、対象に応じて次の既知のCI相当検証を実行する。失敗を残したまま
実機変更へ進まない。**Apps VMのCompose定義は`origin/main`のcloneから読まれるため、
`compose.yaml`の変更はmainへmergeし、reconcile経由で配布しなければ反映されない。**

```sh
make ansible-lint ansible-check ansible-bootstrap-paths-test \
  compose-reconcile-fixture toolbox-uid-test cloud-init-test \
  terraform-apps-vm-lifecycle-test compose-config adguard-config-check \
  gatus-config-check shellcheck secrets-scan \
  state-backup-test state-restore-test state-backup-preflight-test \
  tailscale-acl-path-test terraform-fmt terraform-validate \
  terraform-validate-tailscale
```

## 完了済みのGit delivery

- PR #7、#9、#14〜#24はmainへmerge済みで、各CIは成功済み。
- **PR #23**（2026-09-06 merge）はPhase 3再構築試験の結果、Proxmox権限の欠陥、
  IX2215ドリフト解消の記録である。文書と`files/infrastructure/network/`の記録のみで、
  実機の挙動を変えるコードは含まない。
- **PR #8**（2026-09-06 merge）はDependabotによる`actions/checkout` 4.2.2 → 7.0.1である。
  移行作業とは無関係。v7の破壊的変更は`pull_request_target`と`workflow_run`での
  fork PR checkoutに関するもので、本リポジトリの4 workflowはいずれも該当trigger を使っていない。
  この変更で`.github/workflows/caddy-image.yml`自身が変わったため、Caddy imageの再ビルドが
  走った。**compose.yamlはdigest固定のため稼働containerへの影響はない。**
- **PR #24**（2026-09-06 merge）はtoolbox imageをtagではなくdigestで固定して実行する変更である。
  背景は下記のtoolboxの項を参照。digest固定のimageでCI相当19 targetが通ることを確認済み。
- `origin/main`の現在地は`git log --oneline origin/main -1`で確認する。
  **この文書はSHAを固定しない。**
- toolbox `ghcr.io/koji-genba/homelab-toolbox:1.0.1`は公開済み。
  **Makefileはtagではなくdigest `sha256:9da8408a19624df8b4da2fbcde93d64eddd5c6414e77e59c0e0e6f51b7ec8037`で
  固定して実行する（PR #24）。** publish workflowは`files/tools/homelab-toolbox/**`と
  `.github/workflows/toolbox-image.yml`自身の変更で起動し、毎回同じ`:1.0.1`タグを上書きするため、
  tag参照では引かれるimageが再現しないためである。
  **2026-09-06だけでtagは3つのdigestを指した。** `sha256:7607f2c7...`（当初）→
  `sha256:9da8408a...`（PR #8のmergeでworkflowファイルが変わったため）→
  `sha256:63c9c090...`（PR #24でtoolbox READMEを変えたため）。いずれもDockerfileは変わっていない。
  **digest固定後はtagがどこへ動いてもMakefileが引くimageは変わらない。**
  旧digestはいずれもregistryに残存している。
  更新手順は[toolbox README](../../files/tools/homelab-toolbox/README.md)にある。
- **image workflowの`paths`から自分自身を外す案は採らなかった。** digest固定さえしてあれば
  再ビルド自体は無害であり、またcommitしている最中の再ビルドは原因が明らかで、
  何もしていない時の突然の停止とは性質が違うためである（ユーザー判断、2026-09-06）。
  なお`compose.yaml`が7 projectすべてをdigest固定しているため、Caddy imageの`:2.11.4`タグが
  上書きされても稼働containerは再作成されず、サービスは止まらない。
- Caddy custom imageを含む7 projectのimageはdigest固定済み。
- ローカルの`main`と`origin/main`の間に未反映の差分はない。

## cutover以降の実機確認で判明した実装バグ（PR #19、#20、#21で修正済み）

いずれもoffline検証では検出できず、実機適用で初めて顕在化した。同種の不具合を疑う際の参考にする。

1. **AdGuardHome.yaml.j2が不正なYAMLを生成していた。** Ansibleのtemplateは`trim_blocks=True`で
   動作するため、inlineの`{% for %}{% if %}`直後の改行が削除され、`user_rules`のsequence entryが
   1行に連結されていた。AdGuard Homeが起動できず、cutover中のDNS断の直接原因になった。
   `make adguard-config-check`は静的なconfigしか検証しておらず、**Ansibleがレンダリングした
   実出力を検証していなかった**ことが見逃しの原因である。
2. **systemd unit templateで同じ改行消失が起きていた。** `homelab-apps.service.j2`と
   `homelab-app-reconcile.service.j2`で`Requires=`/`After=`行末の改行が消え、次のdirectiveと
   連結していた。systemdは該当行を`Invalid argument`として無視するため、**設計上意図していた
   `PartOf=docker.service`と`Wants=network-online.target`が実機で無効だった**。
   実装状況文書に「Docker再起動時の`PartOf`復旧連携」として記載されていた機能が動いていなかった。
3. **Samba image内蔵のHEALTHCHECKが構造的に誤検知していた。**
   `smbclient -L localhost -U% | grep -q Server`を使っているが、SMB1無効化により
   server一覧テーブルが出力されず`Server`に永久にマッチしない。この誤検知で
   `docker compose up --wait`がtimeoutし、後続4 projectが起動しなかった。
   `compose.yaml`側で終了コード判定のhealthcheckを明示して解決した。
4. **GatusのCaddy probeが恒常的に失敗していた。** `http://caddy:80`の308をGatusが追跡し、
   証明書に含まれないDocker内部名`https://caddy/`へ接続してTLS errorになっていた。PR #20で
   `client.ignore-redirect: true`を追加し、最初の308を成功として評価するよう修正した。
5. **application reconcileがbind-mounted fileだけの変更をcontainerへ反映しなかった。** Gitの
   fast-forwardとprojectのsuccess記録は完了しても、Compose定義自体に差分がなければcontainerは
   再作成されず、Gitが置換した`config.yaml`等の旧inodeをbind mountし続けた。PR #21で、reconcileと
   rollbackが選択projectをforce-recreateするよう修正した。

あわせて、Phase 2Aの調査でも次の乖離が判明している。

- kube-proxyがIPVSモードかつlive ConfigMapの`strictARP: false`であるため、MetalLB speakerを
  止めてもnodeが`kube-ipvs0`のLoadBalancer IPに対してARPを返し続けた。
  kubespray inventoryは`kube_proxy_strict_arp: true`であり、実機がdriftしていた。
  service IPの解放にはServiceのClusterIP化が必要だった。
- 移行文書が管理する7 pathの外に、NFS上へPVデータを持つ未記録のworkloadが2系統
  （`openldap`、`external-dns-blocklist`）存在した。
