# ADR-0013: Hermes Webapp を Apps VM の Caddy で公開する

- 日付: 2026-11-02
- 状態: 採用（反映状況はこの記録の対象外）
- 関連: [0008](0008-hermes-agent-hindsight-vms.md)、[0009](0009-elastiflow-caddy-fqdn.md)

## 背景

Hermes 上流 main の gateway は Webapp（ブラウザ版 Desktop）を配信できる。
Agent VM を tailnet 外に置く分離方針を維持し、既存の Apps VM の TLS と接続元制限を使いたい。
ADR-0009 は外部 VM への中継を ElastiFlow に限定していた。採用時の判断は保存し、Hermes を追加の例外にする。

## 決定

- `https://hermes.kojigenba-srv.com` を Apps VM の Caddy で TLS 終端し、
  `192.168.10.104:9120` へ HTTP / WebSocket を中継する。Agent VM は tailnet に参加させない。
- Agent gateway は `webapp.enabled: true`、`0.0.0.0:9120` で待ち受ける。
  Docker は Agent LAN IP だけに公開し、nftables の input / DNAT forward で到達元を Apps `.101/32` に限定する。
  Runner `.105` や他 LAN 端末は許可しない。CDP の公開は増やさない。
- Caddy は `admin_networks`、Hermes は同梱 basic provider のフォーム認証を使う。
  Caddy の Basic Auth は重ねない。ユーザー名・scrypt ハッシュ・安定した署名 secret は Agent SOPS bundle から env へ渡し、
  必須キーが不足した apply は停止する。access token TTL は12時間（refresh token は上流の30日）。
- 通常のリモート DNAT は Apps の送信元を保持すると判断し、`dashboard.trusted_proxies` は `.101/32` のみ。
  Docker role は userland-proxy を明示しないため、実際の HTTP peer を反映時に確認する。広い CIDR は使わない。
- 選定版には手動 terminal（gateway の子 PTY がコンテナ内 shell を開く機能）の設定による停止方法がない。
  別 PR の Apps 側 Caddy で `/api/host-terminal` とその配下（`/api/host-terminal/*`）を、
  WebSocket upgrade を含め403で拒否し、ブラウザからの手動 terminal を止める。
  会話・セッション・ファイルに必要な共通 API は遮断しない。
  上流 `web_host_terminal.request_allowed()` への patch は、Caddy を経由しない利用も止めるための将来の選択肢として残す。

## 影響と反映境界

Agent 側は Ansible 手動反映を維持する。Apps 側 Caddy・AdGuard・Homepage・Gatus は別 PR で実装する。
PR 1 の自前イメージ `main-c7da41dd` は公開され、Compose の Hermes と cdp-tunnel はその digest に差し替え済み。
両側の変更と認証キーを揃えて反映する。
9120 の到達元は Apps VM に限定するため、ブラウザからの terminal 経路は Caddy の1か所で遮断する。
Apps VM 自身から backend へ直接接続する経路は残るが、Hermes の認証が必要になる。
Agent tool の Runner SSH 隔離とは別の制御であり、Caddy による遮断は上流機能そのものを無効化しない。
反映後は Caddy 経由の terminal path が403となり、会話・セッション・ファイルなど他の機能が動くことを確認する。
state DB schema 更新により、ロールバックは更新前バックアップと旧イメージ・設定の組から復元する。
具体的なキー登録・確認・2回目 apply の changed=0 は[運用手順](../operations/hermes-agent.md#上流-main--webapp-への更新)に従う。
2026-11-02 のローカル結合試験では、新イメージと本 PR の config、Apps 側 PR の Caddy により、
config の6段階での内容不変、ログインと `__Host-` cookie、会話 WebSocket の接続・ping、
terminal 経路の403、CLI からの DGX 会話、export から rebuild item の構築を確認した。
試験用ネットワーク・内部 CA・メモリ6GiBでの結果であり、本番 apply、Discord、Runner SSH・Chromium、
正常な Hindsight、実 LAN の DNAT・firewall は未検証。実ブラウザ・ファイル操作等の未検証範囲は運用手順に記す。
本番の反映状況を repo から推定しない。
