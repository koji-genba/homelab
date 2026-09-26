# ADR-0007: Apps VMのtailnet addressへ内部DNSを切り替える

- 状態: 承認済み
- 日付: 2026-09-26

## 背景

AdGuardの内部recordとTailscaleのglobal nameserverはApps VMのLAN address
`192.168.10.101`を指す。宅外clientはgatewayの`192.168.10.0/24` subnet routeに依存し、
roaming clientで`accept-routes`を手動切替していた。2026-07には宅内desktopのSMBが
gateway経由でヘアピンし、速度が落ちた（[調査記録](../smb-performance-troubleshooting.md)）。
exit node利用時の内部DNSはPR #56で`Use with exit node`を有効にして解決した。

## 決定

Apps VMを`tag:apps`付きtailnet nodeとして維持し、Caddy、AdGuard、SambaをLAN addressと
固定したtailnet address `100.86.147.127`の両方で公開する。AdGuardはすべての内部service名に
`100.86.147.127`を返し、tailnet global nameserverも同addressへ向ける。
`Use with exit node`を維持し、全tailnet clientで`accept-routes=false`を常用する。

常時宅内のdesktopはSMB shareを`\\192.168.10.101\<share>`で指定し、LANの速度を保つ。
WebはApps VMへの直接WireGuard経路を使う。PVE、IX2215、ElastiFlowなどApps VM以外のLAN管理UIは、
宅外ではgateway exit node経由で利用する。gatewayのexit nodeを維持し、
`192.168.10.0/24`の広告撤去は後日の選択肢とする。

この決定は[ADR-0003](0003-four-network-zones.md)のroaming clientによるsubnet route手動切替だけを
置き換え、[ADR-0004](0004-dns-and-minimal-observability.md)の「Apps VMのDNS」をtailnet addressへ
具体化する。両ADRのその他の判断は維持する。

## 検討した代替案

- client source別のsplit-horizonは採用しない。AdGuardには宅内desktopを含むtailnet clientが
  すべて100.xから見えるため、device別の例外が必要になる。`$dnsrewrite`の回答も加算される。
- LAN用とtailnet用の別名は採用しない。証明書とCaddy設定が重複し、clientで名前を選ぶ必要がある。
- gatewayを廃止してApps VMへexit nodeを移す案は採用しない。service用Docker hostに
  Internet転送とNATを担わせることになる。

## 影響

- tailnet全体の内部DNSはApps VMとtailscaledの稼働に依存する。Healthchecksのprobeで監視する。
- roaming laptopが宅内で名前によってSMBへ接続すると、Apps VMへの直接WireGuard経路の
  単一UDP flowとなる。LAN速度が必要なdesktopはLAN IPを使う。
- tailnet未参加のLAN専用deviceは元からAdGuard clientではなく、影響を受けない。
- VM再構築で100.x addressが変われば、admin consoleで再固定して設定値を整合させる。
