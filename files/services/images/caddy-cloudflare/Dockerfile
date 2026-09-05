# The official multi-architecture manifest digests are pinned here so local
# builds and CI consume the same Caddy inputs. Override only for a reviewed
# base-image update.
ARG CADDY_BUILDER_IMAGE=caddy:2.11.4-builder@sha256:4bdeabce8e79d36b23d1cba7d20598cec2c1117ace960d8ca06071f945e8fc9b
ARG CADDY_RUNTIME_IMAGE=caddy:2.11.4@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d
FROM ${CADDY_BUILDER_IMAGE} AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4

FROM ${CADDY_RUNTIME_IMAGE}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
