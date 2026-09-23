# 次セッションへの作業指示

> 2026-09-19時点の履歴資料。Phase 5の現行状態は[引き継ぎ](../next-session.md)を参照。

- 更新日: 2026-09-19
- 対象リポジトリ: `/home/s-sato/homelab`
- 作業ブランチ: **`main`**。新しい作業は`origin/main`からbranchを切って行う。
  **この文書にSHAを固定で書かない。** merge のたびに陳腐化して罠になるためである。
  現在地は`git log --oneline origin/main -1`で確認する。branchは`main`と`state-backup`
  （暗号化したTerraform stateの保管用。**削除しない**）だけである。
  pushとPRはユーザーの指示を受けてから行う。

この文書は、会話履歴がない次セッションが安全に作業を再開するための指示書である。
進捗の羅列ではなく、ここに記載した順序、ゲート、停止条件に従うこと。
**Phase 0〜4の完了記録は[archive/](archive/)にある。読む必要があるのは経緯を辿るときだけで、
作業の前提はこの文書に書き出してある。**

## 現在地

| | |
| --- | --- |
| Phase 0〜2（inventory、Apps VM構築、application cutover） | 完了（2026-09-05） |
| Phase 3（再構築性の証明） | 完了（2026-09-06、受入試験12項目すべて合格） |
| Phase 4（IX/VLAN/ECW移行、Apps VM host resolver） | 完了（2026-09-13）。Port 4のVLAN 10 access化は2026-09-19に実機反映・`write memory`まで完了 |
| **Phase 5（Kubernetes廃止）** | **未着手。これが次の作業である** |

- **Apps VMが唯一のwriterで、7 Compose projectが稼働中である。**
- **Kubernetes VM 101/102/103は2026-09-05に停止した。削除はしていない。**
- **14日保持期間はPhase 3合格日2026-09-06に開始し、2026-09-20に満了する。**
  満了日までにrollbackが発生しなければ、Phase 5の廃止へ進む。

## セッション開始時に必ず行うこと

1. この文書を最後まで読む。あわせて次を確認する。
   - [rollback用 状態スナップショット](k8s-rollback-state.md) — Kubernetes VM停止直前のService定義、
     replicas、nodeSelector、Flux suspend状態。**Phase 5でKubernetesを消すまで生きている文書である。**
   - [移行手順書のフェーズ5](k8s-to-compose.md) — 廃止作業のチェックリスト
2. worktreeとbranchを読み取り専用で確認する。protectedなnetwork 2ファイルを触らない。

   ```sh
   git status --short --branch
   git log --oneline --decorate -10
   ```

3. 実機の現在状態を読み取り専用で確認し、後述の「現在のシステム状態」と一致するかを見る。
4. **2026-09-20の満了日まで、Kubernetes VM・disk・PVC・NFS data・ZFS snapshotを削除しない。**

## 現在のシステム状態（2026-09-19）

### Apps VM（VMID 112、`192.168.10.101`）

- 7 Compose projectがすべて稼働。`homelab-apps.service`は`active`。

  | project | container |
  | --- | --- |
  | edge | `homelab-edge-caddy-1` |
  | dns | `homelab-dns-adguard-1` |
  | samba | `homelab-samba-samba-1` |
  | stashpad-prod | `homelab-stashpad-prod-stashpad-prod-1` |
  | stashpad-staging | `homelab-stashpad-staging-stashpad-staging-1` |
  | sillytavern | `homelab-sillytavern-sillytavern-1` |
  | monitoring | `homelab-monitoring-gatus-1` |

- **NICは`eth0`の1枚だけ**（`192.168.10.101/24`、VLAN 10）。管理もserviceもここに集約済みで、
  Caddy 80/443、AdGuard 53、Samba 445がこのaddressで待ち受ける。VLAN 11 NIC（`ens19`）は
  2026-09-13に`legacy_service_nic=false`で撤去した。
- NFS 8 mountのうち`stashpad-media`だけが`ro`、他が`rw`。これが正しい状態である。
  8本目はDGX Spark用の`ai`（2026-09-19追加、[DGX Sparkストレージ運用](../operations/dgx-storage.md)）。
- `/opt/homelab`は`origin/main`のcleanなcheckoutである。`homelab-app-reconcile.timer`は
  enabled/activeで、15分間隔でmainへfast-forwardする。追従先は
  `git -C /opt/homelab rev-parse HEAD`を`origin/main`と突き合わせて確認する。
