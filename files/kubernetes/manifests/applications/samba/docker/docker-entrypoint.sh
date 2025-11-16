#!/bin/bash
set -e
# Note: Some systems don't allow -x (xtrace) with bash shebangs, so we set it conditionally
if [ -n "$DEBUG_ENTRYPOINT" ]; then
    set -x
fi

# Log configuration
echo "[INFO] Starting Samba configuration..."

# Configure NSS LDAP (nslcd)
echo "[INFO] Configuring NSS LDAP..."
cat > /etc/nslcd.conf <<'EOF'
# nslcd configuration for Samba LDAP integration
uid nslcd
gid nslcd

uri ldap://openldap-ldap.openldap.svc.cluster.local:389

base dc=kojigenba-srv,dc=com
base passwd ou=people,dc=kojigenba-srv,dc=com
base group ou=groups,dc=kojigenba-srv,dc=com

ldap_version 3
binddn cn=admin,dc=kojigenba-srv,dc=com
EOF

# Add LDAP_BIND_PASSWORD to nslcd.conf (must be set before nslcd starts)
if [ -n "$LDAP_BIND_PASSWORD" ]; then
    echo "bindpw $LDAP_BIND_PASSWORD" >> /etc/nslcd.conf
else
    echo "[WARNING] LDAP_BIND_PASSWORD not set, nslcd may fail"
fi

chmod 600 /etc/nslcd.conf
chown nslcd:nslcd /etc/nslcd.conf

echo "[INFO] Configuring NSS to use LDAP..."
cat > /etc/nsswitch.conf <<'EOF'
passwd:         files ldap
group:          files ldap
shadow:         files ldap

hosts:          files dns
networks:       files

protocols:      db files
services:       db files
ethers:         db files
rpc:            db files

netgroup:       nis
EOF

echo "[INFO] Starting nslcd daemon..."
/usr/sbin/nslcd
sleep 2

# Verify nslcd is running
if ! pgrep -x nslcd > /dev/null; then
    echo "[ERROR] nslcd failed to start"
    exit 1
fi

echo "[INFO] nslcd started successfully"

# Verify smb.conf exists
if [ ! -f /etc/samba/smb.conf ]; then
    echo "[ERROR] smb.conf not found at /etc/samba/smb.conf"
    exit 1
fi

# Check if LDAP is configured and configure password
SMBD_CONFIG="/etc/samba/smb.conf"
if grep -q "ldapsam" $SMBD_CONFIG; then
    echo "[INFO] LDAP backend detected, configuring LDAP credentials..."
    if [ -z "$LDAP_BIND_PASSWORD" ]; then
        echo "[ERROR] LDAP_BIND_PASSWORD environment variable not set"
        exit 1
    fi

    # Create working smb.conf in /tmp (ConfigMap is read-only)
    cat $SMBD_CONFIG > /tmp/smb.conf.tmp

    # Add LDAP bind password to the working copy (Samba requires this parameter)
    # Insert after 'ldap admin dn' line in the [global] section
    sed -i '/ldap admin dn/a \    ldap admin password = '"${LDAP_BIND_PASSWORD}" /tmp/smb.conf.tmp

    # Use the modified config file for smbd
    SMBD_CONFIG="/tmp/smb.conf.tmp"

    echo "[INFO] LDAP credentials configured in temporary smb.conf"

    echo "[DEBUG] LDAP config:"
    grep -E "ldap" $SMBD_CONFIG | sed 's/^/  [DEBUG] /'
else
    echo "[INFO] Local backend (tdbsam) configured, LDAP password not required"
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

# Note: Do NOT clear *.tdb files when using ldapsam
# secrets.tdb contains the LDAP password and must be preserved

# Store LDAP password in secrets.tdb after directories are created
if grep -q "ldapsam" $SMBD_CONFIG; then
    echo "[INFO] Storing LDAP password in secrets.tdb..."
    smbpasswd -w "$LDAP_BIND_PASSWORD"
    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to store LDAP password in secrets.tdb"
        exit 1
    fi
    echo "[INFO] LDAP password successfully stored in secrets.tdb"
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
echo "[DEBUG] Configuration backend: $(grep 'passdb backend' $SMBD_CONFIG | head -1)"
echo "[DEBUG] LDAP settings:"
grep -E "ldap|LDAP" $SMBD_CONFIG | sed 's/^/  [DEBUG] /' || echo "  [DEBUG] No LDAP settings found"

# Use higher debug level for LDAP debugging
if grep -q "ldapsam" $SMBD_CONFIG; then
    echo "[INFO] Running with high debug level (-d 10) for LDAP diagnostics..."
    exec /usr/sbin/smbd --foreground --no-process-group -d 10 -s $SMBD_CONFIG 2>&1
else
    echo "[INFO] Running with standard debug level (-d 3) for tdbsam..."
    exec /usr/sbin/smbd --foreground --no-process-group -d 3 -s $SMBD_CONFIG 2>&1
fi
