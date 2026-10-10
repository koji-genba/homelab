# SearXNG / MCP運用

- 状態: 2026-10-10にApps VMへ反映し、両FQDN、FQDN経由のMCP呼び出し、DGXのmodelからの往復、
  Open WebUIの2つの入口（内蔵のWeb検索とMCP）まで確認済み
- 関連: [アプリ更新・promotion・rollback](application-lifecycle.md)、[Open WebUI運用](open-webui.md)、
  [Apps VM復旧](apps-vm-recovery.md)、[ADR-0001](../adr/0001-single-apps-vm-compose.md)、
  [ADR-0007](../adr/0007-apps-vm-tailnet-dns.md)
- 対象: `searxng` Compose project（`https://searxng.kojigenba-srv.com`と
  `https://mcp-searxng.kojigenba-srv.com/mcp`）

DGX SparkのvLLMで動かすmodel（`glm-5.3-flash`）に、web検索とpage取得のtoolを与える。SearXNGが
複数の検索engineを束ね、その前に置いたMCP server（`mcp-searxng`、Streamable HTTP）がtoolとして
公開する。利用側はOpen WebUIと、信頼networkにある他のMCP clientである。

## 構成

```text
MCP client (信頼network)
  -> Caddy (mcp-searxng.kojigenba-srv.com、信頼networkのみ)
  -> mcp-searxng:3000 -> searxng:8080 -> 外部のsearch engine

Open WebUI
  -> http://mcp-searxng:3000/mcp (homelab_frontend network、Caddyを通さない)

browser (信頼network)
  -> Caddy (searxng.kojigenba-srv.com、信頼networkのみ)
  -> searxng:8080
```

- Host portは公開しない。到達元の制限はnftables、IX2215 ACLと、Caddyの信頼network制限
  （`admin_networks` snippet、`CADDY_TRUSTED_NETWORKS`）で行う
- imageはdigestでpinする（`files/services/compose/searxng/compose.yaml`）。SearXNGは
  `2026.10.9-f4822b3fc`、`mcp-searxng`は`v2.5.1`である
- NFSや永続dataはない。SearXNGのcacheはnamed volume `searxng-cache`に置くが、消えてよい
- Compose project名は`homelab-searxng`で、lifecycle helperが導出する
- 提供されるtool（`tools/list`で確認）:
  - `searxng_web_search`: SearXNGで検索する
  - `web_url_read`: URLを取得して本文を返す
  - `searxng_search_suggestions`: 検索候補を返す
  - `searxng_instance_info`: SearXNG instanceの情報を返す

## 利用側の設定

1. Open WebUI（同じDocker network）には入口が2つあり、渡すaddressが違う。どちらも2026-10-10に運用者が
   管理者設定で登録し、動作することを確認した
   - 内蔵のWeb検索: 管理者設定のWeb Searchでengineを`searxng`にし、Query URLへSearXNG自体のaddress
     `http://searxng:8080/search`を指定する（`SEARXNG_QUERY_URL`。旧形式の
     `http://searxng:8080/search?q=<query>`も受け付ける）。Open WebUIが回答の前に自分で検索する方式で、
     modelのtool callingに依存しない。Open WebUI v0.11.4は必ず`format=json`を付けて呼び、失敗を例外に
     するため、SearXNGがJSONを返せないと検索がerrorになる。`settings.yml`の`formats`に`json`があるのは
     このためでもある。Open WebUIと同じparameterとheaderのrequestを実機のDocker network内から送り、
     JSONで20件返ることを確認した（許可していない`format=csv`は403）
   - MCPのtool: 管理者設定のExternal Toolsで、typeを「MCP (Streamable HTTP)」、URLを
     `http://mcp-searxng:3000/mcp`、認証を「なし」にする。modelが必要と判断したときに検索やpage取得を
     tool callとして呼ぶ方式である
