# sparkDash運用

- 状態: Compose定義を追加。実ホストへの反映・受入確認は未実施
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

以下の上流動作はphase 1の確認済みimage contractに基づく。このフェーズでは上流ソースの再取得と
実imageの起動確認は行えていない。更新時は固定revisionの実装を再確認する。

## secretとSSH identity

必須keyはSOPS bundleの`sparkdash.token`で、64文字の16進値を使う。
Ansibleは`/etc/homelab/secrets/sparkdash.env`へ`SPARKDASH_TOKEN=...`をroot:root `0600`で配置する。
`env_file`は`format: raw`で読み、healthcheckもcontainer自身の環境変数からtokenを取る。

任意keyは`sparkdash.ssh_private_key`。専用の、passphraseなしのEd25519秘密鍵をYAML block scalarで
保存する。Ansibleは鍵の有無にかかわらず`/etc/homelab/secrets/sparkdash-ssh`を`10001:10001 0500`で作り、
値があれば`id_ed25519`を`10001:10001 0400`で配置する。directory全体を`/run/sparkdash-ssh`へread-only
mountし、`SSH_IDENTITY_FILE=/run/sparkdash-ssh/id_ed25519`とする。Composeの`create_host_path: false`は
Ansible未反映時の自動directory作成も防ぐ。存在しないsingle fileのbind mountは使わない。

鍵が未生成でもAnsibleとアプリは進められる（アプリにはwarningが出る）。任意keyを省略または空にして
再applyすると、配置済みの秘密鍵も削除する。DGX側の`authorized_keys`からの削除も人が行う。
secret、directory permission、鍵の追加・変更・削除は既存のchange flagへ合流し、全projectを
force-recreateする。値は`no_log`で扱う。age private keyをApps VMへ渡してはならない。

## DGX側の準備とunit登録

DGXごとに専用の非root account（例: `sparkdash-monitor`）を作り、sudoを付与せず、SSHはpublic key認証
だけを許可する。監視に必要な情報が読めることを確認し、docker group等の管理権限も安易に与えない。
アプリは登録scriptの実行やhost shutdownをそのaccount経由で試みられ、単一Bearer tokenはそれらも含む
全操作権限を持つ。監視用途でもDGX側accountの権限が境界になる。shutdownなどが権限不足で失敗する
構成を維持する。

管理端末の安全なrepo外directoryで作成する。生成した値や秘密鍵をGitやlogへ貼らない。

```sh
umask 077
openssl rand -hex 32
ssh-keygen -t ed25519 -N '' -C sparkdash-monitor -f /secure/path/sparkdash_id_ed25519
```

tokenをKeePassXCにも保存し、公開鍵（`.pub`）をDGX専用accountの`~/.ssh/authorized_keys`へ登録する。
DGX側は`.ssh`を`0700`、`authorized_keys`を`0600`とし、秘密鍵はDGXにcopyしない。
SSH port、LLM HTTP portがApps VMから到達できることも確認する。新しいネットワーク例外が必要なら
先にGitへ送信元・宛先・port・目的・廃止条件を記録する。

起動後、HTTPSのUIへtokenを入力してDGX unitを登録する。

- `isLocal: false`とDGXのaddressを指定する
- 上流default SSH userはrootなので、専用account名を明示する。passwordは登録せず専用鍵を使う
- LLM portは各unitで実際のportを設定する。image defaultの8888に頼らず、Composeには固定値を追加しない
- Hermes monitoringは常に無効にする。上流probeがgit lockを削除し、updateを実行するためである
- ComfyUI monitoringは必要な場合だけ有効にする。初期登録時は無効にする

## 初回反映の順序

新規projectのため、既存helperを先に差し替えてはならない。[共通手順](application-lifecycle.md)に従い、
次の順番で人が反映する。named volumeなのでpve1のNFS directory/marker作成は不要である。

1. このCompose追加PRをreviewしてmergeする。merge前にはtoken・DGX account・backup先を準備し、
   optional SSH鍵が未準備でもtokenは必ず用意する。検証結果を確認し、既存サービスの短い中断を見込む
2. 15分のreconcileを待つ（または人が`homelab-app-reconcile.service`を起動する）。Apps VMの
   `/opt/homelab`がmerge commitまで進み、`sparkdash/compose.yaml`が存在することを確認する。
   AnsibleのGit taskは`update: false`なので、この順序を省くとdigest gateで失敗する。
   古いhelperはsparkDashを起動しない。Caddy/Gatusの再作成は先に行われ、一時的にGatusが失敗し得る
3. 管理端末で以下のSOPS編集を行い、暗号化bundleへ新しいkeyを追加する。
   `make secrets-encrypt`は既存bundleの上書きを拒否するので編集には使わない。
   下記はhost版SOPSとeditorがある管理端末で実行する（toolboxにはeditorを同梱していない）

   ```sh
   export AGE_IDENTITY_FILE=/secure/path/age-identity.txt
   SOPS_AGE_KEY_FILE="$AGE_IDENTITY_FILE" sops edit files/infrastructure/secrets/runtime.sops.yaml
   AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make secrets-decrypt-check
   ```

   既存keyは保持して、`sparkdash.token`に生成した64文字の16進tokenを設定する。
   鍵を使う場合は`sparkdash.ssh_private_key: |`の下へ秘密鍵の全行をindentして保存する。
   未準備なら`ssh_private_key: ""`またはkey省略にする。`runtime.yaml.example`は形式だけの参照で、
   実値を入れない。人が暗号化bundleのみをreview済み変更としてGitへ保存する。
   その変更がmergeされた場合も、次のapply前にVM checkoutが追いついていることを確認する
