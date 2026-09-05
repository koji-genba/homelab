# Docker Official Image, Debian 13/trixie multi-platform index digest pinned
# (resolved 2026-08-30; the amd64 build uses its matching manifest).
FROM debian:13-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132

ARG TERRAFORM_VERSION=1.15.4
ARG SOPS_VERSION=3.10.2
ARG AGE_VERSION=1.2.1
ARG ANSIBLE_CORE_VERSION=2.19.2
ARG ANSIBLE_LINT_VERSION=25.8.2
ARG SHELLCHECK_VERSION=0.10.0-1
ARG AGE_ARCHIVE_SHA256=7df45a6cc87d4da11cc03a539a7470c15b1041ab2b396af088fe9990f7c79d50
ARG ADGUARD_VERSION=0.107.79
ARG ADGUARD_ARCHIVE_SHA256=c48f4a43000665484c5ec28177de11a004759b620dae8f77b2aabefc9ef3687f

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates curl git libnss-wrapper openssh-client python3 python3-jinja2 python3-pip python3-yaml \
      "shellcheck=${SHELLCHECK_VERSION}" tar unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
      --output /tmp/terraform.zip \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
      --output /tmp/terraform.sha256 \
    && terraform_hash="$(awk -v name="terraform_${TERRAFORM_VERSION}_linux_amd64.zip" '$2 == name { print $1; exit }' /tmp/terraform.sha256)" \
    && test -n "$terraform_hash" \
    && printf '%s  %s\n' "$terraform_hash" /tmp/terraform.zip | sha256sum -c - \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip /tmp/terraform.sha256

RUN curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
      --output /usr/local/bin/sops \
    && curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.checksums.txt" \
      --output /tmp/sops.sha256 \
    && sops_hash="$(awk -v name="sops-v${SOPS_VERSION}.linux.amd64" '$2 == name || $2 ~ ("/" name "$") { print $1; exit }' /tmp/sops.sha256)" \
    && test -n "$sops_hash" \
    && printf '%s  %s\n' "$sops_hash" /usr/local/bin/sops | sha256sum -c - \
    && chmod 0755 /usr/local/bin/sops \
    && rm /tmp/sops.sha256

# age v1.2.1 publishes no checksums.txt asset; its release assets include a
# proof file instead. Keep a separately verified archive hash and fail closed
# if the build input is ever cleared.
RUN curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
      --output /tmp/age.tar.gz \
    && test -n "$AGE_ARCHIVE_SHA256" \
    && printf '%s  %s\n' "$AGE_ARCHIVE_SHA256" /tmp/age.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/age.tar.gz -C /tmp \
    && install -m 0755 /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ \
    && rm -rf /tmp/age /tmp/age.tar.gz

RUN curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${ADGUARD_VERSION}/AdGuardHome_linux_amd64.tar.gz" \
      --output /tmp/adguardhome.tar.gz \
    && printf '%s  %s\n' "${ADGUARD_ARCHIVE_SHA256}" /tmp/adguardhome.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/adguardhome.tar.gz -C /tmp \
    && install -m 0755 /tmp/AdGuardHome/AdGuardHome /usr/local/bin/adguardhome-check \
    && rm -rf /tmp/AdGuardHome /tmp/adguardhome.tar.gz

RUN python3 -m pip install --break-system-packages \
      "ansible-core==${ANSIBLE_CORE_VERSION}" \
      "ansible-lint==${ANSIBLE_LINT_VERSION}"

RUN mkdir -p /usr/share/ansible/collections \
    && ansible-galaxy collection install --collections-path /usr/share/ansible/collections ansible.posix:==2.1.0
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections

# The runner is deliberately started with the invoking host UID/GID. Keep a
# stable path for the NSS shim so the entrypoint can provide that arbitrary
# UID with a passwd/group record without requiring root or changing the image's
# real /etc/passwd.
RUN nss_wrapper_lib="$(dpkg -L libnss-wrapper | awk '/\/libnss_wrapper\.so$/ { print; exit }')" \
    && test -n "$nss_wrapper_lib" \
    && ln -s "$nss_wrapper_lib" /usr/local/lib/libnss_wrapper.so

COPY entrypoint.sh /usr/local/bin/homelab-toolbox
RUN chmod 0755 /usr/local/bin/homelab-toolbox

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/homelab-toolbox"]