2. 信頼LAN/tailnetの他のclient: `https://mcp-searxng.kojigenba-srv.com/mcp`を指定する
3. DGX自身で動くclient: 内部名はApps VMのtailnet addressへ解決される（ADR-0007）。DGXがtailnetや
   AdGuardのclientかは分かっていないため、必要なら`/etc/hosts`に両FQDNを`192.168.10.101`として
   書く（CaddyはLAN addressでも待ち受ける）。DGXで要確認であり、事実としては確認していない
4. browser originのrequestは、`MCP_HTTP_ALLOWED_ORIGINS`を設定しない限り`mcp-searxng`のOrigin検査で
   拒否される（`Origin: https://evil.example`が403 `Invalid Origin header`になることを確認した）。
   server側のclientはOriginを送らないので影響しない

## 設計上の判断

- **SearXNGとMCP serverは1つのCompose projectにまとめる。** 両者は常に一緒に更新・再作成され、
  `mcp-searxng`は`searxng`のhealthy後にだけ起動する（`depends_on: service_healthy`）
- **NFSを使わないため、pve1の手順はない。** 永続すべきdataがないので、directory・markerの作成も
  `/etc/exports`の変更もmount guardへの追加も不要である
- **`SEARXNG_SECRET`はSOPS bundleではなく、Apps VM上でAnsibleが生成する。** 外部systemの
  credentialではなく、値に依存するdataもなく、VMを作り直せば再生成されるだけだからである。
  `force: false`なので最初の値が以後の実行でも保たれる。rotationは`/etc/homelab/secrets/searxng.env`を
  消して`make ansible-apply`を実行する。`runtime.yaml.example`には載せない。生成の挙動（初回
  `changed`、2回目`ok`、64文字の16進、mode `0600`）は作業端末のtoolboxで確認した
- **SearXNGは`user: "977:977"`で動かす。** imageはUSERを指定せず、entrypointがrootのまま動くためである。
  977はimage自身の`searxng` accountで、`/var/cache/searxng`の所有者である。`read_only: true`と
  `cap_drop: [ALL]`の下で、そのvolumeにuid 977が書けることを確認した
- **`MCP_HTTP_STATELESS=true`にする。** stateful sessionはmemoryにあるため、container再作成のたびに
  無効になる。さらにsessionは既定で失効せず、1000件に達すると新しいclientへ503を返す。代償として
  `GET /mcp`と`DELETE /mcp`は405を返し、server起点のstreamは使えない。tool呼び出しだけの用途には
  影響しない
- **`MCP_HTTP_TRUST_PROXY=1`にする。** Caddyは`X-Forwarded-For`を付けて転送する。この変数がないと
  `mcp-searxng`のrate limiterがCaddy経由の全clientをCaddyのaddressで数え、logに
  `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`を出す。初回の実機反映で見つけて追加した。`1`は信頼するproxyが
  1段という意味である。Caddyを通さないDocker network内のclientには影響しない
- **MCPに認証は付けない。** 到達元はnftables/IX2215とCaddyの信頼network制限で絞る。上流には
  hardened mode（`MCP_HTTP_HARDEN`、bearer token、allowed hosts/origins）があり、制限を強める
  必要が出たときに使える
- **`web_url_read`のSSRF保護は既定のまま有効にし、`MCP_HTTP_ALLOW_PRIVATE_URLS`は設定しない。**
  実測で次をsecurity policyが拒否した: `http://searxng:8080/healthz`（Docker内部名）、
  `http://192.168.10.11:8006/`（private address）、`http://100.86.147.127/`（tailnet address）。
  `https://example.com`は取得できた。この変数を設定するとLLMがhomelab内部を読めてしまう
- **SearXNGのlimiterは無効にし、Valkeyは置かない。** 到達元は信頼networkだけであり、limiterは
  Valkeyを要し、API clientを絞ってしまう。`settings.yml`で`json` formatを許可している（既定は
  htmlのみで、他のformatは403になる）
- **Gatusが見るのは`/healthz`と`/health`だけである。** どちらも検索engineを呼ばないため、上流engineの
  障害は通知されない
