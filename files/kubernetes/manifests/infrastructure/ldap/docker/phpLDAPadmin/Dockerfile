FROM phpldapadmin/phpldapadmin:2.3.4

# Switch to root to install packages
USER root

# Add debugging and diagnostic tools on top of the official image
RUN apk add --no-cache \
    tcpdump \
    strace \
    openldap-clients \
    net-tools \
    bind-tools \
    curl \
    wget

# Switch back to www-data
USER www-data
