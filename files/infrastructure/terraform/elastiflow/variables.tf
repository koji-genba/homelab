variable "proxmox_endpoint" {
  description = "Proxmox API endpoint"
  type        = string
  default     = "https://192.168.10.11:8006/"
}

variable "proxmox_username" {
  description = "Proxmox username"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for root access to the container"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve1"
}

variable "datastore_id" {
  description = "Storage datastore ID for the container disk"
  type        = string
  default     = "vmpool"
}

variable "network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.10.1"
}

variable "dns_servers" {
  description = "DNS servers"
  type        = list(string)
  default     = ["192.168.10.1", "8.8.8.8"]
}

variable "domain" {
  description = "DNS domain"
  type        = string
  default     = "kojigenba-srv.com"
}

variable "vm_id" {
  description = "Container ID (CTID)"
  type        = number
  default     = 110
}

variable "ip_address" {
  description = "Static IPv4 address (CIDR) for the container, on the management VLAN"
  type        = string
  default     = "192.168.10.40/24"
}

variable "container_template_file_id" {
  description = <<-EOT
    LXC template file ID, as registered in Proxmox storage (e.g. via `pveam download local <template>`).
    Check `pveam available | grep debian-12` on the Proxmox host for the current file name.
  EOT
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
}

variable "cpu_cores" {
  description = "Number of CPU cores allocated to the container"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Memory (MB) allocated to the container"
  type        = number
  default     = 4096
}

variable "swap_mb" {
  description = "Swap (MB) allocated to the container"
  type        = number
  default     = 512
}

variable "disk_size_gb" {
  description = "Root disk size (GB)"
  type        = number
  default     = 32
}
