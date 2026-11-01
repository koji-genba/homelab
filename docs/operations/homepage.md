# Homepage運用

## 用途と構成

homelab各サービスへの統合トップページと、接続先の索引・簡易状況表示を提供する。Webアプリ、AI・MCP、基盤・管理、
ストレージ (SMB/NFS)、SSH 先、外部サイトの6グループで構成する。
各グループを横並びのカードで表示し、狭い画面では列数を減らす。全カードとグループ見出しに
アイコンを付け、ダークテーマとCSSの控えめなグラデーションを使う。外部画像・fontは追加しない。
アイコンはブラウザが既存のアイコンCDNから取得する。Webリンクは別タブで開く。

トップバーにはApps VMラベルのresources、Asia/Tokyoの日本語日時（24時間）、SearXNG検索を置く。
検索候補の取得は無効。ページ上で入力すると標準Quick Launchが名前・説明を検索する
（例: `samba`、`ssh`）。基盤・管理のGatusカードにはup / down / uptimeの集計を表示し、
既存のsiteMonitorも維持する。
固定v2.5.0の標準Quick Launchは`href`なしのカードを除外するため、custom.jsで同じ検索画面に
名前・説明に一致する接続先のコピー候補を補う。候補のクリック、またはTabで選択してEnter/Spaceでコピーする。
custom.jsが無効なら、この追加候補は表示されない（カードの手動コピーは可能）。

- URL: `https://homepage.kojigenba-srv.com`
- Compose project / service: `homepage` / `homepage`（内部port 3000）
- image: 公式`ghcr.io/gethomepage/homepage`、v2.5.0のOCI index digestを固定
- 接続: `homelab_frontend`のみ。host port、host network、Docker socketは使わない
- 認証: Caddyの接続元制限とBasic Auth。Gatusと同じ資格情報を使う

`edge.env`の`GATUS_BASIC_AUTH_USER`と`GATUS_BASIC_AUTH_HASH`を流用する。
secrets roleのsecret生成処理、`runtime.yaml.example`、暗号化bundleへの追加は不要である。
Homepage内蔵認証の`HOMEPAGE_AUTH_ENABLED`は設定しない。
`HOMEPAGE_ALLOWED_HOSTS`は公開FQDNだけを許可し、GatusとCompose healthcheckは同じHost headerでprobeする。

## Hermes Webapp のカード

「AI・MCP」の Hermes は `https://hermes.kojigenba-srv.com` を開く。AdGuard は既存サービスと同じ
Apps の Web 用 IP を返し、Apps VM（`192.168.10.101`）の Caddy が TLS を終端して
Agent VM の `192.168.10.104:9120` へ HTTP で中継する。Agent VM は tailnet 外を維持する。
Caddy は `admin_networks` と同じ接続元制限を行い、ログインは Hermes 同梱の basic provider が担当する。
Webapp 内 terminal は Runner を通さず Hermes コンテナ内で shell を開き、上流に停止設定がないため、
Caddy が `/api/host-terminal*` を403で拒否する。Agent 側で9120を Apps VM からだけ許可することが前提となる。
判断は [ADR-0013](../adr/0013-hermes-webapp-caddy.md) を参照する。

`siteMonitor` と Gatus は `http://192.168.10.104:9120/api/status` を直接見る。上流の
`dashboard_auth/public_paths.py` はこの経路を認証対象外とし、`web_routers/status.py` は
未ログイン時にも `gateway_running` と `auth_required` を返す。Gatus は HTTP 200 と両方の true を確認する。
Homepage の表示は HTTP の死活だけで、DNS・Caddy・TLS・ログイン・チャットの成功までは判定しない。
Apps の nftables テンプレートは Docker の転送・NAT を置き換えず、Docker の標準 bridge masquerade を
無効化する設定もない。2026-11-02 JST、Apps VM から `/api/status` が `overall: ok` を返し、
Gatus の監視成功と Trusted VLAN の作業端末から9120へ届かないことを確認済み。
Caddy 越しのログインが成功し `__Host-` cookie が使えたことから、`.101` の trusted proxy 設定で
HTTPS の転送ヘッダーが信頼され、Hermes から見た接続元は Apps の LAN IP のままと判断できる。
Agent 側の公開ポート・Apps のみを許可する firewall・認証・trusted proxy の設定は
[Hermes Agent 運用](hermes-agent.md)と [ADR-0013](../adr/0013-hermes-webapp-caddy.md) を参照する。