- 稼働中imageのdigestはGit宣言と一致している。7 projectすべてdigest固定済みである。
- SSHは`deploy@192.168.10.101`。秘密鍵の指定はなく、既定の`~/.ssh/id_ed25519`とssh-agentに委ねる設計である。
- **このVMはICMPを塞いでいる。** 死活確認はpingではなくSSHで行う。
- host resolverはAnsibleの`network` roleが管理するsplit DNSである。`kojigenba-srv.com`だけを
  自分のAdGuard（`192.168.10.101`）へ、それ以外を`1.1.1.1`/`8.8.8.8`へ送る。
  **全部をAdGuardへ向けない。** AdGuardのコンテナが止まるとaptもimage取得も失敗するhostになるためである。
  Terraformの`dns_servers`既定値`["192.168.10.1", "1.1.1.1"]`はcloud-initの初回起動専用として残してある。
  **再構築直後は`make ansible-apply`まで流さないと内部FQDNが引けない**のが正しい状態であり、ドリフトではない。
- **Apps VMはTailscaleノードではない。** `tailscaled`も`100.x`アドレスも持たない。

### Kubernetes（VM停止済み、削除していない）

- **VM 101/102/103は`stopped`である。** 2026-09-05にworker → control planeの順（103 → 102 → 101）で
  `qm shutdown --timeout 180`により3台ともクリーンに停止した。VMもdiskも削除していない。
- 停止前にwriterから降ろした状態を維持している。完全な値は
  [rollback用 状態スナップショット](k8s-rollback-state.md)にある。
  - Flux Kustomization `stashpad-prod` `stashpad-staging` `sillytavern` `flux-system` はsuspend。
  - CronJob `external-dns/blocklist-updater` はsuspend。
  - Deployment 6件（stashpad prod/staging、sillytavern、samba、external-unbound、
    ingress-nginx-controller）は`replicas=0`。
  - DaemonSet `metallb-speaker` は`nodeSelector`に`homelab.io/metallb: disabled`を追加して停止。
    **元の値は`{"kubernetes.io/os":"linux"}`である。**
  - 3つのServiceは`ClusterIP`化済み。rollback用に`spec.loadBalancerIP`を固定してある
    （ingress `192.168.11.100`、Unbound `192.168.11.101`、Samba `192.168.11.103`）。
- Unboundは、PVC上の`rpz/hagezi-tif.txt`が不正なためscale upするとCrashLoopする。
  復旧はReplicaSetの選び直しではなく、当該ファイルの退避で行う（手順はスナップショット文書にある）。

### ネットワーク

- VLAN 10/20/30/40の4ゾーン構成。**VLAN 11と63は2026-09-13に撤去済みである。**
- GE2の物理port（すべて実機反映済み）。

  | port | 接続先 | untagged | tagged |
  | ---: | --- | --- | --- |
  | 1 | pve1 | 破棄 | VLAN 10（group 6） |
  | 2 | 管理端末 | VLAN 20（access） | 破棄 |
  | 3 | edgeXpert `.10.51` | VLAN 10（access） | 破棄 |
  | 4 | Server access | VLAN 10（access、group 1） | 破棄 |
  | 5-7 | 未使用 | VLAN 40（access、group 4） | 破棄 |
  | 8 | ECW5211-L `.10.2` | 破棄 | VLAN 10/20/30/40 |

  port 1と8はタグ専用trunk、port 2〜7は1 VLANだけのaccess portである。
  ECW uplinkではtagged/untagged VLAN 40を同じbridge-groupへ入れるとARP反射が起きたため、
  untaggedを`GigaEthernet2.0`へ収容しない。
- Server VLAN 10上のVMは3台。Apps 112 `.10.101`、Tailscale gateway 105 `.10.102`、
  ElastiFlow 110 `.10.103`。いずれもsystemd-networkd + Netplan、NoCloud seedである。
- tailnetに居るのは`tailscale-gateway`（VMID 105、tailnet上のhostnameは**`home-gateway`**で
  PVEのVM名とは異なる）だけで、これがsubnet routerとしてLANを代理している。
  **したがって、外部からSMB・HTTPS・DNSへ届く唯一の経路は`home-gateway`のAdvertiseRoutesである。**
  現行の広告は`0.0.0.0/0`、`::/0`、`192.168.10.0/24`の3件である。
  **`192.168.10.0/24`を外すと、tailnet越しに宅内サービスへ到達できなくなる。**
  名前解決はAdGuardが担うのでDNSは成功し続け、接続だけがtimeoutするという分かりにくい壊れ方をする。
  **exit node（`0.0.0.0/0`、`::/0`）はsubnet routeの代替にならない。**
