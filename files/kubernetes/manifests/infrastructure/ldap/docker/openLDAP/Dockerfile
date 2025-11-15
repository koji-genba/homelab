# ステージ1: Sambaスキーマ取得
FROM ubuntu:24.04 AS schema-extractor

RUN apt-get update && \
    apt-get install -y curl && \
    curl -L -o /tmp/samba.schema \
      'https://raw.githubusercontent.com/samba-team/samba/master/examples/LDAP/samba.schema' && \
    test -f /tmp/samba.schema || \
      (echo "ERROR: Failed to download samba.schema" && exit 1) && \
    rm -rf /var/lib/apt/lists/*

# ステージ2: 最終イメージ
FROM ubuntu:24.04

# 必要なパッケージのインストール
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
    slapd \
    ldap-utils \
    ca-certificates \
    openssl \
    gettext-base \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Sambaスキーマをコピー
COPY --from=schema-extractor /tmp/samba.schema /etc/ldap/schema/

# スキーマファイルの存在確認
RUN test -f /etc/ldap/schema/samba.schema || \
    (echo "ERROR: samba.schema not found in final image" && exit 1)

# DHパラメータ生成（2048bit、約30秒〜1分）
RUN openssl dhparam -out /etc/ldap/dhparam.pem 2048

# パーミッション設定
RUN chmod 644 /etc/ldap/dhparam.pem && \
    chmod 644 /etc/ldap/schema/samba.schema

# エントリポイントスクリプト
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# データディレクトリ作成
RUN mkdir -p /var/lib/ldap && \
    chown -R openldap:openldap /var/lib/ldap && \
    chmod 700 /var/lib/ldap

# ポート公開
EXPOSE 389 636

# エントリポイント
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
