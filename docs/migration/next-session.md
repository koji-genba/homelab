# 次セッションへの作業指示

- 更新日: 2026-09-05
- 対象リポジトリ: `/home/s-sato/homelab`
- 作業ブランチ: `k8s-decommission`（`origin/main` = `e272c75`）
- 現在地: **Phase 2B application cutover実施済み。Apps VMが唯一のwriterで、7 Compose projectが稼働中**

この文書は、会話履歴がない次セッションが安全に作業を再開するための指示書である。
進捗の羅列ではなく、ここに記載した順序、ゲート、停止条件に従うこと。

## セッション開始時に必ず行うこと

1. この文書を最後まで読み、次を確認する。
   - [Phase 2A事前調査結果](phase2a-inventory.md) — 実測値、cutover/rollback手順、ユーザー判断
   - [実装状況](implementation-status.md)
   - [KubernetesからComposeへの移行手順](k8s-to-compose.md)
   - [Apps VM復旧手順](../operations/apps-vm-recovery.md)
2. worktreeとbranchを読み取り専用で確認する。protectedなnetwork 2ファイルを触らない。

   ```sh
   git status --short --branch
   git log --oneline --decorate -10
   ```

3. 実機の現在状態を読み取り専用で確認する（後述の「現在のシステム状態」と一致するか）。

## 目的とフェーズ境界

- KubernetesをDebian 13の単一Apps VMとDocker Composeへ置き換え、現在の機能を減らさない。
- Proxmoxインストール済みの状態からGit、Terraform、Ansible、Compose、SOPS/ageで再構築可能にする。
- NFS上の既存dataを最優先で保護し、新旧を同時writerにしない。
- VLAN 10/20/30/40への再編（Phase 4）は別windowで行う。application cutoverへ混ぜない。
- **Apps VMの削除・IaC再構築試験（Phase 3）に合格した日から14日間は旧Kubernetes VMを保持する。**
  この14日はまだ開始していない。
- `stashPadDev`（VMID 111）は作業用VMであり、この移行の対象外とする。

## 絶対に維持する安全条件

**writerの向きがcutoverで反転した。以下は2026-09-05時点の状態を前提とする。**

- **Apps VMが唯一のwriterである。Kubernetes側のworkloadを再開させない。**
  Flux Kustomization 4件はsuspend、対象Deployment 6件はreplicas=0、MetalLB speakerは停止、
  3つのLoadBalancer ServiceはClusterIP化されている。この状態を維持する。
- Kubernetes VMを起動したまま残しているが、writerではない。**Fluxをresumeしない。
  Deploymentをscale upしない。ServiceをLoadBalancerへ戻さない。** これらはrollback時にだけ行う。
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
- ZFS snapshot `@pre-compose-cutover-20260905`（4 dataset）を、Phase 3の再構築試験に合格するまで削除しない。

## 現在のシステム状態（2026-09-05 21:09 再確認）

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
- `/opt/homelab`は`origin/main` `e272c75`のcleanなcheckout。`homelab-app-reconcile.timer`はenabled/active。
- 稼働中imageのdigestはGit宣言と一致している。
- GatusのCaddy probeは`HTTP 308`を成功として観測している。PR #20の設定変更は、旧bind mount inodeを
  保持したcontainerを手動でforce-recreateして反映した。PR #21のreconcile/rollback修正もAnsibleで
  Apps VMへ反映済みである。
- NFS server側のopen stateは、Apps VMがstashPad prod/staging DBのrw openを保持する一方、
  Kubernetes worker 2台に残るのは旧Unboundの`hagezi-pro.txt`に対するread-only openだけである。
  想定外のwriterは観測されていない。

### Kubernetes（停止状態だがVMは起動中）

- VM 101/102/103は起動したままだが、application workloadは動いていない。
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

  変更前の完全なService定義JSONはセッションのscratchpadにのみ存在し、恒久保存されていない。
  必要なら`kubectl get svc -o json`で現状を再取得すること。
- Unboundは**旧ReplicaSet `external-unbound-588bcf9d7c`（revision 129）が正常な世代**である。
  新ReplicaSet `external-unbound-75dd79988f`（revision 288）は不正なRPZでCrashLoopする。

### ネットワーク

- IX2215のBVI11は`192.168.11.1/25`。**この`/25`は誤りで、期待値は`/24`である。修正はPhase 4で行う。**
- `interface BVI11`の`ip dhcp binding server_app-dhcp`を解除済み。**running-configのみで
  `write memory`は未実行。** ルータを再起動すると解除が失われる。
- VLAN 11のDHCP leaseは解除前から0件で、影響を受けるclientはない。
- `vmbr0.11`は`192.18.11.11/24`のまま（記録のみ、修正しない）。

### ZFS snapshot

cutover直前に4 datasetへ`@pre-compose-cutover-20260905`を取得済み。

- `tank-gen2/data/k8s-volumes`（それまでsnapshot 0件）
- `tank-gen1/data/archive`（それまでsnapshot 0件）
- `tank-gen2/data/shared`
- `cache-pool`（mergerfsのcache branch。HDD側datasetのsnapshotだけでは直近の書き込みを保護できない）

pve1のroot crontabにある`/usr/local/bin/mover.sh`（05:00）は`tank-gen2/data/shared`のみを
対象とする自家製snapshot/tieringである。cutover後も運用を継続する。

## 次に行う作業

### 1. 受入試験の残項目

