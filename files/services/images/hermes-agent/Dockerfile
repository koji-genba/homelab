# Hermes Agent gateway image with the Hindsight memory provider bundled in.
#
# The upstream image does not ship the Hindsight integration, and the plugin
# catalog is fetched at runtime. Vendoring the integration at a verified commit
# keeps the provider code pinned for review and installs its dependencies at
# build time. Runtime lazy installs must be explicitly disabled in deployment
# config with security.allow_lazy_installs: false; upstream allows them by default.
#
# Upstream facts this relies on (hermes-agent main, revision c7da41dd):
#   * Hermes lives at /opt/hermes and uses Python 3.14 in a PM-managed sealed
#     venv at /opt/hermes/.venv. PM also supplies the pinned uv executable.
#   * Bundled memory providers are discovered under /opt/hermes/plugins/memory/
#     (outside HERMES_HOME=/opt/data, so they survive the data volume mount).
#   * The provider's dependencies are installed for local_external mode only;
#     the heavyweight hindsight-embed runtime is intentionally not included.
#   * requirements.txt is a hash-pinned lock compiled against base-constraints.txt
#     from the base venv. The build fails if any existing package version changes.
#   * docker.build_agent reassembles source bindings and launchers after the
#     dependency install. See README.md for lock regeneration and validation.

ARG HERMES_IMAGE=docker.io/nousresearch/hermes-agent:main@sha256:e39055b7c9c0a7655a84cdce601fe6bdcef2740e1b524744375424b66fed6495

# Hindsight integration revision (vectorize-io/hindsight). This is the release
# pinned by the Hermes plugin catalog entry used for this stack; bump together
# with the memory-db image when the API contract changes.
ARG HINDSIGHT_INTEGRATION_REVISION=d952b6e655fccab4581ee0722b51c5f103873d12

FROM ${HERMES_IMAGE} AS integration

ARG HINDSIGHT_INTEGRATION_REVISION

RUN set -eux; \
    git init -q /src; \
    git -C /src remote add origin https://github.com/vectorize-io/hindsight.git; \
    git -C /src fetch -q --depth 1 origin "${HINDSIGHT_INTEGRATION_REVISION}"; \
    git -C /src checkout -q --detach FETCH_HEAD; \
    test "$(git -C /src rev-parse HEAD)" = "${HINDSIGHT_INTEGRATION_REVISION}"; \
    rm -rf /src/.git

FROM ${HERMES_IMAGE}

ARG HINDSIGHT_INTEGRATION_REVISION

LABEL org.opencontainers.image.source="https://github.com/koji-genba/homelab" \
    org.opencontainers.image.title="Hermes Agent (Hindsight memory provider)" \
    org.opencontainers.image.description="Hermes Agent gateway for the homelab Agent VM, with the Hindsight memory provider vendored at a pinned revision" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.revision="${HINDSIGHT_INTEGRATION_REVISION}"

# Keep remote MEDIA delivery working after the handler clears its session context.
# Fail on upstream drift; remove when the pinned base includes the upstream fix.
COPY patches/0001-remote-media-session-key.patch /tmp/remote-media-session-key.patch

RUN set -eux; \
    cd /opt/hermes; \
    git apply --check /tmp/remote-media-session-key.patch; \
    git apply /tmp/remote-media-session-key.patch; \
    rm -f /tmp/remote-media-session-key.patch \
        gateway/__pycache__/media_fetch.*.pyc gateway/platforms/__pycache__/base.*.pyc; \
    /opt/hermes/.venv/bin/python -m compileall -q -f gateway/media_fetch.py gateway/platforms/base.py

# Use PM's bundled uv only at build time to add hash-verified dependencies.
# install-dependencies.py fails if any existing package version changes.
# Reassemble source bindings and launchers with the upstream assembler afterward.
COPY --from=integration /src/hindsight-integrations/hermes/ /opt/hermes/plugins/memory/hindsight/
COPY requirements.txt install-dependencies.py /tmp/hindsight-build/

RUN set -eux; \
    rm -rf /opt/hermes/plugins/memory/hindsight/tests; \
    /opt/hermes/.venv/bin/python /tmp/hindsight-build/install-dependencies.py; \
    /opt/hermes/.venv/bin/python -m docker.build_agent; \
    /opt/hermes/.venv/bin/python -m compileall -q /opt/hermes/plugins/memory/hindsight; \
    rm -rf /tmp/hindsight-build