- **一般のweb検索engineに`bing`、`yahoo`、`duckduckgo web`を足している。** 上流の既定で有効な一般
  engineは`brave`、`duckduckgo`、`google cse`だが、この回線では`brave`がrate limit、`duckduckgo`が
  CAPTCHAで応答せず、`google cse`だけが結果を返していた。足した3つは単独では不安定（作業端末の試験で
  `bing`は0件が2回、`duckduckgo web`はtimeoutが1回、`yahoo`は0件が1回あった）だが、欠けるタイミングが
  互いに違うので、まとめて使うと結果が途切れにくい。`brave`と`duckduckgo`は回復する可能性があるため
  既定の有効のままにしてあり、`google`（access denied）と`qwant`（CAPTCHA）は試験で応答しなかったため
  有効にしていない。中国・ロシア・韓国・チェコ向けのengineは検索語を送る先として避けた。engineの
  変更は`settings.yml`で行い、reconcileがprojectを再作成して反映する。回線やengine側の事情で応答は
  変わるため、定期的に見直す

## 反映手順

順序を入れ替えない。

1. PRを`main`へmergeする。
2. Apps VMのcheckoutを進める。`ssh deploy@192.168.10.101 sudo systemctl start homelab-app-reconcile.service`
   （または15分のtimerを待つ）。checkoutに`searxng/compose.yaml`が無いと、手順3のdigest gateが
   `missing Compose project`で失敗する。このreconcileはまだ古いhelperで動くため、変更を検出して
   再作成するのは`edge`（Caddyfile）と`monitoring`（Gatus config）だけで、searxngは起動しない。
   `edge`の再作成中は全FQDNのHTTPSが短時間途切れる。`.env.example`は今回変わらないので、他の
   projectは再作成されない。Gatusは新しい2 endpointを読み込むが、手順3までdownと報告し、3回失敗後に
   Discord通知が出る。Caddyは新しい2 FQDNの証明書を要求する
3. `AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply`を実行する。secrets roleが
   `searxng.env`を生成してAdGuard rewrite（2 FQDN）を再描画し、compose roleがhelperを再描画する。
   `searxng.env`とAdGuard設定が変わるため、全projectが一度force-recreateされ（DNS/SMBが短時間
   途切れる）、そこでsearxngが起動する。初回はimageのpullを伴う

pve1の手順はない。2と3は静かな時間帯に続けて行うことを推奨する。

手順3が途中で失敗した場合、再実行では全projectのforce-recreateが走らないことがある。secrets roleは
先に`searxng.env`とAdGuard設定を書き終えており、2回目は変更なしと判定するためである。その場合は
`make ansible-apply`の成功後に、Apps VMで次を実行する。

```sh
ssh deploy@192.168.10.101 sudo env HOMELAB_FORCE_RECREATE=true /usr/local/sbin/homelab-compose-up all
```

## 検証

実機のhealthとlogは`homelab-searxng`のprojectで見る。