自動確認できる範囲は合格済みである（7 FQDNのTLS、DNSの通常応答・内部record・ブロック、
stashPad prod/stagingの`200`、SillyTavernの`401`、SMB 445の到達性、image digestの一致）。

2026-09-05にユーザーが次の完了を申告した。

- 7 FQDN（`prod.stashpad.kojigenba-srv.com`、`staging.stashpad.kojigenba-srv.com`、
  `prod.kojigenba-srv.com`、`staging.kojigenba-srv.com`、`sillytavern.kojigenba-srv.com`、
  `dns.kojigenba-srv.com`、`status.kojigenba-srv.com`）の動作確認
- IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない隔離テスト

7 FQDNの動作確認は完了申告として記録するが、操作内容の内訳は記録されていないため、下記の
application別read/write項目を自動的に完了扱いにはしない。

ユーザーの確認が必要な項目。

- [ ] stashPad prod/stagingで閲覧、更新、upload、共有mediaを確認する
- [ ] stashPad prod/stagingのmetadataが分離されている
- [ ] SillyTavernでlogin、会話、設定保存を確認する
- [ ] Samba 3 shareを既存userでread/writeできる
- [x] IoT/Guest/Internetから管理UI、SSH、SMBへ到達できない（2026-09-05、ユーザー確認）

サービス断を伴うため実施タイミングの合意が必要な項目。

- [ ] Apps VM reboot後にmountと全serviceが自動復旧する
- [ ] NFS未mountまたはmarker不一致ならapplicationが起動しない（fail-closed）

発火させないと確認できない項目。

- [ ] Gatusが障害と復旧をDiscordへ通知する
- [ ] Healthchecks.ioがdead-man停止を通知する

### 2. 受入試験の合格後

- [ ] IX2215で`write memory`を実行し、DHCP binding解除を保存する
- [ ] Kubernetes VMを停止する（削除はしない）。安定を確認してからでよい

### 3. Phase 3: 再構築性の証明

Kubernetes VMの14日保持期間を開始する前に実施する。手順は
[移行手順書](k8s-to-compose.md)のフェーズ3に従う。snapshot restoreで代替してはならない。

**合格した日が、Kubernetes VM 14日保持期間の開始日である。**

### 4. Phase 4: ネットワーク移行

別のmaintenance windowで実施する。application cutoverへ混ぜない。含まれるのは次である。

- BVI11の`/25`→`/24`修正と、それに伴うACL（`server_app-out`）の更新
- `files/infrastructure/network/README.md`と`config.txt`の反映（ユーザー管理。勝手に触らない）
- Tailscale live ACLのexport、Terraform import、global nameserverの`192.168.10.101`への変更
- VLAN 10/20/30/40への再編、ECW5211の設定、Apps VMの`192.168.10.101`への集約
- MetalLB pool（`.100-.200`）が`/25`を超えている不整合の解消（MetalLBごと廃止で自然に消える）

### 5. Phase 5: 廃止

再構築試験から14日経過し、rollbackが発生していないことを条件とする。詳細は移行手順書に従う。
`k8s-volumes`配下のorphan directory 7件（`openldap-*` 3世代、旧`external-dns-blocklist-*` 2世代、
旧stashpad prod/staging各1世代）の削除判断もここで行う。

## rollback手順

新旧を同時にwriterにしないことを最優先する。

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
8. **Unboundは旧ReplicaSetで復旧する。** 単に`replicas=1`にすると新Podが不正なRPZで再度
   CrashLoopする。復旧前にNFS server上で
   `/mnt/tank-gen2/data/k8s-volumes/external-dns-blocklist-data-pvc-8e7db6e1-.../rpz/hagezi-tif.txt`
   を退避すること。
9. Flux Kustomization 4件をresumeする。
10. IX2215で`interface BVI11`に`ip dhcp binding server_app-dhcp`を再投入する。
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
- Phase 3の再構築試験に合格していないのにKubernetes VMを削除しようとしている。
- rollback手順、OOB access、maintenance window、ユーザーの明示許可のいずれかがない。

## 作業対象外・worktree保護

- `files/infrastructure/network/README.md`
- `files/infrastructure/network/config.txt`

上記2ファイルには、この移行作業開始前からのユーザー変更（VLAN 11を`/25`から`/24`へ改める期待値）が
ある。明示依頼なしに編集、破棄、整形、stage、commitしない。選択的にstageし、commit前に
`git diff --cached --name-only`で対象を確認する。

次も現時点では行わない。

- Kubernetes VM、PVC、NFS data、ZFS dataset、cutover snapshotの削除
- IX2215、ECW5211、VLAN、DHCPの追加変更（`write memory`と承認済みwindowを除く）
- `vmbr0.11`の修正・削除
- Tailscale DNS/ACL/routeのapply
- `stashPadDev`（VMID 111）の変更

コード変更が必要な作業は、ユーザーの希望により可能な限りsonnetの補助agentへ委譲する。ただし、この
指示書の最終編集はprimary agentが実施した。設計・運用文書は日本語で記述する。

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

- PR #7、#9、#14、#15、#16、#17、#18、#19、#20、#21、#22はmainへmerge済みで、各CIは成功済み。
- `origin/main`は`e272c75`。
- toolbox `ghcr.io/koji-genba/homelab-toolbox:1.0.1`は公開済み。
  digestは`sha256:7607f2c74300504e045b2649ce4032920885c1902dd22c01b4c220fc7067dad0`。
- Caddy custom imageを含む7 projectのimageはdigest固定済み。

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
