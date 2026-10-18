variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, including the trailing slash"
  type        = string
  default     = "https://192.168.10.11:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token (user@realm!token=uuid), supplied through an environment variable"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Allow the Proxmox self-signed certificate"
  type        = bool
  default     = true
}

variable "node_name" {
  description = "Proxmox node on which the Runner VM is created"
  type        = string
  default     = "pve1"
}

variable "datastore_id" {
  description = "Proxmox datastore for the VM disks and cloud-init drive"
  type        = string
  default     = "vmpool"
}

variable "snippet_datastore_id" {
  description = "Proxmox datastore that supports both Import and snippets"
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox bridge for the VLAN 10 server network"
  type        = string
  default     = "vmbr0"
}

variable "management_vlan_id" {
  description = "Server VLAN (VLAN 10) used by the Runner VM"
  type        = number
  default     = 10
}

variable "management_ip" {
  description = "Runner VM management address on VLAN 10"
  type        = string
  default     = "192.168.10.105/24"
}

variable "management_gateway" {
  description = "VLAN 10 gateway"
  type        = string
  default     = "192.168.10.1"
}

variable "dns_servers" {
  description = "Resolvers used only during cloud-init/bootstrap"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "domain" {
  description = "Search domain for the Runner VM"
  type        = string
  default     = "kojigenba-srv.com"
}

variable "vm_id" {
  description = "Proxmox VMID reserved for the Runner VM"
  type        = number
  default     = 105
}

variable "vm_name" {
  description = "Stable Runner VM name"
  type        = string
  default     = "runner"
}

variable "cpu_cores" {
  description = "vCPU cores for the Runner VM (see PRD: 8)"
  type        = number
  default     = 8
}

variable "memory_mb" {
  description = "Dedicated memory in MiB for the Runner VM (see PRD: 16384)"
  type        = number
  default     = 16384
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB"
  type        = number
  default     = 40
}

variable "data_disk_size_gb" {
  description = "Blank work disk size in GiB, mounted at /srv/agent-work"
  type        = number
  default     = 150
}

variable "ssh_public_key" {
  description = "SSH public key installed by cloud-init; no password is configured"
  type        = string
  sensitive   = true
}

variable "deploy_user" {
  description = "Non-root Ansible/deploy account created by cloud-init"
  type        = string
  default     = "deploy"
}

variable "debian_cloud_image_url" {
  description = "Exact Debian 13 generic-cloud image URL. Keep the point-in-time URL pinned."
  type        = string
  # This is intentionally a versioned URL, not a rolling latest URL. Update
  # it only together with debian_cloud_image_checksum.
  default = "https://cloud.debian.org/images/cloud/trixie/20260826-2582/debian-13-genericcloud-amd64-20260826-2582.qcow2"
}

variable "debian_cloud_image_checksum" {
  description = "SHA-512 from the official Debian SHA512SUMS for debian_cloud_image_url"
  type        = string
  # Public integrity metadata, not a secret. Keep synchronized with the
  # point-in-time Debian URL above.
  default = "184761b0dad0f9ace02f9298050ca96ce3caa39a461a47706d47ff9698b59933918b91b40177fbd4d392f6446af8b4d18ecb94caca988169b19641606bf34003"

  validation {
    condition     = can(regex("^[0-9a-fA-F]{128}$", var.debian_cloud_image_checksum))
    error_message = "debian_cloud_image_checksum must be a 128-character SHA-512 digest from Debian."
  }
}

variable "cloud_image_file_name" {
  description = "Name used for the imported image in the Proxmox datastore. Keep it root-specific so two roots never manage the same object."
  type        = string
  default     = "debian-13-genericcloud-amd64-runner.qcow2"
}
