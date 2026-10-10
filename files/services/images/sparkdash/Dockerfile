# The official multi-arch manifest list for Node 22.23.3 (bookworm-slim) is
# pinned here, resolved 2026-10-11. The build requires Node >= 22.19.0.
# Override only for a reviewed base-image update.
ARG NODE_IMAGE=node:22-bookworm-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392
# To bump upstream, review its Dockerfile and config defaults, then update this
# commit and the version label / workflow tag together. Never build a local checkout.
ARG SPARKDASH_REVISION=cc0fcee0043f365335a979cdae1dfdefaf0879ac

FROM ${NODE_IMAGE} AS source
ARG SPARKDASH_REVISION
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN printf '%s\n' "$SPARKDASH_REVISION" | grep -Eq '^[0-9a-f]{40}$' \
    && git init \
    && git fetch --depth 1 https://github.com/MiaAI-Lab/sparkDash.git "$SPARKDASH_REVISION" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$SPARKDASH_REVISION" \
    && git ls-files config | LC_ALL=C sort > /tmp/config-files \
    && printf '%s\n' config/gpu-memory.sh config/settings.json | cmp - /tmp/config-files \
    && git diff --exit-code -- config \
    && rm -rf .git /tmp/config-files

FROM ${NODE_IMAGE} AS builder
WORKDIR /app
# Enforce undici's minimum Node version, including when NODE_IMAGE is overridden.
RUN node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major !== 22 || minor < 19) process.exit(1)'
# Upstream Dockerfile lines 15-23: build dependencies and locked npm install.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ make python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=source /src/package.json /src/package-lock.json ./
RUN npm ci --no-audit --no-fund \
    || (echo "npm ci failed once - retrying" && npm cache clean --force && npm ci --no-audit --no-fund)
# Upstream lines 28-37: frontend build and production dependency pruning.
ARG VITE_HISTORY_HOURS=8
ENV VITE_HISTORY_HOURS=${VITE_HISTORY_HOURS}
COPY --from=source /src/ ./
RUN npm run build
RUN npm prune --omit=dev --no-audit --no-fund \
    || (npm install --omit=dev --no-audit --no-fund && npm prune --omit=dev --no-audit --no-fund)
# Fail if a build script added state/secrets or changed any tracked config default.
COPY --from=source /src/config/ /config-defaults/
RUN diff -r /config-defaults /app/config

FROM ${NODE_IMAGE}
ARG SPARKDASH_REVISION
LABEL org.opencontainers.image.source="https://github.com/koji-genba/homelab" \
    org.opencontainers.image.revision="${SPARKDASH_REVISION}" \
    org.opencontainers.image.version="2.31.0" \
    org.opencontainers.image.licenses="Apache-2.0" \
    org.opencontainers.image.title="sparkDash homelab image" \
    org.opencontainers.image.description="Unofficial sparkDash image for monitoring remote DGX Spark hosts over SSH"
# Upstream lines 45-47: retain all runtime tools, including password SSH support.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client sshpass procps util-linux iproute2 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# Upstream lines 52-61: ship the same frontend, dependencies and server modules.
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/dist ./dist-baked
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/package-lock.json ./package-lock.json
COPY --from=builder /app/server ./server
COPY --from=builder /app/src/shared ./src/shared
COPY --from=builder /app/src/components/ShowcasePage/showcasePrompts.ts ./src/components/ShowcasePage/showcasePrompts.ts
COPY --from=builder /app/config ./config
# Preserve upstream attribution, including the earlier MIT-licensed code notice.
COPY --from=source /src/LICENSE /src/NOTICE /src/THIRD_PARTY_NOTICES.md /src/LICENSE-MIT /licenses/sparkdash/
RUN groupadd --gid 10001 sparkdash \
    && useradd --uid 10001 --gid 10001 --home-dir /app/config --no-create-home --shell /usr/sbin/nologin sparkdash \
    && chown -R 10001:10001 /app/config \
    && chmod 0700 /app/config
# Keep both the passwd home and HOME on the writable config volume for OpenSSH.
ENV PORT=5555 \
    LLM_PORT=8888 \
    NODE_ENV=production \
    HOME=/app/config \
    USER=sparkdash \
    LOGNAME=sparkdash
# Upstream lines 64-74: persistent config, port and plain production command.
VOLUME /app/config
EXPOSE 5555
USER 10001:10001
CMD ["node", "server/index.js"]
