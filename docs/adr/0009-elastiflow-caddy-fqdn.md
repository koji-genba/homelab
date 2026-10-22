# ADR-0009: ElastiFlow UIをCaddy経由のFQDNで公開する

- 状態: 承認済み（repo定義済み、反映待ち）
- 日付: 2026-10-22

## 背景

[#33](https://github.com/koji-genba/homelab/issues/33)ではElastiFlow/KibanaにFQDNがなく、
IP直指定が必要だった。[ADR-0007](0007-apps-vm-tailnet-dns.md)ではApps VM外のLAN管理UIを
宅外からgateway exit node経由で利用するため、ElastiFlow UIもその経路に依存していた。

## 決定

`elastiflow.kojigenba-srv.com` のAdGuard rewriteを既存Webサービスと同じ `web_ip`
（現行はApps VMのtailnet IP）へ向ける。CaddyでHTTPSを終端し、HTTPの
`192.168.10.103:5601` へreverse_proxyする。既存の `admin_networks` スニペットで接続元を制限する。
通常のブラウザ向けURLとHomepageのリンクをこのFQDNへ揃える。

## 影響

- Caddyにとって初のApps VM外upstreamとなり、Apps VMからElastiFlow VMへのLAN到達性に依存する。
- Kibanaは認証なしで、Caddy経由のアクセスでは接続元制限が唯一の防御となる。
  LANからの直IPアクセスにはCaddyの制限がかからず、既存のネットワーク境界に依存する。
- ElastiFlow VMのIPを変更するときはCaddyfileのupstreamも更新する。
- CaddyとHomepageはmainマージ後のreconcile、DNSは手動の `make ansible-apply` で反映する。
  反映後に名前解決、HTTPS、画面・共有リンク、許可外接続元の403を確認する
  （[反映手順](../../files/infrastructure/terraform/elastiflow/README.md#fqdn変更の反映と確認)）。
- ADR-0007の例外はElastiFlow UIのみとし、他のLAN管理UIは従来どおりgateway経由で利用する。
  SSH、復旧、sFlow collector、LANフォールバックのIP指定も維持する。
