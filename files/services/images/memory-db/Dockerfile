# PostgreSQL 17 with pgvector + PGroonga for the Hindsight memory database.
#
# Based on Hindsight's own pgroonga recipe
# (hindsight/docker/docker-compose/pgroonga/Dockerfile): PGroonga provides a
# multilingual BM25 index that tokenizes CJK text without a language-specific
# parser, which is what the Japanese banks need. pgvector is layered on top for
# the embedding index. Hindsight's migrations create both extensions in the
# `public` schema on first boot, so no initdb script is needed here.
#
# Pin the base to the multi-arch index digest (repo convention). Override only
# for a reviewed base-image update; dependabot watches this Dockerfile.
ARG PG_IMAGE=groonga/pgroonga:4.0.8-debian-17@sha256:15ab42f1b92749950da640b6d88f5563498a2ac06b2d0aaee1f9185afe34e376

FROM ${PG_IMAGE}

# The base image ships the PostgreSQL PGDG repository and PGroonga. pgvector is
# pinned to the same build Hindsight's recipe installs; the exact Debian
# revision keeps the layer reproducible.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-17-pgvector=0.8.6-1.pgdg13+1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

LABEL org.opencontainers.image.source="https://github.com/koji-genba/homelab" \
    org.opencontainers.image.title="Memory DB (PostgreSQL 17 + pgvector + PGroonga)" \
    org.opencontainers.image.description="Hindsight memory database image for the homelab Agent VM" \
    org.opencontainers.image.licenses="PostgreSQL"