Caddy の `reverse_proxy` は WebSocket の upgrade と SSE（`text/event-stream`）の即時 flush に
既定で対応し、Host を保持して `X-Forwarded-For` / `X-Forwarded-Proto` / `X-Forwarded-Host` を付けるため、
追加の `flush_interval` や header 上書きは不要である
（[Caddy 公式仕様](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#streaming)）。
Agent 側には公開 URL と実際の TCP peer に対する trusted proxy 設定が必要になる。

反映順は Agent 側の Webapp・認証・firewall の準備、Apps 側の merge と reconcile による checkout 更新、
同じ変更を持つ controller からの `make ansible-apply` による DNS rewrite 反映とする。
この merge は `edge`・`homepage`・`monitoring` を force-recreate する。AdGuard の生成結果変更は
`secrets_runtime_changed` を通じて Apps 全 project の force-recreate を伴う
（[CODEBASE_MAP の gotcha 2・3・6](../CODEBASE_MAP.md#6-gotchas)）。
Agent の準備より先に merge すると Gatus が異常となり、Caddy は 502 を返す。

2026-11-02 JST、PR #180 のマージ後に reconcile を手動起動し、上記3 project の再作成を確認した。
AdGuard rewrite の `make ansible-apply` は changed=4で、Apps の全 project が再作成された。
tailnet 端末では名前が Apps の tailnet IP に解決され、`/login` 200、`/` 302、`/api/host-terminal` 403、
未ログインの `/api/sessions` 401を確認した。利用者はブラウザで Webapp にログインし会話できた。

## 設定の置き場所と更新

`files/services/compose/homepage/config/`の`settings.yaml`、`services.yaml`、`bookmarks.yaml`、
`widgets.yaml`と、表示用の`custom.css`・コピー操作用の`custom.js`をGitで管理し、
それぞれ`/app/config/`配下へread-only bindする。
リンクや説明、UIはこれらのファイルを編集し、検証、review、mergeする。通常reconcileがHomepageを
force-recreateして反映する。UIやcontainer内での編集は使わない。

SMB/NFS/SSHの索引エントリは`href`なしのカードとし、`description: |-`で必ず2行を書く。
1行目はコピーしたい文字列そのもの、2行目は認証・到達範囲・未実施事項などの短い補足とする。
SMBのUNCパスは先頭にバックスラッシュ2つ、共有名の前に1つを書く（YAMLのliteralではescape不要）。
SSHは`ssh user@host`、admin userが未確認のDGXはホストIPだけを1行目に置き、`:22`は補足に書く。

```yaml
- shared:
    id: copy-storage-shared
    icon: samba-server
    description: |-
      \\samba.kojigenba-srv.com\shared
      統合共有・SMB認証・tailnet必須
```

新しいエントリは「ストレージ (SMB/NFS)」または「SSH 先」に置き、重複しない`id`を
それぞれ`copy-storage-` / `copy-ssh-`で始める。アイコンも付ける。
固定v2.5.0の実コンテナで確認した`.service`・`.service-card`・`.service-description`と
`.services-group`・`.service-group-name`をCSS/JSで使う。image更新時はDOMを再確認する。

対象カードのクリック、またはフォーカスしてEnter/Spaceで**1行目だけ**をコピーする。
成功すると色が変わり「コピーしました」を約2.4秒表示する。イベント委任とMutationObserverで
再描画に対応し、Clipboard APIが使用不可・拒否された場合は`execCommand('copy')`にフォールバックする。
両方失敗した場合は手動コピーを案内する。CSSは改行を表示し、文字の選択を許可するため、
custom.jsが無効でもトリプルクリックやドラッグでコピーできる。長い補足は画面幅に合わせて折り返す。
ただしJavaScript全体を無効にすると、固定v2.5.0のHomepage本体がカードを描画しない。
手動コピーの代替はHomepage本体のJavaScriptを有効にした状態で利用する。

`smb://`・`ssh://`はブラウザ/OSでの動作が未検証のため使わない。説明は日本語で簡潔にし、
認証・到達範囲や未実施の作業を必要に応じて添える。外部サイトはHTTPSの`href`を付ける。
これらの索引には`siteMonitor`・`ping`を付けない。索引の更新もmerge後の通常reconcileで反映される。

`/app/config`全体をread-only bindすると、公式imageのlogs書込みと不足するskeleton生成が衝突する。
そこで親directoryをuid/gid 1000、mode 0755、上限64 MiBのtmpfsとし、その上に設定6ファイルを
個別にread-only bindする。`/app/config/logs`と補助ファイルは書込み可能で、再作成時に破棄される。
repoに`docker.yaml`は追加しない。固定imageは起動後にコメントのみの`docker.yaml`と
`kubernetes.yaml`をtmpfsへ生成するが、Docker socketへの接続設定は持たせない。

`user: "1000:1000"`で直接非root起動し、`cap_drop: ALL`、`no-new-privileges`、
`read_only: true`、`/tmp`のtmpfsを組み合わせる。PUID/PGIDはrootでの所有権変更・UID切替に
capabilityを要するため設定せず、tmpfs側で所有権を指定する。固定imageのentrypointはPUID未指定時に
所有権変更を省き、既に非rootの場合はそのuserのままNodeを実行する。capabilityの追加は不要である。
ローカルでこのdigestを取得し、同じmountとhardeningによる一時containerを検証した。
FQDNのHost header付き`GET /`と設定APIは200、healthcheckは成功し、logsとskeletonの生成に
`EROFS`・`EACCES`・chown失敗はなかった。初回実機反映でのログ・HTTP検証結果は末尾の記録に記載する。

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
3. apply末尾の強制reconcile（task `Force-reconcile projects after rendered runtime changes`）でHomepageが起動する。
   apply後にApps VMの`docker ps`でHomepageが起動・healthyか確認し、起動していなければ
   `sudo /usr/local/sbin/homelab-compose-up homepage`を実行する。
4. tailnet接続済みの端末からURLを開き、Gatusと同じBasic Authで画面と6グループのリンク・索引を確認する。
   GatusのHomepage endpoint、container health、起動ログを確認する。

NFS directory、marker、nftables ruleの追加は不要である。2026-10-12に初回反映を実施した。

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

## 既知の制約 / 今後

- ADR-0001に従いDocker socketを使わず、container自動検出やDocker widgetは提供しない。
- resourcesはコンテナから見えるCPU・memory・disk (`/`)・uptimeの値であり、ホストmountや
  追加権限は使わない。実機でApps VMの値になるかはデプロイ後に確認する。ローカルではWSLホストの
  値が出るため、実機一致は未検証。diskもコンテナの`/`であり、NFSやストレージ全体の使用率ではない。
- Gatus widgetは同じDocker networkの`http://gatus:8080`から集計する。ローカルでGatusが
  無い場合は値を取得できずAPIエラー表示になるが、他カードやコピー操作は利用できる。
- 履歴グラフはPrometheus/Grafana導入時に`prometheusmetric` widget等で拡張する。
  Proxmox/DGXの数値はAPIトークンやエージェントが要るため別途判断する。
  この構成ではProxmox・Glances・Prometheus系widget、tokenが要るsparkDashのcustomapi連携は追加しない。
- `siteMonitor`は同じDocker network上のHTTP backendだけに付ける。CaddyのFQDN経由ではprobeしない。
  SillyTavernはBasic Authで401になるためリンクのみとし、probeのために資格情報を渡さない。
  DGX、Proxmox、ElastiFlowなどLAN機器には付けない。自己署名TLSの回避設定も追加しない。
- probeは入口の応答確認であり、DGX推論、MCP呼出し、検索engine、認証APIの動作までは保証しない。
- 内部DNS rewriteがtailnet IPを返すため、FQDNリンクはtailnet接続を前提とする。
  ElastiFlow UIは `https://elastiflow.kojigenba-srv.com` からApps VMのCaddyを経由して別VMへ届くため、
  gateway exit nodeに依存しない。Kibanaは認証なしで、Caddyの `admin_networks` で接続元を制限する
  （[ADR-0009](../adr/0009-elastiflow-caddy-fqdn.md)）。このリンクにも `siteMonitor` は付けない。
  他のLAN機器へのIPリンクとSSH先のエントリはLANのIP（`192.168.10.x`）を示す。
  宅外やtailnet端末からはgatewayのsubnet route / exit node経由で到達できる必要がある。
- Basic AuthはGatusと共用で、資格情報の変更は両サービスへ影響する。

## 手動反映の記録

| 日付 | 操作者 | 反映内容 | commit / 確認結果 |
| --- | --- | --- | --- |
| 2026-10-12 (JST) | — | 初回反映。PR #82をmerge（`6b71c23`）→ 01:37 JSTのreconcileでcheckout更新・edgeとmonitoringを再作成 → `make ansible-apply`実行 → 強制reconcileでHomepageが起動（`homelab-compose-up homepage`は不要だった）。apply時はAdGuard設定が変わり既存projectも再作成され、DNS/SMBは短時間断 | image: `ghcr.io/gethomepage/homepage@sha256:57c4a0531937889c0b968b120fe9c2560bbe036b5c9e18c49a9e2479de9975d1`（v2.5.0）。ansible-applyはok=103 changed=9 failed=0 unreachable=0。Homepageコンテナはhealthy、Composeの12コンテナすべてup。Gatusの15エンドポイントすべてOK（Homepage含む）。資格情報なしでCaddy経由は401。Homepage内部からsiteMonitorの8宛先すべてに到達。ログにEROFS/EACCESなし。tailnet端末でBasic Authと3グループ・応答時間の表示をユーザーが確認 |