| 項目 | 確認方法 | 結果 |
| --- | --- | --- |
| `docker compose ps`がhealthy | `ssh deploy@192.168.10.101 sudo docker compose --project-name homelab-searxng --env-file /etc/homelab/compose.env -f /opt/homelab/files/services/compose/searxng/compose.yaml ps` | 2026-10-10 確認済み（2 serviceともhealthy、SearXNGはuid 977） |
| `searxng.env`の生成 | `ssh deploy@192.168.10.101 sudo ls -l /etc/homelab/secrets/searxng.env`（`root:root 0600`） | 2026-10-10 確認済み（`root:root 0600`、64文字の16進） |
| SearXNGのFQDN | `curl -sI https://searxng.kojigenba-srv.com`（信頼networkから200、他から403） | 2026-10-10 確認済み（`/`と`/healthz`が200、Let's Encrypt証明書）。信頼network外からの403は未確認 |
| MCPのFQDN | `curl -s https://mcp-searxng.kojigenba-srv.com/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'` | 2026-10-10 確認済み（`initialize`が200、`searxng_web_search`の`tools/call`が結果を返す、`web_url_read`は`http://adguard:3000/`を拒否） |
| Gatusの`SearXNG`と`SearXNG MCP`がgreen | `https://status.kojigenba-srv.com` | 2026-10-10 確認済み（全13 endpointがsuccess） |
| AdGuard rewrite | `nslookup searxng.kojigenba-srv.com 192.168.10.101`と`mcp-searxng`も同様（`100.86.147.127`を返す） | 2026-10-10 確認済み（両方`100.86.147.127`） |
| Caddy経由でrate limiterの警告が出ない | FQDN経由で呼んだ後、`docker compose ... logs mcp-searxng`に`ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`がないこと | 2026-10-10 確認済み（PR #69の反映後、FQDN経由の`initialize`・`tools/call`・`/health`の後もlogは起動時の4行だけ） |
| DGXのmodelからの往復 | `glm-5.3-flash`へMCPの`tools/list`をtoolとして渡し、返ったtool callを`https://mcp-searxng.kojigenba-srv.com/mcp`へ実行して結果を返す | 2026-10-10 確認済み（`searxng_web_search`と`web_url_read`を呼び、2 roundで回答） |
| Open WebUIのMCP tool | External Toolsへ登録し、最新情報を要するchatで検索が呼ばれることを確認する | 2026-10-10 運用者が確認済み |
| Open WebUIの内蔵Web検索 | Web Searchのengineを`searxng`、Query URLを`http://searxng:8080/search`にして、chatで検索させる | 2026-10-10 運用者が確認済み |

### 実機反映の記録（2026-10-10）

PR #68（merge commit `d477e44`）を反映手順の順で反映した。imageは事前に`docker pull`しておいた
（それぞれ約10秒）。

| 項目 | 結果 |
| --- | --- |
| reconcile | 34秒で成功。再作成したのは`edge`と`monitoring`だけで、checkoutは`d477e44`へ進んだ |
| `make ansible-apply` | 133秒、`ok=100 changed=10 failed=0`。`searxng.env`の生成、AdGuard設定とhelperの再描画、全projectのforce-recreateが行われた |
| 反映後のcontainer | 全10 containerが稼働し、healthcheckを持つものはすべてhealthy |
| FQDNの経路 | LAN address（`192.168.10.101`）とtailnet address（`100.86.147.127`）のどちらでも200 |
| Docker network内の経路 | 別containerから`http://mcp-searxng:3000/health`が200 |
| dead-man ping | `homelab-healthchecks-ping.service`が成功 |
| memory | SearXNG 約134 MiB、`mcp-searxng` 約58 MiB |
| rootfs | 28%（image追加前は26%） |

反映後、`mcp-searxng`のlogに`ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`（express-rate-limitの
`ValidationError`）が出ていた。Caddy経由のrequestは成功しており、影響はrate limitの枠がclient間で
共有されることである。作業端末で再現し、`MCP_HTTP_TRUST_PROXY=1`で消えること、Caddy経由と直接の
どちらのrequestも成功することを確認して、`compose.yaml`へ追加した。

この修正はPR #69（merge commit `92d3343`）で反映した。`ansible-apply`は不要で、reconcileが14秒で
`searxng` projectだけを再作成した。他の8 containerは再作成されていない。反映後もGatusは全13 endpointが
successだった。

### ローカル検証（2026-10-10）

実機反映の前に、同じ`compose.yaml`・`settings.yml`・digestを作業端末のDockerで起動した。host portは
検証用のoverrideで`127.0.0.1`にだけ公開し、repoのfileには足していない。imageは事前に取得済みで、
pull時間は含まない。SearXNGから外部engineへの検索は実際のインターネットに対して行った。

