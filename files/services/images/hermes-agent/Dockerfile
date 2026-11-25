# Hermes Agent gateway image with the Hindsight memory provider bundled in.
#
# The upstream image does not ship the Hindsight integration, and the plugin
# catalog is fetched at runtime. Vendoring the integration at a verified commit
# keeps the provider code pinned for review and installs its dependencies at
# build time. Runtime lazy installs must be explicitly disabled in deployment
# config with security.allow_lazy_installs: false; upstream allows them by default.
#
# Upstream facts this relies on (hermes-agent v0.23.4, revision 8fc03744473):
#   * The standard image ships the gateway, the hermes webapp command, and
#     the browser bundle at /opt/hermes/apps/desktop/dist-webapp.
#   * Hermes lives at /opt/hermes and uses Python 3.14.9 in a PM-managed sealed
#     venv at /opt/hermes/.venv. PM exposes its pinned uv through uv_launcher.
#   * Bundled memory providers are discovered under /opt/hermes/plugins/memory/
#     (outside HERMES_HOME=/opt/data, so they survive the data volume mount).
#   * docker.build_agent reassembles source bindings and launchers after the
#     dependency install. See README.md for lock regeneration and validation.
#
# Derived image dependency policy:
#   * The provider's dependencies are installed for local_external mode only;
#     the heavyweight hindsight-embed runtime is intentionally not included.
#   * requirements.txt is a hash-pinned lock compiled against base-constraints.txt
#     from the base venv. The build fails if any existing package version changes.

ARG HERMES_IMAGE=docker.io/nousresearch/hermes-agent:v0.23.4@sha256:ef0650d523ee1b5ab32c779acabc446d9936869a9932591553688a62bcf0c42f

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
# Accept backend-owned cwd paths when moving a session to a project.
# Fail on upstream drift; remove each patch when the pinned base includes its fix.
COPY patches/0001-remote-media-session-key.patch patches/0002-remote-workspace-move.patch /tmp/hermes-patches/

RUN set -eux; \
    cd /opt/hermes; \
    git apply --check /tmp/hermes-patches/*.patch; \
    git apply /tmp/hermes-patches/*.patch; \
    rm -f /tmp/hermes-patches/*.patch \
        gateway/__pycache__/media_fetch.*.pyc gateway/platforms/__pycache__/base.*.pyc \
        gateway/__pycache__/session_mutation_policy.*.pyc gateway/__pycache__/session_policy.*.pyc; \
    /opt/hermes/.venv/bin/python -m compileall -q -f \
        gateway/media_fetch.py gateway/platforms/base.py gateway/session_mutation_policy.py gateway/session_policy.py

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
