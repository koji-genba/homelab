FROM ubuntu:24.04

# DNS機能インストール
RUN apt-get update && apt-get install -y \
    unbound \
    unbound-anchor \
    ca-certificates \
    dnsutils \
    curl \
    && rm -rf /var/lib/apt/lists/*

# unboundユーザーはパッケージで既に作成済み
# 必要なディレクトリ作成と権限設定
RUN mkdir -p /opt/unbound/etc/unbound/local-zones \
    && mkdir -p /opt/unbound/var/lib/unbound \
    && mkdir -p /shared/local-zones \
    && mkdir -p /shared/rpz \
    && chown -R unbound:unbound /opt/unbound /shared

# エントリーポイントスクリプトコピー
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# DNS用ポートのみ公開
EXPOSE 5353/tcp 5353/udp

# unbound専用ユーザーで実行
USER unbound
ENTRYPOINT ["/entrypoint.sh"]