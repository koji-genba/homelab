#!/bin/bash
set -e

# Log configuration
echo "[INFO] Starting Samba configuration..."

# Verify smb.conf exists
if [ ! -f /etc/samba/smb.conf ]; then
    echo "[ERROR] smb.conf not found at /etc/samba/smb.conf"
    exit 1
fi

# Verify LDAP bind password is set
if [ -z "$LDAP_BIND_PASSWORD" ]; then
    echo "[ERROR] LDAP_BIND_PASSWORD environment variable not set"
    exit 1
fi

# Test smb.conf syntax
echo "[INFO] Validating smb.conf..."
testparm -s > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "[ERROR] smb.conf syntax error:"
    testparm -s
    exit 1
fi

echo "[INFO] smb.conf validation passed"

# Ensure all required directories exist and have correct permissions
mkdir -p /mnt/shared /mnt/archive
chmod 755 /mnt/shared /mnt/archive

# Ensure Samba private directories exist (important for emptyDir mounts)
mkdir -p /var/lib/samba/private
chmod 700 /var/lib/samba/private
mkdir -p /var/cache/samba
chmod 755 /var/cache/samba

# Clean up stale PID files
rm -f /var/run/samba/*.pid 2>/dev/null || true

# Clear Samba cache if it exists
if [ -d /var/lib/samba/private ]; then
    rm -f /var/lib/samba/private/*.tdb 2>/dev/null || true
fi

echo "[INFO] Samba initialization complete"
echo "[INFO] Starting Samba daemon..."
echo "[DEBUG] Command to execute: $@"
echo "[DEBUG] Current working directory: $(pwd)"
echo "[DEBUG] UID/GID: $(id)"
echo "[DEBUG] smbd version: $(smbd --version 2>&1 || echo 'ERROR: smbd not found')"
echo "[DEBUG] smbd path: $(which smbd 2>&1 || echo 'NOT FOUND')"
echo "[DEBUG] /etc/samba/smb.conf exists: $(test -f /etc/samba/smb.conf && echo 'YES' || echo 'NO')"
echo "[DEBUG] /etc/samba/smb.conf readable: $(test -r /etc/samba/smb.conf && echo 'YES' || echo 'NO')"
echo "[DEBUG] /var/lib/samba writable: $(test -w /var/lib/samba && echo 'YES' || echo 'NO')"
echo "[DEBUG] /var/log/samba writable: $(test -w /var/log/samba && echo 'YES' || echo 'NO')"
echo "[DEBUG] /var/run/samba exists: $(test -d /var/run/samba && echo 'YES' || echo 'NO')"

# Run smbd in foreground with debug logging
echo "[INFO] Starting smbd daemon..."
exec /usr/sbin/smbd -F -d 3 -s /etc/samba/smb.conf 2>&1