| 項目 | 結果 |
| --- | --- |
| `config --quiet`、`config --images` | 成功。2 imageとも`@sha256:`の64桁digest |
| `up -d --wait`（空の状態） | 約11.6秒で両方healthy |
| `up -d --wait --force-recreate` | 約13.8秒でhealthy。再作成直後に再初期化なしで`tools/call`が成功 |
| SearXNGのuid | `/proc/1/status`で`Uid`/`Gid`とも977。read-only rootfsで`/etc`への書き込みは拒否、named volumeへは書き込める |
| `/healthz` | 200 |
| `/search?q=debian+13&format=json` | 200、`results` 20件。`unresponsive_engines`は`brave`（too many requests）、`duckduckgo`（CAPTCHA）、`wikidata`（timeout） |
| `format=csv` | 403 |
| `/`（`X-Forwarded-Proto: https`、`X-Forwarded-Host: searxng.kojigenba-srv.com`付き） | 200 HTML |
| 内部名でのJSON API（`SEARXNG_BASE_URL`設定下、`mcp-searxng`のcontainerから`http://searxng:8080`） | 200、20件 |
| MCP `initialize`（`2025-06-18`） | 200、`Mcp-Session-Id`は返らない、本文はSSE（`event: message`） |
| session headerなしの`notifications/initialized` | 202 |
| `tools/list` | 4 toolを返す |
| `searxng_web_search` | 結果を返す |
| `web_url_read` | `https://example.com`は成功。`searxng:8080`、`192.168.10.11`、`100.86.147.127`はsecurity policyが拒否 |
| `GET /mcp`、`DELETE /mcp` | 405 |
| `Origin: https://evil.example` | 403（`Invalid Origin header`） |
| `GET /health` | 200、`{"status":"healthy",...,"transport":"http"}` |
| `initialize`なしの`tools/list`、`tools/call` | 成功（statelessなので遅延接続のclientにも寛容） |
| 公式MCP Python SDK（`mcp` 1.30.0と2.3.0） | initialize、list_tools、`searxng_web_search`の`call_tool`が成功。GETの405による警告は出ない |
| Caddy経由（同じpinned imageのcaddy-cloudflare、plain HTTP） | initialize、`tools/list`、`tools/call`、SDK clientが成功。当初は`mcp-searxng`のlogに警告が出ないと記録したが誤りで、実機反映後の再検証では`MCP_HTTP_TRUST_PROXY`なしだと`ValidationError`が出た。`MCP_HTTP_TRUST_PROXY=1`では出ず、Caddy経由と直接のどちらも200だった |
| repoの`Caddyfile`の`caddy validate` | `Valid configuration`（検証用の環境変数で実行。`CF_API_TOKEN`はplugin側の形式検査があるため、40文字の英数字のダミー値が必要） |
| 実際のDGXのmodelでの往復 | `glm-5.3-flash`が`searxng_web_search`と`web_url_read`を呼び、結果を受けて最新のstable kernel versionを答えた（3 round） |
| engine追加後の検索（`bing`、`yahoo`、`duckduckgo web`を有効化。作業端末のDocker、同じdigest） | 6 query（英語4、日本語2）で、`google cse`、`duckduckgo web`、`yahoo`が毎回、`bing`が4回結果を返した。結果は1 queryあたり29〜39件（重複は統合される）、応答は平均2.0秒、最大3.2秒。`brave`と`duckduckgo`は毎回`unresponsive_engines`に出た |
| idle時のmemory | SearXNG 約118 MiB、`mcp-searxng` 約51 MiB（検証後の計測） |
| image size | SearXNG 384 MB、`mcp-searxng` 320 MB（`docker image ls`） |

`mcp-searxng`はrequestにrate limitを付ける。応答headerで、`initialize`は20回/60秒、それ以外は
300回/60秒と確認した（既定値。上流は`MCP_RATE_*`で変更できる）。枠はclientのaddressごとで、
Caddy経由のclientは`MCP_HTTP_TRUST_PROXY=1`により`X-Forwarded-For`のaddressで数えられる。client別に
枠が分かれることそのものは未検証である。

