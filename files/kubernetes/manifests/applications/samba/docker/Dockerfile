FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install Samba and dependencies
RUN apt-get update && apt-get install -y \
    samba \
    samba-common \
    samba-common-bin \
    samba-vfs-modules \
    samba-dsdb-modules \
    smbclient \
    ldap-utils \
    libpam-ldapd \
    libnss-ldapd \
    nslcd \
    tdb-tools \
    acl \
    xattr \
    supervisor \
    rsyslog \
    cron \
    dos2unix \
    strace \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /var/log/samba \
    && mkdir -p /var/lib/samba/private \
    && mkdir -p /mnt/shared \
    && mkdir -p /mnt/archive \
    && mkdir -p /var/run/samba

# Set permissions
RUN chmod 755 /var/log/samba \
    && chmod 755 /var/lib/samba \
    && chmod 700 /var/lib/samba/private \
    && chmod 755 /mnt/shared \
    && chmod 755 /mnt/archive

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose SMB3 port (TCP 445 only)
EXPOSE 445/tcp

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD smbclient -L localhost -U% 2>/dev/null | grep -q Server || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
