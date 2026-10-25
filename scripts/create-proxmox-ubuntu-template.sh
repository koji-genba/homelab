#!/bin/bash
set -euo pipefail
umask 077

image_url=https://cloud-images.ubuntu.com/releases/noble/release-20260518/ubuntu-24.04-server-cloudimg-amd64.img
image_sha256=53fdde898feed8b027d94baa9cfe8229867f330a1d9c49dc7d84465ee7f229f7
image_path=/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64-release-20260518.img
vmid=
storage=vmpool

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { echo "Usage: $0 --vmid VMID [--storage STORAGE] (root on pve1)"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --vmid|--storage)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --vmid) [ -z "$vmid" ] || die "duplicate --vmid"; vmid=$2 ;;
        --storage) storage=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ "$vmid" =~ ^[1-9][0-9]{2,8}$ ]] || die "--vmid must be 100..999999999 (required)"
[[ "$storage" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "invalid storage ID"
[ "$(id -u)" -eq 0 ] || die "run as root on pve1"
[ "$(hostname -s)" = pve1 ] || die "run locally on pve1"
for command in qm pvesh pvesm qemu-img curl sha256sum python3 flock mktemp; do
  command -v "$command" >/dev/null || die "$command is required"
done

# Serialize this helper's VMID checks and image-cache writes on pve1.
exec 9>/run/lock/homelab-ubuntu-template.lock
flock -n 9 || die "another template creation is running"
work_dir=$(mktemp -d)
download=
creation_attempted=0
stage=preflight
show_config() {
  python3 -c '
import sys
keys = set("boot cores cpu ide2 machine memory name net0 scsi0 scsihw serial0 template vga ostype agent bios citype onboot".split())
for line in sys.stdin:
    if line.partition(":")[0] in keys:
        print(line, end="")
'
}
cleanup() {
  result=$?
  trap - EXIT
  [ -z "$download" ] || rm -f -- "$download"
  if [ "$result" -ne 0 ]; then
    echo "Failed at: $stage; verified image cache (if present): $image_path" >&2
    if [ "$creation_attempted" -eq 1 ]; then
      echo "VMID $vmid and any allocated volumes are NOT deleted. Inspect before manual cleanup:" >&2
      qm config "$vmid" | show_config || echo "qm config failed; inspect VMID $vmid manually" >&2
      pvesm list "$storage" --vmid "$vmid" || echo "volume listing failed; inspect storage $storage manually" >&2
    fi
  fi
  rm -rf -- "$work_dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

check_vmid() {
  pvesh get /cluster/resources --type vm --output-format json >"$work_dir/resources.json"
  python3 - "$work_dir/resources.json" "$vmid" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    resources = json.load(source)
if not isinstance(resources, list):
    sys.exit("invalid cluster resources response")
for resource in resources:
    if not isinstance(resource, dict) or resource.get("type") not in ("qemu", "lxc"):
        sys.exit("invalid VM resource in cluster response")
    value = resource.get("vmid")
    if isinstance(value, bool) or not str(value).isdigit():
        sys.exit("missing/invalid VMID in cluster response")
    if int(value) == int(sys.argv[2]):
        sys.exit(f"VMID {value} already exists in cluster; refusing to overwrite")
PY
}
check_vmid
pvesh get "/nodes/pve1/storage/$storage/status" --output-format json >"$work_dir/storage.json"
python3 - "$work_dir/storage.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    status = json.load(source)
if status.get("active") != 1 or status.get("enabled") != 1:
    sys.exit("storage must be active and enabled")
if "images" not in status.get("content", "").split(","):
    sys.exit("storage must support VM images")
PY

verify_checksum() {
  printf '%s  %s\n' "$image_sha256" "$1" | sha256sum --check --status
}
stage=image
mkdir -p -- "$(dirname -- "$image_path")"
[ ! -L "$image_path" ] || die "image cache must not be a symlink"
if [ -e "$image_path" ]; then
  [ -f "$image_path" ] || die "image cache is not a regular file"
  if ! verify_checksum "$image_path"; then
    rm -f -- "$image_path"
    die "cached image checksum mismatch; removed $image_path"
  fi
  echo "Reusing verified image: $image_path"
else
  download=$(mktemp "${image_path}.download.XXXXXX")
  # The pinned release redirects to the HTTP archive; SHA256 is mandatory.
  curl --fail --location --proto '=https,http' --proto-redir '=https,http' \
    --retry 3 --output "$download" "$image_url"
  verify_checksum "$download" || die "downloaded image checksum mismatch"
  mv -- "$download" "$image_path"
  download=
fi
qemu-img info --output=json "$image_path" >"$work_dir/image.json"
python3 - "$work_dir/image.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    image = json.load(source)
if image.get("format") != "qcow2" or image.get("virtual-size") != 3758096384:
    sys.exit("unexpected source image format/virtual-size")
PY

# Check again after the download. qm create also refuses a concurrently taken ID.
stage=create
check_vmid
creation_attempted=1
# Untagged bridge SDN.Use is required at clone time; use VLAN 10 to match the ACL.
qm create "$vmid" --name ubuntu-2404-cloudinit \
  --memory 2048 --cores 2 --cpu host --machine q35 \
  --net0 virtio,bridge=vmbr0,tag=10 --scsihw virtio-scsi-pci \
  --serial0 socket --vga serial0
stage=import
qm set "$vmid" --scsi0 "${storage}:0,import-from=${image_path},discard=on,ssd=1"
stage=cloudinit
qm set "$vmid" --ide2 "${storage}:cloudinit"
stage=boot
qm set "$vmid" --boot order=scsi0
stage=template
qm template "$vmid"
stage=verify
qm config "$vmid" >"$work_dir/config"
show_config <"$work_dir/config"
python3 - "$work_dir/config" "$vmid" "$storage" <<'PY'
import re
import sys
with open(sys.argv[1]) as source:
    config = dict(line.rstrip("\n").split(": ", 1) for line in source if ": " in line)
vmid, storage = sys.argv[2:]
expected = {
    "boot": "order=scsi0", "cores": "2", "cpu": "host", "machine": "q35",
    "memory": "2048", "name": "ubuntu-2404-cloudinit", "scsihw": "virtio-scsi-pci",
    "serial0": "socket", "template": "1", "vga": "serial0",
    "ide2": f"{storage}:vm-{vmid}-cloudinit,media=cdrom",
    "net0": "virtio,bridge=vmbr0,tag=10",
    "scsi0": f"{storage}:base-{vmid}-disk-N,discard=on,size=3584M,ssd=1",
}
failed = False
for key, want in expected.items():
    actual = config.get(key, "<absent>")
    normalized = actual
    if key == "net0":
        normalized = re.sub(r"^virtio=(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?=,)", "virtio", actual)
    if key == "scsi0":
        normalized = re.sub(r"^" + re.escape(f"{storage}:base-{vmid}-disk-") + r"[0-9]+(?=,)",
                            f"{storage}:base-{vmid}-disk-N", actual)
    # PVE may reorder comma-separated properties.
    ok = sorted(normalized.split(",")) == sorted(want.split(","))
    print(f"{'OK' if ok else 'MISMATCH'} {key}: expected={want}; actual={actual}")
    failed |= not ok
for key in ("ostype", "agent", "bios", "citype", "onboot"):
    ok = key not in config
    print(f"{'OK' if ok else 'MISMATCH'} {key}: expected=<absent>; actual={config.get(key, '<absent>')}")
    failed |= not ok
if failed:
    sys.exit("template configuration mismatch; inspect manually")
with open(sys.argv[1] + ".volume", "w") as target:
    target.write(config["scsi0"].split(",")[0])
PY
disk_path=$(pvesm path "$(cat "$work_dir/config.volume")")
qemu-img info --output=json "$disk_path" >"$work_dir/disk.json"
python3 - "$work_dir/disk.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    disk = json.load(source)
for key, expected in (("format", "raw"), ("virtual-size", 3758096384)):
    ok = disk.get(key) == expected
    print(f"{'OK' if ok else 'MISMATCH'} disk {key}: expected={expected}; actual={disk.get(key)}")
    if not ok:
        sys.exit("template disk mismatch; inspect manually")
PY
echo "Template $vmid created and verified (not booted)."