## 更新とrollback

更新は`searxng/compose.yaml`のdigestを上げるPRで行い、reconcileが反映する。SearXNG imageは1日に
複数のdated tagを公開するので、digestの更新は頻繁になるが、必須ではない。data migrationはないため、
rollbackは`PROJECT=searxng make rollback-app`で行え、dataに関する注意はない（手順は
[アプリ更新・promotion・rollback](application-lifecycle.md#rollbackと再開)）。

## 再deploy

通常はPRを`main`へmergeするだけで、reconcile（15分間隔）が変更のあるprojectだけを再作成する。
急ぐ場合はApps VMで`sudo systemctl start homelab-app-reconcile.service`を実行する。

| 変えたもの | 手順 | 影響 |
| --- | --- | --- |
| `searxng/compose.yaml`、`searxng/settings.yml` | PRをmerge。reconcileがsearxngだけを再作成する | 短時間、検索とMCPが止まる |
| Caddyfile、Gatusの`config.yaml` | 同上（edge / monitoringだけ） | 該当projectのみ |
| Ansible管理のもの（`group_vars`、helper、AdGuard rewrite、`searxng.env`） | merge後に`make ansible-apply` | `compose.env`、AdGuard設定、runtime secretのいずれかが変わると全projectを再作成する（DNS/SMBが短時間途切れる）。helperだけなら再作成なし |
| 変更なしで作り直す | `ssh deploy@192.168.10.101 sudo env HOMELAB_FORCE_RECREATE=true /usr/local/sbin/homelab-compose-up searxng` | searxngのみ |

## 既知の制約

- 上流のsearch engineはrate limitやCAPTCHAで応答しないことがある。ローカル検証では`brave`（too many
  requests）、`duckduckgo`（CAPTCHA）、`wikidata`（timeout）が`unresponsive_engines`に出た。他のengineが
  応答するため結果は返るが、Gatusでは検知できない
- engineを足す前に実機で4つのquery（英語3、日本語1）を試したところ、返った20件はいずれも`google cse`
  という1つのengineだけの結果で、`brave`（Suspended: too many requests）と`duckduckgo`（CAPTCHA）は
  4回とも応答しなかった。`bing`、`yahoo`、`duckduckgo web`を足した後も、`brave`と`duckduckgo`は
  `unresponsive_engines`に出続ける。`/healthz`と`/health`はengineを呼ばないため、Gatusは全engineが
  止まった状態を検知しない
- SearXNGのlogには、Caddyを通さない直接のrequestに対して`X-Forwarded-For nor X-Real-IP header is
  set!`のERRORが出ることがある（ローカル検証では1回）。`limiter.toml`が無いというWARNINGも出る。
  どちらもrequestは成功しており、noiseとして扱う。ほかに起動時に`torch`と`ahmia`のengineが
  読み込めないERRORが出た
- statelessなので`GET /mcp`と`DELETE /mcp`は405である。検証した2つのSDK clientは問題なく動いたが、
  他のclientで警告が出る可能性は排除していない

## 切り戻し（アプリの撤去）

追加時とは逆に、helperのproject一覧を先に戻す。checkoutだけが先に戻ると、古いhelperとdead-man pingが
`searxng/compose.yaml`を見つけられずに失敗する。

1. Apps VMでprojectを止める。

   ```sh
   ssh deploy@192.168.10.101 sudo docker compose --project-name homelab-searxng \
     --env-file /etc/homelab/compose.env \
     -f /opt/homelab/files/services/compose/searxng/compose.yaml down
   ```

2. revertのPRを`main`へmergeし、reconcileを待たずに`make ansible-apply`を実行する。
3. reconcileでApps VMのcheckoutを進める。
4. Apps VMで`/etc/homelab/secrets/searxng.env`と、named volume `homelab-searxng_searxng-cache`を手で
   消す（`docker volume rm homelab-searxng_searxng-cache`）。NFS側の作業はない。