4. SSH agentの`deploy`用鍵を確認して、管理端末の最新checkoutから適用する

   ```sh
   AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" make ansible-apply
   ```

   secrets、AdGuard rewrite、helperが再描画され、全10 projectsがforce-recreateされる。
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

volumeには`sparks.json`、settings、secret暗号鍵、AES-GCM ciphertext、history、
`/app/config/.ssh/known_hosts`が入る。鍵とciphertextが同じvolumeにあるため、backup全体をsecretとして
扱う。tmpfsのSSH ControlPath socketは永続化しない。専用SSH identityとBearer tokenはSOPSから再配置できる。

運用者はunit/secret変更前とimage更新前にsparkDashを停止し、volume全体をUID/GID・modeを保持した形で
暗号化backupし、Apps VM外の保管先へcopyする。定期backupも運用者が設定する。このrepoにはnamed volume
backupの自動化がなく、NFS/ZFS snapshot、mover、Terraform state-backupにはこのvolumeが含まれない。
Proxmox VM backupの実際の設定・復旧可否は別途確認する。backup先と復旧試験が未確定のまま登録したstateを
唯一のcopyとして扱わない。

復旧時は同じproject名でvolumeを用意し、停止中に全内容と`10001:10001 0700`のdirectory権限を復元する。
暗号鍵とciphertextを必ず同じbackupから戻し、SOPSからtoken・optional SSH鍵を再配置して起動する。
known_hostsを失った場合はhost fingerprintを別経路で確認してから再接続する。volumeを失っても新規起動は
できるが、unit/settings/historyと暗号化secretは復元できず再登録が必要になる。`down -v`は使わない。

## 監視と確認

Compose healthcheckはNodeのfetchでBearer付き`/api/health`を呼び、HTTP成功かつJSONの`ok === true`を
要求する。30秒間隔、5秒timeout、3 retries、30秒start period。warningsがあっても`ok:true`ならhealthyで、
DGX到達性や各monitorの成功を保証しない。Gatusはtokenを持たず`http://sparkdash:5555/`の200だけを監視し、
隣接endpointと同じdefault interval・Discord alertを使う。

| 確認 | 期待値 |
| --- | --- |
| Compose `ps`とimage参照 | sparkdashのみ、healthy、指定digest |
| secretのmetadata（内容は表示しない） | envはroot:root 0600、SSH dirは10001:10001 0500、鍵があれば0400 |
| uidとconfigへの書込み・再作成後のunit保持 | uid/gid 10001、configが永続化される |
| host listener | 5555のhost公開なし |
| `nslookup sparkdash.kojigenba-srv.com 192.168.10.101` | `100.86.147.127` |
| 信頼tailnetからのHTTPS frontend | 200、正しいTLS証明書、UIにtoken入力可 |
| 信頼network外からのroute | 403 |
| tokenなし・誤tokenの`/api/health` | 401 |
| 正しいBearerの`/api/health` | 200かつ`ok:true`。tokenを履歴/logに残さないclientで確認 |
| SSH鍵なし | warningのみで起動可能。任意keyなしのapplyも成功 |
| DGX登録と観測 | remote unit、専用非root user、実LLM port、Hermes無効 |
| Gatus / Healthchecks.io | frontend正常、dead-man復帰。DGX監視の成否はUIで別確認 |
| backup復旧試験 | 暗号鍵・ciphertext・known_hostsとunit/settingsを同時に復元 |

## image更新とrollback

上流更新は`files/services/images/sparkdash/Dockerfile`の`SPARKDASH_REVISION`（40文字commit SHA）、
`org.opencontainers.image.version`、`.github/workflows/sparkdash-image.yml`のpublish tagを同時に更新する。
review後にworkflowを実行し、job summaryのimmutable digestを取得する。別変更で
`sparkdash/compose.yaml`のdigestとreview用version commentを更新し、通常reconcileで反映する。
DependabotはNode base imageを追跡するが、上流revision/versionを自動更新しない。
image directory差分にもedgeと同様のreconcile mappingがあり、Composeのdigestを変えなければ同じimageを
再作成する。publishだけでは新imageへ切り替わらない。

backupを取り、data互換性を確認した上で次を人が実行する。対象SHAにはsparkdashのCompose定義が必要である。

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
- Hermes probeの副作用はcontainer hardeningでは防げない。DGX unitの設定で無効を維持する

## 手動反映の記録

| 日付 | 操作者 | 反映内容 | commit / 確認結果 |
| --- | --- | --- | --- |
| 未実施 | — | merge、SOPS追加、Ansible、DGX登録、backup復旧試験 | 実機確認待ち |

個人ID、token、秘密鍵、NodeIDはこの表に記録しない。