- Tailscale rootはimport済みでstateがある。ACL、MagicDNS、global nameserverをTerraformが所有し、
  global nameserverの実機値は`192.168.10.101`である。ACLを変えるときはAdmin Consoleを直接編集せず、
  `acl-policy.live.json`を編集してplan/applyする。`manage_subnet_router`はfalseのままで、
  ノードが広告するrouteはguestの`tailscaled` prefsでありTerraformでは変えられない
  （[#29](https://github.com/koji-genba/homelab/issues/29)、構造的な代替案は
  [#30](https://github.com/koji-genba/homelab/issues/30)）。
- sFlowは`.10.103:6343`へ送信中で、collector側の着信まで確認済みである。
  **ElastiFlowのElasticsearch取り込みは2026-07-07から壊れている**既存障害で、移行とは無関係である
  （[#34](https://github.com/koji-genba/homelab/issues/34)）。

### ZFS snapshot

cutover直前の`@pre-compose-cutover-20260905`とPhase 3のdestroy直前の`@pre-phase3-20260906`を、
同じ4 datasetへ取得済みである。**どちらも14日保持期間の満了まで削除しない。**

- `tank-gen2/data/k8s-volumes`
- `tank-gen1/data/archive`
- `tank-gen2/data/shared`
- `cache-pool`（mergerfsのcache branch。HDD側datasetのsnapshotだけでは直近の書き込みを保護できない）

pve1のroot crontabにある`/usr/local/bin/mover.sh`（05:00）は`tank-gen2/data/shared`のみを対象とする
自家製snapshot/tieringである。Kubernetesとは独立した第3のwriterであり、運用を継続する。

## 絶対に維持する安全条件

- **Apps VMが唯一のwriterである。Kubernetes側のworkloadを再開させない。**
  上記のsuspend/replicas=0/ClusterIP化の状態を維持する。**rollback以外の目的でVMを起動しない。**
  起動した場合も、Fluxをresumeせず、Deploymentをscale upせず、ServiceをLoadBalancerへ戻さない。
- **2026-09-20の満了日まで、VM・disk・PVC・NFS data・ZFS snapshot 2世代のいずれも削除しない。**
- Ansible flagは次の値である。**rollback以外で逆戻しない。**
  - `network_migration_complete: true`
  - `legacy_service_addresses_enabled: false`
  - `legacy_service_cutover_confirmed: false`
  - `application_cutover_confirmed: true`

  `site.yml`のassertは、`network_migration_complete=true`のときlegacy 2 flagがどちらもfalseで
  あることを要求する。**VLAN 11のaddressを再付与するには`network_migration_complete`を
  falseへ戻す必要がある。** これはrollback時にだけ行う。
- Apps VMのcloud-init warning履歴を消す目的で`cloud-init clean`やreinitを行わない。
- Terraform planにVMID 112のreplace、想定外resource、Apps VM以外の変更が出たらapplyしない。
- secret、API token、age秘密鍵、復号済み設定、Terraform stateの実値を会話、ログ、Git、tfvarsへ出力しない。
- **Apps VMをdestroyする場合は、applyの前にProxmoxのACL `/vms/112`を再付与する。**
  Proxmoxはdestroy時に`/vms/<vmid>`のACLをVMと一緒に削除するため、そのままapplyすると
  `HTTP 403 Permission check failed`で失敗する。2026-09-06に実際に発生した。前提条件、投入コマンド、
  403の診断手順、destroy時のその他の注意はすべて
  [Apps VM復旧手順](../operations/apps-vm-recovery.md)にある。

## 次に行う作業: Phase 5（Kubernetes廃止）

**着手条件は2026-09-20の経過と、その間にrollbackが発生していないことである。それ以前に着手しない。**
チェックリストは[移行手順書のフェーズ5](k8s-to-compose.md)にある。判断が要るのは次の点である。

- `k8s-volumes`配下のorphan directory 7件（`openldap-*` 3世代、旧`external-dns-blocklist-*` 2世代、
  旧stashpad prod/staging各1世代）の削除判断。writerは存在せず、Phase 2Bではsnapshotで保全した。
- 旧NFS exportをApps VM `/32`だけへ狭める範囲。**ただしDGX Spark 2台（`.10.51`/`.10.52`）が
  `ai` exportを使うため、そこは`192.168.10.0/24`単位のまま残す**
  （[NFS export契約](../operations/nfs-export.md)）。
- 削除に踏み切った時点で[rollback用 状態スナップショット](k8s-rollback-state.md)と
  この文書のrollback節は役目を終える。あわせて整理する。

## 移行フェーズとは独立した残作業

- **DGX Spark 2台の`/etc/fstab`追記。** pve1とApps VMへの反映は2026-09-19に完了している。
  残りはユーザーが実施する。手順は[DGX Sparkストレージ運用](../operations/dgx-storage.md)にある。
  Phase 5のゲートには影響しない。
- **ProxmoxのIaC外資産の恒久対策（未実施）。** user `terraform@pve`、role `HomelabTerraform`、
  API token `terraform@pve!apps-vm`、7つのACL pathはGitにもTerraformにも宣言されていない
  手動作成の資産である。Phase 3はこれにより「Proxmoxインストール済みの状態からGitとIaCだけで
  再構築できる」という前提が現状では成立しないことを明らかにした。
  現在の緩和策は[Apps VM復旧手順](../operations/apps-vm-recovery.md)への明文化のみである。
- 既知の未解決issue: [#29](https://github.com/koji-genba/homelab/issues/29)（subnet router routeの層）、
  [#30](https://github.com/koji-genba/homelab/issues/30)（hairpinの構造的代替案）、
  [#34](https://github.com/koji-genba/homelab/issues/34)（ElastiFlow取り込み障害）、
  [#35](https://github.com/koji-genba/homelab/issues/35)（`make ansible-apply`のたびに全Compose
  projectが再作成される。AdGuardが起動直後に設定ファイルを書き戻し、テンプレートと常に食い違うため）。

## rollback手順

新旧を同時にwriterにしないことを最優先する。

**Phase 4でVLAN 11を撤去したため、Kubernetesへのrollbackには前提作業が2つ増えている。**

- Kubernetes VM 101/102/103を起動し、全nodeがReadyになるまで待つ。
- IX2215へVLAN 11を再投入する（`BVI11`、tagged subinterface、`server_app-dhcp`、関連ACL）。
  投入内容は`files/infrastructure/network/config.txt`のGit履歴から復元できる。
  これがないと3つのLoadBalancer IP（`.11.100`/`.11.101`/`.11.103`）が疎通しない。

そのうえで次を実行する。

1. Apps VMで`homelab-apps.service`を停止し、全Compose projectがdownしたことを確認する。
2. NFS serverで`/proc/fs/nfsd/clients/*/states`を確認し、Apps VM（`192.168.10.101`）の
   open stateが0件であることを確認する。
3. Apps VM側で発生したwriteを記録し、旧側へ戻すdata/schemaの扱いを決める。
4. `metallb-speaker` DaemonSetの`nodeSelector`を`{"kubernetes.io/os":"linux"}`へ戻す。
5. 3つのServiceのtypeを`LoadBalancer`へ戻す。`spec.loadBalancerIP`が固定してあるため
   MetalLBは同じIPを再割り当てする。
6. ingress-nginx、samba、sillytavern、stashpad-prod/stagingを`--replicas=1`へ戻す。
7. **Unboundは先にPVC上の不正なRPZファイルを退避してからscale upする。** ReplicaSetを選び直す操作は
   不要かつ不可能である（詳細は[rollback用 状態スナップショット](k8s-rollback-state.md)）。
   NFS server上の
   `/mnt/tank-gen2/data/k8s-volumes/external-dns-blocklist-data-pvc-8e7db6e1-.../rpz/hagezi-tif.txt`
   を改名で退避し、必要なら空zoneを置いたうえで`--replicas=1`へ戻す。
   `blocklist-updater` CronJobのresumeは、downloaderがHTTPエラー本文をファイルへ保存しないよう
   修正してから行う。修正前にresumeすると同じ事象を再発させる。
8. Flux Kustomization 4件をresumeする。
9. 現行FQDNから旧serviceが正常なことを確認する。

`make rollback-app`が成功した場合は、自動reconcileが停止したまま
`/var/lib/homelab/reconcile.pending`に現在の`origin/main` SHAと対象projectが記録される。
原因とdata/schema互換性を確認した後にだけ`reconcile.paused`を削除する。

## 直ちに停止する条件

- Apps VMと旧Kubernetesが同時にwriterになりうる状態が観測された。
- NFS serverの`states`に、想定していないclientのwrite openがある。
- Terraform planがApps VM以外を変更する、VMID 112をreplaceする、または説明できない差分を含む。
- state backup preflight、SSH host key、NFS source/fstype/mode/markerのいずれかを検証できない。
- imageがdigest固定されていない、または宣言digestと公開manifestが一致しない。
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
- Tailscale live ACL全体をexport・reviewせずに`manage_tailnet=true`へ変更しようとしている。
- IX2215を変更するのにconsole accessとstartup-config原本がない、
  またはECW5211を変更するのにECW backupがない。

## 作業対象外

**`files/infrastructure/network/`の2ファイル（`README.md`、`config.txt`）にかかっていた
「明示依頼なしに編集しない」保護は2026-09-19に解除した。** 通常の文書と同じように編集してよい。
ただし次は引き続き守る。

- `config.txt`は**実機の保存済み`startup-config`を基準にした管理用コピー**である。実機を変えずに
  ここだけ書き換えない。実機へ投入し`write memory`まで済ませてから、この記録を合わせる。
- 実機と照合するときは**行の並びではなく行の集合**で比較する。並び順は3箇所で異なるが、
  これはドリフトではない（[IX2215 ACL runbook §1.7.2](../network/ix-acl-stateful-runbook.md)）。
- 認証情報の行は既存値を保持しているため、公開場所へ転載しない。
- commit前に`git diff --cached --name-only`で対象を確認する。

次は現時点では行わない。

- Kubernetes VM、PVC、NFS data、ZFS dataset、snapshot 2世代の削除
  （**2026-09-20の満了までは、いかなる理由でも削除しない**）
- `vmbr0.11`の修正・削除（記録のみ。`192.18.11.11/24`のtypoも直さない）
- `stashPadDev`（VMID 111）の変更

## 作業の進め方

`make ansible-apply`を実行する前に、**ssh-agentと`AGE_IDENTITY_FILE`の両方**を用意すること。
toolboxはどちらの鍵もimageに持たず、環境変数があるときだけmountする。欠けたまま走らせると、
前者は`Gathering Facts`で`UNREACHABLE`、後者は`secrets`ロールが`no_log: true`のまま
原因不明の`non-zero return code`で落ちる。

**Apps VMのCompose定義は`origin/main`のcloneから読まれる。** `compose.yaml`の変更はmainへmergeし、
reconcile経由で配布しなければ反映されない。ローカル未コミットの変更は`make ansible-apply`だけでは
反映されない。

コード変更が必要な作業と、まとまった調査は、ユーザーの希望により可能な限り補助agentへ委譲する。
primary agentは設計、監査、実機への破壊的操作の判断に専念する。ただし、この指示書の最終編集と、
実機を変更する操作の実行はprimary agentが行う。
**補助agentには読み取り専用の調査・検証だけを任せ、実機を変更する操作は委譲しない。
待機を含む手順（`sleep`を挟んだ再確認）も委譲しない。** 補助agentがバックグラウンドタスクの
完了通知を待つループに入り、報告を返さなかった実例がある。
設計・運用文書は日本語で記述する。

コードまたは構成を変更した場合は、対象に応じて次の既知のCI相当検証を実行する。
失敗を残したまま実機変更へ進まない。

```sh
make ansible-lint ansible-check ansible-bootstrap-paths-test \
  compose-reconcile-fixture toolbox-uid-test cloud-init-test \
  terraform-apps-vm-lifecycle-test compose-config adguard-config-check \
  gatus-config-check shellcheck secrets-scan \
  state-backup-test state-restore-test state-backup-preflight-test \
  tailscale-acl-path-test terraform-fmt terraform-validate \
  terraform-validate-tailscale
```

**toolboxはtagではなくdigestで固定して実行する。** publish workflowが毎回同じ`:1.0.1`タグを
上書きするため、tag参照では引かれるimageが再現しないためである。更新手順は
[toolbox README](../../files/tools/homelab-toolbox/README.md)にある。

## 関連文書

| 文書 | 用途 |
| --- | --- |
| [移行手順書](k8s-to-compose.md) | 全フェーズの手順とゲート。残るのはフェーズ5 |
| [rollback用 状態スナップショット](k8s-rollback-state.md) | Kubernetes復旧に要る停止直前の値 |
| [archive/](archive/) | Phase 0〜4の完了記録。更新しない |
| [Apps VM復旧手順](../operations/apps-vm-recovery.md) | Proxmox側の前提、403の診断、再構築フロー |
| [アプリケーションのライフサイクル](../operations/application-lifecycle.md) | 日常のdeploy、reconcile、rollback |
| [NFS export契約](../operations/nfs-export.md) | export path、client範囲、marker |
| [DGX Sparkストレージ運用](../operations/dgx-storage.md) | `ai` exportの手順と検証 |
| [目標ゾーン設計](../network/target-zones.md) | VLAN 10/20/30/40の設計と手動変更記録 |
| [IX2215 ACL stateful化 実施手順書](../network/ix-acl-stateful-runbook.md) | IXのACL設計、投入手順、rollback |
| [ADR](../adr/README.md) | 0001〜0006の設計判断 |
