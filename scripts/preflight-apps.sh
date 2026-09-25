#!/bin/sh
set -eu

management_ip=${APPS_MANAGEMENT_IP:-192.168.10.101}
vmid=${APPS_VMID:-101}
test $# -eq 0 || { echo "usage: $0" >&2; exit 2; }

case "$management_ip" in
  192.168.10.*) ;;
  *) echo "Apps management address must be on VLAN 10: $management_ip" >&2; exit 1 ;;
esac
case "$vmid" in
  ''|*[!0-9]*) echo "APPS_VMID must be numeric: $vmid" >&2; exit 1 ;;
esac
last_octet=${management_ip##*.}
case "$last_octet" in
  ''|*[!0-9]*) echo "APPS_MANAGEMENT_IP must be an IPv4 address: $management_ip" >&2; exit 1 ;;
esac
if [ "$last_octet" -lt 100 ] || [ "$last_octet" -gt 254 ]; then
  echo "Apps management address must use a valid Proxmox VMID octet: $management_ip" >&2
  exit 1
fi
test "$vmid" -eq "$last_octet" || {
  echo "APPS_VMID ($vmid) must match the management IP's fourth octet ($last_octet)" >&2
  exit 1
}

cat <<EOF
Apps preflight (static check only; no address is assigned)
  VMID:          $vmid
  Management IP: $management_ip
  Confirm that the ID is free and the previous VM has released this IP before apply.
EOF
