# 次セッションへの作業指示

- 更新日: 2026-09-06
- 対象リポジトリ: `/home/s-sato/homelab`
- 作業ブランチ: **`main`**（`origin/main` = `6929950`）。`k8s-decommission`はPR #23として
  mainへmerge済みであり、以後の作業ブランチではない。新しい作業は`origin/main`から
  branchを切って行う。
- **未pushのcommitはない。** 2026-09-06にPR #23と#24をmainへmerge済みである。
  以後の作業でcommitした場合、pushとPRはユーザーの指示を受けてから行う。
- 現在地: **Phase 3の再構築性試験を2026-09-06に実施した。** Apps VM（VMID 112）をTerraformで
  destroyし、Terraform・Ansible・Gitから再構築して復旧させた。**Apps VMが唯一のwriterで、
  7 Compose projectが稼働中。** IX2215の構成ドリフトは2026-09-05に解消済み。
  Kubernetes VM 3台は2026-09-05に停止済み（削除はしていない）。
- **受入試験は12項目すべて合格した**（自動確認5項目と、2026-09-06にユーザーが確認した7項目）。
  **Kubernetes VM 14日保持期間は2026-09-06に開始し、2026-09-20に満了する。**
- **次の作業はPhase 4のネットワーク移行である。** 別のmaintenance windowで実施する。
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
4. 次の作業はPhase 4のネットワーク移行である。**着手にはユーザーとのmaintenance window合意が必須である。**
   **Phase 1〜3はすべて完了しており、再実施しない。**
   **2026-09-20の満了日まで、Kubernetes VM・disk・PVC・NFS data・ZFS snapshotを削除しない。**

## 目的とフェーズ境界

- KubernetesをDebian 13の単一Apps VMとDocker Composeへ置き換え、現在の機能を減らさない。
- Proxmoxインストール済みの状態からGit、Terraform、Ansible、Compose、SOPS/ageで再構築可能にする。
- NFS上の既存dataを最優先で保護し、新旧を同時writerにしない。
- VLAN 10/20/30/40への再編（Phase 4）は別windowで行う。application cutoverへ混ぜない。
- **Apps VMの削除・IaC再構築試験（Phase 3）に合格した日から14日間は旧Kubernetes VMを保持する。**
  合格日は2026-09-06であり、**保持期間は2026-09-20に満了する**。
- `stashPadDev`（VMID 111）は作業用VMであり、この移行の対象外とする。

## 絶対に維持する安全条件

**writerの向きがcutoverで反転した。以下は2026-09-05時点の状態を前提とする。**

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
  global nameserverは`192.168.11.101`のままであり、Terraform宣言の`192.168.10.101`はPhase 4の期待値である。
  **今applyするとtailnet全体のDNSが解決不能になる。**
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

### Apps VM（VMID 112、`192.168.10.42`）

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
  `eth0`は管理用`192.168.10.42/24`のまま。
- NFS 7 mountのうち`stashpad-media`だけが`ro`、他6つが`rw`。これが正しい状態である。
- `/opt/homelab`は`origin/main` `6929950`のcleanなcheckout。`homelab-app-reconcile.timer`はenabled/active。
- 稼働中imageのdigestはGit宣言と7/7一致している。
- **2026-09-06のPhase 3で再構築されたVMである。** 次の値が変わった。
  - NICのMAC。`net0`（eth0、VLAN 10）が`BC:24:11:D7:47:A2`、`net1`（ens19、VLAN 11）が`BC:24:11:2E:FB:64`。
    旧値はそれぞれ`BC:24:11:9E:9B:29`と`BC:24:11:84:F3:EA`である。
  - SSH host key。現在の値は`SHA256:9U1BvsqDUUQASaGfCqLSei5HdOV17gkNUsUa1ahEpys`で、
    QEMU guest agent経由と`ssh-keyscan`の2経路で一致を確認して`known_hosts`へ登録した。
  - TLS証明書。Let's Encryptから再取得された（`prod.stashpad`の有効期限は2026-12-05）。
- Apps VMへのSSHは`deploy@192.168.10.42`である（`files/infrastructure/ansible/apps/inventory/hosts.yml`の
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

**1〜4はすべて完了済みの記録である。再実施しない。次の作業は5のPhase 4である。**
1〜4には、今後も守るべき手順や注意（IX2215のACL編集手順、NFS open stateの扱い、
再びApps VMをdestroyする場合の前提、Proxmox権限がIaCの外にあること）が含まれているので
読み飛ばさないこと。

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


### 5. Phase 4: ネットワーク移行

別のmaintenance windowで実施する。application cutoverへ混ぜない。含まれるのは次である。

- `files/infrastructure/network/README.md`と`config.txt`の反映（ユーザー管理。勝手に触らない）。
  BVI11の`/24`化と実機バージョン整合は2026-09-05に反映済みのため、Phase 4で残るのは
  VLAN 10/20/30/40再編に伴う変更に限る
- Tailscale live ACLのexport、Terraform import、global nameserverの`192.168.10.101`への変更
- VLAN 10/20/30/40への再編、ECW5211の設定、Apps VMの`192.168.10.101`への集約

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
3. NFS serverで`/proc/fs/nfsd/clients/*/states`を確認し、Apps VM（`192.168.10.42`）の
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
- rollback手順、OOB access、maintenance window、ユーザーの明示許可のいずれかがない。
- Apps VMをdestroyしようとしているのに、次のいずれかを満たしていない。
  - `proxmox_api_token`と`ssh_public_key`を供給できることを確認していない。
  - `make state-backup`でTerraform stateを退避していない。
  - destroy planに`proxmox_virtual_environment_vm.apps`、
    `proxmox_virtual_environment_file.cloud_config`、`proxmox_download_file.debian_cloud_image`
    以外のresourceが含まれている。
  - Debian cloud imageのURLが生きていることを確認していない。
- destroy後のapplyが403で失敗しているのに、ACL `/vms/112`の欠落を確認せず別の原因を探している。

## 作業対象外・worktree保護

- `files/infrastructure/network/README.md`
- `files/infrastructure/network/config.txt`

上記2ファイルにあった、この移行作業開始前からのユーザー変更（VLAN 11を`/25`から`/24`へ改める
期待値）は、2026-09-05にユーザーの明示的な承認のもとで実機へ適用したうえでcommit済みであり、
未commitの変更はもう残っていない。ただし両ファイルは引き続きユーザー管理であり、明示依頼なしに
編集、破棄、整形、stage、commitしない。選択的にstageし、commit前に
`git diff --cached --name-only`で対象を確認する。

次も現時点では行わない。

- Kubernetes VM、PVC、NFS data、ZFS dataset、cutover snapshotの削除。
  **Apps VM（VMID 112）のdestroyだけはPhase 3の試験対象であり例外だが、
  「着手前のゲート」を全部満たし、ユーザーとmaintenance windowを合意してからに限る。**
- IX2215、ECW5211、VLAN、DHCPの追加変更（2026-09-05に承認済みwindowで実施したBVI11 prefix変更・
  ACL更新と、`write memory`を除く）
- `vmbr0.11`の修正・削除
- Tailscale DNS/ACL/routeのapply
- `stashPadDev`（VMID 111）の変更

コード変更が必要な作業と、まとまった調査は、ユーザーの希望により可能な限りsonnetの補助agentへ
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
- `origin/main`は`6929950`。
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
