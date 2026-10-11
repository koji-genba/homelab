# Homepage運用

## 用途と構成

homelab各サービスへのリンク集を提供する。初版はWebアプリ、AI・MCP、基盤・管理の3グループだけとし、
SMB/SSH/外部リンク、Gatus widget、docs索引は後続PRで追加する。

- URL: `https://homepage.kojigenba-srv.com`
- Compose project / service: `homepage` / `homepage`（内部port 3000）
- image: 公式`ghcr.io/gethomepage/homepage`、v2.5.0のOCI index digestを固定
- 接続: `homelab_frontend`のみ。host port、host network、Docker socketは使わない
- 認証: Caddyの接続元制限とBasic Auth。Gatusと同じ資格情報を使う

`edge.env`の`GATUS_BASIC_AUTH_USER`と`GATUS_BASIC_AUTH_HASH`を流用する。
secrets roleのsecret生成処理、`runtime.yaml.example`、暗号化bundleへの追加は不要である。
Homepage内蔵認証の`HOMEPAGE_AUTH_ENABLED`は設定しない。
`HOMEPAGE_ALLOWED_HOSTS`は公開FQDNだけを許可し、GatusとCompose healthcheckは同じHost headerでprobeする。

## 設定の置き場所と更新

`files/services/compose/homepage/config/`の`settings.yaml`、`services.yaml`、`bookmarks.yaml`、
`widgets.yaml`をGitで管理し、それぞれ`/app/config/`配下へread-only bindする。
リンクや説明はこの4ファイルを編集し、検証、review、mergeする。通常reconcileがHomepageを
force-recreateして反映する。UIやcontainer内での編集は使わない。

`/app/config`全体をread-only bindすると、公式imageのlogs書込みと不足するskeleton生成が衝突する。
そこで親directoryをuid/gid 1000、mode 0755、上限64 MiBのtmpfsとし、その上に設定4ファイルを
個別にread-only bindする。`/app/config/logs`と補助ファイルは書込み可能で、再作成時に破棄される。
repoに`docker.yaml`は追加しない。固定imageは起動後にコメントのみの`docker.yaml`と
`kubernetes.yaml`をtmpfsへ生成するが、Docker socketへの接続設定は持たせない。

`user: "1000:1000"`で直接非root起動し、`cap_drop: ALL`、`no-new-privileges`、
`read_only: true`、`/tmp`のtmpfsを組み合わせる。PUID/PGIDはrootでの所有権変更・UID切替に
capabilityを要するため設定せず、tmpfs側で所有権を指定する。固定imageのentrypointはPUID未指定時に
所有権変更を省き、既に非rootの場合はそのuserのままNodeを実行する。capabilityの追加は不要である。
ローカルでこのdigestを取得し、同じmountとhardeningによる一時containerを検証した。
FQDNのHost header付き`GET /`と設定APIは200、healthcheckは成功し、logsとskeletonの生成に
`EROFS`・`EACCES`・chown失敗はなかった。初回実機反映でも下記のログ・HTTP検証を行う。

restart policyは既存projectと同様に設定せず、`homelab-apps.service`を起動主体とする。
healthcheckはNodeのHTTP GETで`/`の200応答を確認する。interval 10s、timeout 5s、retries 3、
start period 30sは既存SearXNGに合わせ、CPU/memoryの固定limitは既存projectと同様に設けない。

## 初回反映の順序

1. PRをmergeし、reconcileがApps VMのcheckoutへ`homepage/compose.yaml`を届けたことを確認する。
   新projectは古いhelper一覧にないため、この段階では起動しない。
   CaddyとGatusの変更は先に反映されるので、Homepage起動までは502やGatusの障害通知が出ることがある。
2. 管理端末で`AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply`を実行する。
   DNS rewriteとdigest gate、起動・停止・rollback・dead-man・reconcileのproject一覧を更新する。
   checkout更新前にapplyすると`missing Compose project`で失敗する。新しいsecretは不要である。
   AdGuard設定の変更で既存projectもforce-recreateされ、DNS/SMBなどが短時間途切れることがある。
3. Apps VMで`sudo /usr/local/sbin/homelab-compose-up homepage`を実行する。
4. tailnet接続済みの端末からURLを開き、Gatusと同じBasic Authで画面と3グループのリンクを確認する。
   GatusのHomepage endpoint、container health、起動ログを確認する。

NFS directory、marker、nftables ruleの追加は不要である。ここに記載した実機操作は実装時には実行していない。

## ログと復旧

Apps VMで次を使う。

```sh
sudo docker compose --project-name homelab-homepage --env-file /etc/homelab/compose.env \
  --file /opt/homelab/files/services/compose/homepage/compose.yaml ps
sudo docker compose --project-name homelab-homepage --env-file /etc/homelab/compose.env \
  --file /opt/homelab/files/services/compose/homepage/compose.yaml logs --tail 100
sudo docker compose --project-name homelab-homepage --env-file /etc/homelab/compose.env \
  --file /opt/homelab/files/services/compose/homepage/compose.yaml exec homepage \
  sh -c 'ls -ld /app/config /app/config/logs; ls /app/config/logs'
```

file logは`/app/config/logs`にあり、container再作成で消える。必要な調査結果は再作成前に採取する。
`EROFS`、`EACCES`、skeleton生成失敗がないことを確認する。UIが出ない場合はallowed hostと
Caddyの認証・接続元制限も確認する。永続アプリデータはないため、Git設定とimageを再deployして復旧する。
設定・imageのrollbackは[アプリ更新・rollback](application-lifecycle.md)に従い、
Homepageを追加したcommit以降の既知の正常commitを指定する。

## 既知の制約

- ADR-0001に従いDocker socketを使わず、container自動検出やDocker widgetは提供しない。
- `siteMonitor`は同じDocker network上のHTTP backendだけに付ける。CaddyのFQDN経由ではprobeしない。
  SillyTavernはBasic Authで401になるためリンクのみとし、probeのために資格情報を渡さない。
  DGX、Proxmox、ElastiFlowなどLAN機器には付けない。自己署名TLSの回避設定も追加しない。
- probeは入口の応答確認であり、DGX推論、MCP呼出し、検索engine、認証APIの動作までは保証しない。
- 内部DNS rewriteがtailnet IPを返すため、FQDNリンクはtailnet接続を前提とする。
  LAN機器へのIPリンクにはLANまたはsubnet routeへの到達性が別途必要である。
- Basic AuthはGatusと共用で、資格情報の変更は両サービスへ影響する。

## 手動反映の記録

| 日付 | 作業 | 結果 |
| --- | --- | --- |
| 未実施 | 初回反映 | merge後に上記手順で実施し、SHA・image digest・検証結果を追記する |
