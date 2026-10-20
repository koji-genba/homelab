# Hermes Agent gateway image with the Hindsight memory provider bundled in.
#
# The upstream image does not ship third-party memory plugins, and the plugin
# catalog is fetched at runtime. Vendoring the integration at a pinned commit
# keeps the Agent VM deploy offline-reproducible (`HERMES_DISABLE_LAZY_INSTALLS`
# is on upstream, so nothing is installed from the network on boot) and pins the
# provider code to review.
#
# Upstream facts this relies on (hermes-agent v2026.9.24):
#   * Hermes lives at /opt/hermes; its venv is /opt/hermes/.venv.
#   * Bundled memory providers are discovered under /opt/hermes/plugins/memory/
#     (outside HERMES_HOME=/opt/data, so they survive the data volume mount).
#   * The provider's own dependencies are declared in its pyproject.toml. They are
#     small (hindsight-client and its HTTP/pydantic closure, no torch), so they
#     are installed at build time instead of lazily at first use.
#   * requirements.txt is a hash-pinned lock compiled against base-constraints.txt
#     (the versions already in the base image venv) so installing the provider never
#     upgrades a dependency Hermes pins exactly. See requirements.in for details.

ARG HERMES_IMAGE=docker.io/nousresearch/hermes-agent:v2026.9.24@sha256:fca358f12efd65bfaaca05884166f15c0e2788375ca30d77061ac1ebc96452b7

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

# Vendor the provider into the bundled memory-plugin directory and install the
# dependencies pinned by requirements.txt. `local_external` mode is used, so the
# heavyweight embedded runtime (hindsight-embed) is never imported and its deps
# stay out of the image. `--require-hashes` makes every install hash-verified.
# The `cd /tmp` is required: `uv pip install` run from /opt/hermes picks up that
# project's pyproject.toml and fails --require-hashes on its unpinned deps.
COPY --from=integration /src/hindsight-integrations/hermes/ /opt/hermes/plugins/memory/hindsight/
COPY requirements.txt /tmp/hindsight-requirements.txt

RUN set -eux; \
    rm -rf /opt/hermes/plugins/memory/hindsight/tests; \
    cd /tmp; \
    uv pip install --no-cache --require-hashes --python /opt/hermes/.venv/bin/python \
        -r /tmp/hindsight-requirements.txt; \
    rm -f /tmp/hindsight-requirements.txt; \
    /opt/hermes/.venv/bin/python -m compileall -q /opt/hermes/plugins/memory/hindsight
