#!/bin/sh
set -eu

phase1_ip=${PHASE1_IP:-192.168.10.42}
vmid=${APPS_VMID:-112}
service_iface=${LEGACY_SERVICE_INTERFACE:-ens19}

case "$phase1_ip" in
  192.168.10.*) ;;
  *) echo "Phase 1 address must be on VLAN 10: $phase1_ip" >&2; exit 1 ;;
esac
case "$vmid" in
  ''|*[!0-9]*) echo "APPS_VMID must be numeric: $vmid" >&2; exit 1 ;;
esac

cat <<EOF
Apps preflight (no address is assigned by this script)
  VMID:        $vmid (must not be 101-103 while Kubernetes exists)
  Phase 1 IP:  $phase1_ip (confirm unused; current DHCP pool is .100-.200)
  VLAN 11 NIC: $service_iface (address-less until explicit cutover)
  final mgmt:  192.168.10.101 (manual migration target)
  legacy IPs:  192.168.11.100, .101, .103 (manual takeover targets)
EOF

if [ "${1:-}" != "--cutover" ]; then
  echo "Static preflight complete. Use --cutover only after old owners are stopped and ARP is checked."
  exit 0
fi

test "${CUTOVER_CONFIRM:-}" = "I_HAVE_STOPPED_OLD_OWNERS" || {
  echo "set CUTOVER_CONFIRM=I_HAVE_STOPPED_OLD_OWNERS after stopping old MetalLB/DHCP owners" >&2
  exit 1
}
command -v arping >/dev/null 2>&1 || { echo "arping is required for cutover checks" >&2; exit 1; }
command -v ip >/dev/null 2>&1 || { echo "iproute2 is required for cutover checks" >&2; exit 1; }

for address in 192.168.11.100 192.168.11.101 192.168.11.103; do
  echo "ARP duplicate-address check: $address on $service_iface"
  arping -D -I "$service_iface" -c 2 -w 3 "$address"
done
echo "ARP checks passed; assigning addresses remains a separate explicit Ansible run."
