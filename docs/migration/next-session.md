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

- 管理端末のTailscaleは、Apps VM停止中にtailnet DNSへ依存しないようユーザーが切断済み。
  作業はApps VM `192.168.10.42`とPVE `192.168.10.11`へのLAN直指定で実施した。
- IX2215のBVI11は`192.168.11.1/24`。2026-09-05にユーザーが`/25`から`/24`へ修正し、
  `write memory`でstartup-configへ保存済みである。
- `interface BVI11`の`ip dhcp binding server_app-dhcp`を解除済み。2026-09-05にユーザーが
  `write memory`を実行し、解除後のrunning-configをstartup-configへ保存した。
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

### 1. 受入試験の結果

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

### 2. IX2215構成ドリフトの解消（完了）

2026-09-05にユーザーがIX2215のCLIで次を実施し、`write memory`まで完了した。

1. `interface BVI11`の`ip address`を`192.168.11.1/25`から`/24`へ変更した。新しい`ip address`の
   投入で上書きされ、`no ip address`は不要だった。`show ip route`で
   `C 192.168.11.0/24 ... BVI11`を確認した。
2. ACL 3本の`192.168.11.0/25`を`/24`へ更新した。`server_app-out`（srcの5エントリ）、
   `default-out`（destの1エントリ）、`guest-out`（destの1エントリ）。`iot-out`、`main-out`、
   `server-out`は元から`/24`で無変更だった。
3. 事後確認として、BVI63に`ip filter default-out 10 in`、BVI40に`ip filter guest-out 10 in`が
   戻っていることと、Guest VLAN 40の端末から`192.168.11.100`へ到達できないことを実測した。
   そのうえで`write memory`を実行し、running-configをstartup-configへ保存した。
4. あわせてrunning-configをソフトウェアバージョン10.11.6（`Compiled May 22-Thu-2025`）と照合し、
   `config.txt`・`README.md`を記録上の10.7.18から更新した。実機にある`system interfaces bvi 64`を
   `config.txt`へ追加し、`sflow`設定2行は実機にも存在したため記録上の位置を実機の順序へ移動した。
   さらに実機の`show running-config`全文を`config.txt`と照合し、注釈コメントと`!`の区切り行を
   除く293行が行の集合として完全に一致することを確認した。
5. 照合の過程で、`config.txt`に実機へ存在しない`interface GigaEthernet2.0`の重複定義
   （`no ip address`と`shutdown`のみを持つblock）が残っていたため削除した。実機の
   GigaEthernet2.0は`bridge-group 63`かつ`no shutdown`である。**この重複を残したまま
   `config.txt`を実機へ投入すると、untaggedポートを`shutdown`する危険があった。**
6. `config.txt`は注釈付きの記録であり、`show running-config`の逐語dumpではない。内容は一致するが
   blockの並び順が3箇所で異なる。`device GigaEthernet2`内のsflowとvlan-groupの順、
   `interface GigaEthernet2.0`の位置、`interface GigaEthernet2:1.0`から`2:6.0`までの位置である。
   次回照合する際は行の並びではなく行の集合として比較すること。

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

### 3. Kubernetes VMの停止

- [x] 上記のIX2215構成ドリフトを解消する（2026-09-05）
- [ ] Kubernetes VMを停止する（削除はしない）。停止後にApps側の安定を再確認する

### 4. Phase 3: 再構築性の証明

Kubernetes VMの14日保持期間を開始する前に実施する。手順は
[移行手順書](k8s-to-compose.md)のフェーズ3に従う。snapshot restoreで代替してはならない。

**合格した日が、Kubernetes VM 14日保持期間の開始日である。**

### 5. Phase 4: ネットワーク移行

別のmaintenance windowで実施する。application cutoverへ混ぜない。含まれるのは次である。

- `files/infrastructure/network/README.md`と`config.txt`の反映（ユーザー管理。勝手に触らない）。
  BVI11の`/24`化と実機バージョン整合は2026-09-05に反映済みのため、Phase 4で残るのは
  VLAN 10/20/30/40再編に伴う変更に限る
- Tailscale live ACLのexport、Terraform import、global nameserverの`192.168.10.101`への変更
- VLAN 10/20/30/40への再編、ECW5211の設定、Apps VMの`192.168.10.101`への集約

### 6. Phase 5: 廃止

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
- Phase 3の再構築試験に合格していないのにKubernetes VMを削除しようとしている。
- rollback手順、OOB access、maintenance window、ユーザーの明示許可のいずれかがない。

## 作業対象外・worktree保護

- `files/infrastructure/network/README.md`
- `files/infrastructure/network/config.txt`

上記2ファイルにあった、この移行作業開始前からのユーザー変更（VLAN 11を`/25`から`/24`へ改める
期待値）は、2026-09-05にユーザーの明示的な承認のもとで実機へ適用したうえでcommit済みであり、
未commitの変更はもう残っていない。ただし両ファイルは引き続きユーザー管理であり、明示依頼なしに
編集、破棄、整形、stage、commitしない。選択的にstageし、commit前に
`git diff --cached --name-only`で対象を確認する。

次も現時点では行わない。

- Kubernetes VM、PVC、NFS data、ZFS dataset、cutover snapshotの削除
- IX2215、ECW5211、VLAN、DHCPの追加変更（2026-09-05に承認済みwindowで実施したBVI11 prefix変更・
  ACL更新と、`write memory`を除く）
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
