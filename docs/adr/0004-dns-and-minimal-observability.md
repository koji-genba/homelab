# ADR-0004: AdGuard Homeと最小監視を採用する

- 状態: 承認済み
- 日付: 2026-08-29

## 背景

UnboundはTailscaleのグローバルネームサーバーとしてのみ参照され、内部FQDNと広告blockを提供している。
宅内DHCP clientはpublic DNSを直接参照する。現在のblocklist更新は独自のRPZ変換・再起動処理を持ち、
2026-08-30の実機確認でも不正なTIF RPZによるCrashLoopと更新Jobの連続失敗が発生していた。
監視は必要だが、Prometheus/Grafanaや中央ログ基盤を運用する規模ではない。

## 決定

UnboundをAdGuard Homeへ置き換える。

- TailscaleのグローバルネームサーバーをApps VMのDNSへ向ける。
- DHCPは引き続きpublic DNSを配布する。
- primary upstreamはCloudflare DoH、fallbackはQuad9 DoHとする。
- Quad9のフィルタリング結果はfallback時だけ受け入れる。
- 現行の保護意図を維持するため、HaGeZiのPro、TIF、DoH/VPN/Proxy Bypass、Dynamic DNS、
  Hoster、URL Shortenerの6 feedをAdGuard形式で使用する。取得・更新・構文検証はAdGuardの
  標準機能へ任せ、独自のRPZ変換処理は持たない。
- 手動allow/blockとlocal recordはGit管理する。
- AdGuard標準filter、Safe Browsing、Parental Control、search ads機能は無効化する。
- 初期block動作は通常のNXDOMAIN/AdGuard blockingとし、custom sinkholeは将来要件とする。
- 管理UI `dns.kojigenba-srv.com` はTrusted/Tailscaleだけに公開し、内蔵認証を使う。

監視はGatus、ホストのsystemd probe、Healthchecks.ioで構成する。

- GatusはHTTP/TLS/DNSと主要serviceをprobeする。
- ホストprobeはNFS marker、ディスク、Samba read/write、systemd、Git driftを確認する。
- 異常と復旧をDiscordへ通知する。
- Apps VMからHealthchecks.ioへdead-man pingし、VM全体の停止を外部検知する。
- Healthchecks.ioのcheckとDiscord integrationは手動作成し、ping URLだけをSOPS管理する。
- Prometheus、Grafana、Lokiは導入しない。必要になった時点で再検討する。

ログはDocker local driverでrotationし、journaldは最大500 MiBかつ最長14日を目安にする。
Caddy/application logは14日、DNS query logは7日とし、バックアップ対象外とする。

## 影響

- DNS blocklist更新用の独自container/cronを削減できる。
- Gatus自身とApps VMの停止はHealthchecks.ioで補完する。
- 長期メトリクスと横断ログ検索は提供しない。
