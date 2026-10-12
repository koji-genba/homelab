# sparkDash運用

- 状態: 2026-10-11にApps VMへdeploy済み。DGX 2台を登録済み
- 関連: [アプリ更新・promotion・rollback](application-lifecycle.md)、[Apps VM復旧](apps-vm-recovery.md)
- 対象: `sparkdash` Compose project（`https://sparkdash.kojigenba-srv.com`）
- 上流: [MiaAI-Lab/sparkDash](https://github.com/MiaAI-Lab/sparkDash)（Apache-2.0）

## 用途と構成

Apps VM上のsparkDashはDGX Sparkのremote monitorとして使う。Apps VMにはGPUがなく、local unitを
登録しない。構成は `Browser -> Caddy -> sparkDash -> SSH/HTTP -> DGX` である。

- imageは2.31.0の公開linux/amd64 imageをdigestで固定する。定義は
  `files/services/compose/sparkdash/compose.yaml`、project名は`homelab-sparkdash`
- `BIND_HOST=0.0.0.0`、`PORT=5555`でDocker network内だけにlistenする。host portは公開しない
- Caddyの`admin_networks`で信頼network/tailnetからの接続だけを許可する。アプリのBearer認証が
  `Authorization`を使うため、Caddy Basic Authは追加しない
- `SPARKDASH_ALLOW_OPEN_REMOTE=0`を明示し、token未設定なら起動を拒否する。上流READMEの
  fail-closedという説明にかかわらず、コードのdefaultはopenというphase 1確認結果に基づく設定である
- uid:gid `10001:10001`、`read_only: true`、`cap_drop: ALL`、`no-new-privileges`。
  書込み先は`/app/config`とtmpfsの`/tmp`だけ。hostのGPU、proc/sys、Docker socket、SSH agentを渡さない
- 新しいhost portがないためnftables変更は不要。既存443経路と、許可済みのDGX向けegressを使う

以下の上流動作はphase 1の確認済みimage contractに基づく。このフェーズでは上流ソースの再取得は
行えていない。実imageの起動は2026-10-11に確認した。更新時は固定revisionの実装を再確認する。

## secretとSSH identity

必須keyはSOPS bundleの`sparkdash.token`で、64文字の16進値を使う。
Ansibleは`/etc/homelab/secrets/sparkdash.env`へ`SPARKDASH_TOKEN=...`をroot:root `0600`で配置する。
`env_file`は`format: raw`で読み、healthcheckもcontainer自身の環境変数からtokenを取る。

任意keyは`sparkdash.ssh_private_key`。専用の、passphraseなしのEd25519秘密鍵を複数行の文字列として
保存する。Ansibleは鍵の有無にかかわらず`/etc/homelab/secrets/sparkdash-ssh`を`10001:10001 0500`で作り、
値があれば`id_ed25519`を`10001:10001 0400`で配置する。directory全体を`/run/sparkdash-ssh`へread-only
mountし、`SSH_IDENTITY_FILE=/run/sparkdash-ssh/id_ed25519`とする。Composeの`create_host_path: false`は
Ansible未反映時の自動directory作成も防ぐ。存在しないsingle fileのbind mountは使わない。

鍵が未生成でもAnsibleとアプリは進められる（アプリにはwarningが出る）。任意keyを省略または空にして
再applyすると、配置済みの秘密鍵も削除する。DGX側の`authorized_keys`からの削除も人が行う。
secret、directory permission、鍵の追加・変更・削除は既存のchange flagへ合流し、全projectを
force-recreateする。SOPS bundleへの鍵追加でもDNS/SMBを含む全projectが数分間中断する。
値は`no_log`で扱う。age private keyをApps VMへ渡してはならない。

鍵配置後の`/api/health`のwarningは`Secrets key is not present yet`だけとなった。アプリがsecretを
保存するまで残る無害なwarningで、鍵認証だけを使う運用では暗号鍵が作られず残り続ける可能性がある。

## DGX側の準備とunit登録

DGX `.51` / `.52`の監視account・authorized_keysとUIのunit設定はGitから復元できず、復旧範囲はDGXの手動準備とApps VMのnamed volumeに分かれる。

DGXごとに専用の非root account `sparkdash-monitor`を作り、SSHはpublic key認証だけを許可する。
sudo、docker、adm groupには追加しない。監視に必要な情報が読めることを確認する。
アプリは登録scriptの実行やhost shutdownをそのaccount経由で試みられ、単一Bearer tokenはそれらも含む
全操作権限を持つ。監視用途でもDGX側accountの権限が境界になる。shutdownなどが権限不足で失敗する
構成を維持する。

管理端末の安全なrepo外directoryで作成する。生成した値や秘密鍵をGitやlogへ貼らない。

```sh
umask 077
ssh-keygen -t ed25519 -N '' -C sparkdash-monitor -f ~/sparkdash_monitor_id
```

各DGXの管理accountで専用accountを作る。このDGXでは`adduser`が既定で`users`（gid 100）にも
追加したため、同groupから削除する。両hostとも`id`が専用account自身のgroupだけを示すことを確認した。

```sh
sudo adduser --disabled-password --gecos 'sparkDash monitor' sparkdash-monitor
sudo gpasswd -d sparkdash-monitor users
id sparkdash-monitor
```

公開鍵（`~/sparkdash_monitor_id.pub`）だけをDGX専用accountの`~/.ssh/authorized_keys`へ登録する。
DGX側は`.ssh`を`0700`、`authorized_keys`を`0600`とし、秘密鍵はDGXにcopyしない。
管理端末から専用鍵で両hostへ接続し、`id`、`nvidia-smi -L`の成功と`sudo -n true`の拒否を確認する。

```sh
ssh -i ~/sparkdash_monitor_id sparkdash-monitor@192.168.10.51 'id; nvidia-smi -L; sudo -n true'
ssh -i ~/sparkdash_monitor_id sparkdash-monitor@192.168.10.52 'id; nvidia-smi -L; sudo -n true'
```

DGXは`192.168.10.51`と`192.168.10.52`のNVIDIA GB10で、GLM-5.3-flashを2台に分割して実行する。
vLLM APIはheadの`.51:8000`だけでlistenし、workerの`.52:8000`はclosedである。
Apps VM上で両hostの22と8000への到達性を次の形で確認した。`.52:8000`の失敗は想定どおりである。

```sh
timeout 3 bash -c "</dev/tcp/<host>/<port>"
```

新しいネットワーク例外が必要なら先にGitへ送信元・宛先・port・目的・廃止条件を記録する。

起動後、HTTPSのUIへtokenを入力してDGX unitを登録する。

- `isLocal: false`とDGXのaddressを指定する
- 上流default SSH userはrootなので、専用account名を明示する。passwordは登録せず専用鍵を使う
- `.51`はrole `head`、LLM port `8000`で登録する。image defaultの8888に頼らず、Composeには固定値を追加しない
- `.52`はrole `worker`、headを`.51`として登録する。worker unitはLLM monitoringが強制的に無効になる
- Hermes monitoringは常に無効にする。上流probeがgit lockを削除し、updateを実行するためである
- ComfyUI monitoringは必要な場合だけ有効にする。初期登録時は無効にする

SSHは`StrictHostKeyChecking=accept-new`で接続し、初回に見えたhost keyを信頼する。
unit登録後、containerの`known_hosts`と各DGX自身のhost key fingerprintを必ず照合する。
Apps VMで次を各hostについて実行する。

```sh
sudo docker exec homelab-sparkdash-sparkdash-1 ssh-keygen -l -F <host> -f /app/config/.ssh/known_hosts
```

各DGXへ専用accountで接続し、次を実行する。2026-10-11の照合ではすべて一致した。

```sh
for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
```

unit追加・削除後はFleet energy画面に
`Fleet membership changed. Restart sparkDash to establish a truthful new accounting scope.`と表示される。
energy trackerは起動時のnode集合を固定する（`server/energy/FleetEnergyTracker.js`の`invalidateMembership`）
ため、再起動まで集計を表示しない。登録後は次で再起動する。token counterはもともと永続化されず、
registry/settingsはvolumeに残るため、この再起動で失われるものはない。

```sh
ssh deploy@192.168.10.101 'sudo docker compose --project-name homelab-sparkdash --env-file /etc/homelab/compose.env -f /opt/homelab/files/services/compose/sparkdash/compose.yaml restart'
```

秘密鍵はSOPS bundleへ保存し、監視が動作したら管理端末の平文fileを削除する。

```sh
shred -u ~/sparkdash_monitor_id
```

## 初回反映の順序

新規projectのため、既存helperを先に差し替えてはならない。[共通手順](application-lifecycle.md)に従い、
次の順番で人が反映する。named volumeなのでpve1のNFS directory/marker作成は不要である。

1. このCompose追加PR（#76、imageは#75）をreviewしてmergeする。merge前にはtoken・DGX accountを準備し、
   optional SSH鍵が未準備でもtokenは必ず用意する。検証結果を確認し、既存サービスの短い中断を見込む
2. 15分のreconcileを待つ（または人が`homelab-app-reconcile.service`を起動する）。Apps VMの
   `/opt/homelab`がmerge commitまで進み、`sparkdash/compose.yaml`が存在することを確認する。
   AnsibleのGit taskは`update: false`なので、この順序を省くとdigest gateで失敗する。
   deploy userは`/opt/homelab`を読めないため、確認にもsudoを使う。

   ```sh
   ssh deploy@192.168.10.101 'sudo git -C /opt/homelab log --oneline -1'
   ssh deploy@192.168.10.101 'sudo test -f /opt/homelab/files/services/compose/sparkdash/compose.yaml'
   ```

   古いhelperはsparkDashを起動しない。Caddy/Gatusの再作成は先に行われ、project起動までは赤のalert、
   起動後は緑のresolved通知を見込む。PR #78でGatusは`gatus` named volumeのsqliteへtriggered-alert stateを
   永続化し、障害中に再作成されてもresolved通知が届くようになった。修正前の初回rolloutでは赤だけが届いた
3. 管理端末で以下のSOPS編集を行い、暗号化bundleへ新しいkeyを追加する。
   `make secrets-encrypt`は既存bundleの上書きを拒否するので編集には使わない。
   管理端末にはhost版SOPSもeditorもないため、Makefileと同じdigest固定toolboxの`sops set`を使う。
   tokenはshellで生成して手入力せず、既存keyは保持する。

   ```sh
   export AGE_IDENTITY_FILE=/secure/path/age-identity.txt
   TOOLBOX_IMAGE=ghcr.io/koji-genba/homelab-toolbox@sha256:9da8408a19624df8b4da2fbcde93d64eddd5c6414e77e59c0e0e6f51b7ec8037
   sops_toolbox() {
     docker run --rm --user "$(id -u):$(id -g)" \
       -v "$PWD:/workspace" -w /workspace \
       -v "$AGE_IDENTITY_FILE:/run/secrets/age-identity:ro" \
       -e SOPS_AGE_KEY_FILE=/run/secrets/age-identity \
       -e HOME=/tmp/homelab-toolbox "$TOOLBOX_IMAGE" sops "$@"
   }
   TOKEN=$(openssl rand -hex 32)
   sops_toolbox set files/infrastructure/secrets/runtime.sops.yaml '["sparkdash"]["token"]' "\"$TOKEN\""
   unset TOKEN
   chmod 0600 files/infrastructure/secrets/runtime.sops.yaml
   AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make secrets-decrypt-check
   ```

   tokenは次で一度だけ表示してKeePassXCへ保存する。表示値をlogへ残さない。

   ```sh
   sops_toolbox decrypt --extract '["sparkdash"]["token"]' files/infrastructure/secrets/runtime.sops.yaml
   ```

   鍵を使う場合はhostの`jq`で複数行をJSON文字列にして設定する。実rolloutではtokenをPR #77、鍵をPR #79で追加した。

   ```sh
   sops_toolbox set files/infrastructure/secrets/runtime.sops.yaml '["sparkdash"]["ssh_private_key"]' "$(jq -Rs . < ~/sparkdash_monitor_id)"
   chmod 0600 files/infrastructure/secrets/runtime.sops.yaml
   ```

   `sops set`は値を引数で渡すため、単独利用の管理端末でも短時間process listに見える。
   `sops set`はfileを`0644`で書き直すため、編集後は`chmod 0600`を行う。
   未準備なら`ssh_private_key: ""`またはkey省略にする。`runtime.yaml.example`は形式だけの参照で、
   実値を入れない。暗号化bundleだけを専用branch/PRでcommitする。
   その変更がmergeされた場合も、次のapply前にVM checkoutが追いついていることを確認する
4. 同じshellでSSH agentを起動し、`ssh-add -l`に`deploy`用鍵が表示されることを確認して、管理端末の
   最新checkoutから適用する。Gitのcheckout/mergeでもbundleは`0644`に戻るため、apply直前にもmodeを設定する

   ```sh
   eval "$(ssh-agent -s)"
   ssh-add ~/.ssh/id_ed25519
   ssh-add -l
   chmod 0600 files/infrastructure/secrets/runtime.sops.yaml
   AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make ansible-apply
   eval "$(ssh-agent -k)"
   ```

   agent停止は必ず`eval "$(ssh-agent -k)"`で環境変数も解除する。単なる`ssh-agent -k`では
   `SSH_AUTH_SOCK`が死んだsocketを指したままになり、Dockerがそのpathにroot所有directoryを作って
   toolboxのSSHが`Permission denied (publickey)`で失敗する。

   secrets、AdGuard rewrite、helperが再描画され、宣言済みの全projectがforce-recreateされる。
   対象一覧の正は`homelab-compose-up.sh.j2`の`all`である。
   初回のimage pullを伴い、DNS/SMBも短時間途切れる。途中でdigest gateに失敗した場合、次回applyでは
   secretが変更なしとなる可能性があるため、正常終了後も起動を明示確認する
5. Apps VMで明示startup checkを行い、以下の受入一覧を確認する

   ```sh
   ssh deploy@192.168.10.101 sudo /usr/local/sbin/homelab-compose-up sparkdash
   ssh deploy@192.168.10.101 sudo docker compose --project-name homelab-sparkdash \
     --env-file /etc/homelab/compose.env \
     -f /opt/homelab/files/services/compose/sparkdash/compose.yaml ps
   ```

## 永続化・backup・復旧

`/app/config`は専用named volume `homelab-sparkdash_sparkdash-config`へ保存する。Caddyのstateや
SearXNG cacheと同じvolume方式で、初回はimageの`10001:10001 0700`を引き継ぎ、手動chownを不要にする。
Open WebUI/stashPadのNFS方式は既存dataとの互換性のためであり、このprojectは新規stateなので使わない。
新しいNFS mount/markerは追加しないが、共通lifecycleの既存mount guardはsparkDash起動時にも通過する。

現在volumeで保持するのはunit登録（`sparks.json`）、settings、historyと`/app/config/.ssh/known_hosts`で、
専用SSH identityとBearer tokenはSOPSから再配置できる。tmpfsのSSH ControlPath socketは永続化しない。
アプリにpassword/API key等のsecretを保存した場合は、secret暗号鍵とAES-GCM ciphertextも同じvolumeへ入る。
その場合、backup全体をsecretとして扱う。

2026-10-11時点では自動backupを構築せず、VM外の暗号化backupも必須としない。
NFS/ZFS snapshot、mover、Terraform state-backupにはこのvolumeが含まれない。
Proxmox VM backupの実際の設定・復旧可否は別途確認する。
unit数、benchmark結果、保存secretが増えた場合はbackup方針を見直す。特に保存secretは暗号鍵が
ciphertextと同じvolumeにあることを考慮する。

volume喪失時は同じproject名で再deployしてvolumeを再作成し、SOPSからtoken・SSH鍵を再配置する。
UIで2台のunitを再登録する復旧は約5分を見込む。unit/settings/historyは元に戻らず、
known_hostsのhost fingerprint照合とFleet energyのための再起動も登録手順に従って行う。
通常の停止に`down -v`は使わない。

## 監視と確認

Compose healthcheckはNodeのfetchでBearer付き`/api/health`を呼び、HTTP成功かつJSONの`ok === true`を
要求する。30秒間隔、5秒timeout、3 retries、30秒start period。warningsがあっても`ok:true`ならhealthyで、
DGX到達性や各monitorの成功を保証しない。Gatusはtokenを持たず`http://sparkdash:5555/`の200だけを監視し、
隣接endpointと同じdefault interval・Discord alertを使う。

2026-10-11の2回の`make ansible-apply`はいずれも`failed=0`で完了し、containerはhealthy、frontendは200、
`/api/health`はtokenなしで401、正しいBearer token付きで`ok:true`を確認した。
WSL管理端末には`nslookup`がないため、DNS確認は次を使う。期待値はApps VMのtailnet IP `100.86.147.127`である。

```sh
getent hosts sparkdash.kojigenba-srv.com
```

| 確認 | 期待値 |
| --- | --- |
| Compose `ps`とimage参照 | sparkdashのみ、healthy、指定digest |
| secretのmetadata（内容は表示しない） | envはroot:root 0600、SSH dirは10001:10001 0500、鍵があれば0400 |
| uidとconfigへの書込み・再作成後のunit保持 | uid/gid 10001、configが永続化される |
| host listener | 5555のhost公開なし |
| WSL管理端末には`nslookup`がないため、代わりに`getent hosts sparkdash.kojigenba-srv.com`でsystem resolverを使った管理端末の実際の名前解決を確認 | `100.86.147.127` |
| 信頼tailnetからのHTTPS frontend | 200、正しいTLS証明書、UIにtoken入力可 |
| 信頼network外からのroute | 403 |
| tokenなし・誤tokenの`/api/health` | 401 |
| 正しいBearerの`/api/health` | 200かつ`ok:true`。tokenを履歴/logに残さないclientで確認 |
| SSH鍵なし | warningのみで起動可能。任意keyなしのapplyも成功 |
| DGX登録と観測 | remote unit、専用非root user、実LLM port、Hermes無効 |
| Gatus / Healthchecks.io | frontend正常、dead-man復帰。DGX監視の成否はUIで別確認 |
| volume喪失時の復旧方針 | 自動backupなし。再deploy・SOPS再配置・UIで2台を再登録（約5分）。unit数・benchmark結果・保存secretが増えたら見直す |

## image更新とrollback

上流更新は`files/services/images/sparkdash/Dockerfile`の`SPARKDASH_REVISION`（40文字commit SHA）、
`org.opencontainers.image.version`、`.github/workflows/sparkdash-image.yml`のpublish tagを同時に更新する。
review後にworkflowを実行し、job summaryのimmutable digestを取得する。別変更で
`sparkdash/compose.yaml`のdigestとreview用version commentを更新し、通常reconcileで反映する。
DependabotはNode base imageを追跡するが、上流revision/versionを自動更新しない。
image directory差分にもedgeと同様のreconcile mappingがあり、Composeのdigestを変えなければ同じimageを
再作成する。publishだけでは新imageへ切り替わらない。

data互換性と上記の復旧方針を確認した上で次を人が実行する。対象SHAにはsparkdashのCompose定義が必要である。

```sh
PROJECT=sparkdash ROLLBACK_SHA=<known-good-commit> APPS_HOST=192.168.10.101 make rollback-app
```

rollbackはreconcileをpauseし、image/configだけを戻す。volumeのschema、secret、DGX側の操作は戻さない。
pause解除・pending再反映は[共通手順](application-lifecycle.md)に従う。初回追加より前のSHAへは戻せない。

## 既知の制約

- AdGuardの`web_ip`は現在tailnet IPである。TailscaleのないLAN clientはこの新hostnameを通常のLAN DNSで
  解決できず、AdGuardへ直接問い合わせても返るtailnet addressへ到達できない。この制約を現状受け入れる
- frontend HTMLの`/`は認証なしで200を返す。APIはtoken必須で、共有tokenによる全権限付与である
- tokenはbrowserのlocalStorageに保存され、WebSocketでは`?token=`にも入る。browserはHTTPS経路だけを
  使用し、URL・request header・queryを共有/logへ保存しない
- SSHは`accept-new`で初回接続を信頼する。DGX host key fingerprintは初回に別経路で照合し、変更時に
  安易にknown_hostsを消さない
- plain `node server/index.js`で起動するため、`--watch`前提のrestart buttonは利用しない
- Fleet energyは起動時のnode集合を固定する。unit追加・削除でmembership変更の表示が出たら、
  上記のCompose restartを行うまで集計は表示されない。token counterは永続化されず、registry/settingsはvolumeに残る
- Hermes probeの副作用はcontainer hardeningでは防げない。DGX unitの設定で無効を維持する

## 手動反映の記録

| 日付 | 操作者 | 反映内容 | commit / 確認結果 |
| --- | --- | --- | --- |
| 2026-10-11 | — | Compose project追加PR #76をmerge | image PR #75に続きCompose定義を反映 |
| 2026-10-11 | — | SOPS token追加PR #77 | `sparkdash.token`をbundleへ追加 |
| 2026-10-11 | — | `make ansible-apply` 1回目 | failed=0 |
| 2026-10-11 | — | Gatus修正PR #78 | named volumeのsqliteでalert stateを永続化、digest固定Gatus imageを使った検証用のDocker再現で再起動後のresolved通知を確認。本番での確認は次の再起動後 |
| 2026-10-11 | — | SOPS SSH鍵追加PR #79 | `sparkdash.ssh_private_key`をbundleへ追加 |
| 2026-10-11 | — | `make ansible-apply` 2回目 | failed=0、鍵配置後のwarningはSecrets key未作成だけ |
| 2026-10-11 | — | DGX account作成・unit登録 | 両hostのusers所属を削除、専用groupのみ・GPU参照可・sudo拒否を確認。.51 head（8000）、.52 worker（head .51）を登録 |
| 2026-10-11 | — | host key fingerprint照合 | containerのknown_hostsと各DGX自身のhost keyがすべて一致 |

個人ID、token、秘密鍵、NodeIDはこの表に記録しない。
