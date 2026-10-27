# Official OCI index, resolved from GHCR on 2026-10-26.
ARG DAGU_IMAGE=ghcr.io/dagucloud/dagu:2.22.4@sha256:1232ed10472497012b3c51987618774909b6b7dba2226514acf5a90a807c4c1d
FROM ${DAGU_IMAGE}
LABEL org.opencontainers.image.source="https://github.com/koji-genba/homelab" \
    org.opencontainers.image.title="Dagu Hugging Face downloader" \
    org.opencontainers.image.version="2.22.4-hf2.3.0"
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/hf \
    && rm -f /etc/sudoers.d/* \
    && chmod u-s /usr/bin/sudo \
    && groupadd --gid 10002 hf-downloader \
    && useradd --uid 10002 --gid 10002 --home-dir /var/lib/dagu --no-create-home --shell /usr/sbin/nologin hf-downloader \
    && mkdir -p /var/lib/dagu \
    && chown -R 10002:10002 /var/lib/dagu \
    && chmod 0700 /var/lib/dagu
COPY requirements.txt /tmp/hf-requirements.txt
RUN /opt/hf/bin/pip install --no-cache-dir --require-hashes -r /tmp/hf-requirements.txt \
    && rm /tmp/hf-requirements.txt
ENV PATH="/opt/hf/bin:${PATH}" HOME=/var/lib/dagu HF_HOME=/var/lib/dagu/hf
# Bypass the upstream root/sudo entrypoint. Config, DAG and helpers are bind mounts.
ENTRYPOINT ["/usr/local/bin/tini", "-g", "--"]
WORKDIR /var/lib/dagu
USER 10002:10002
CMD ["dagu", "start-all"]
