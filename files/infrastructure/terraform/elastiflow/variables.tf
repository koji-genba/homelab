variable "proxmox_endpoint" {
  description = "Proxmox API endpoint"
  type        = string
  default     = "https://192.168.10.11:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token (user@realm!token=uuid), supplied through an environment variable"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve1"
}

variable "datastore_id" {
  description = "Storage datastore ID"
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
  description = "VM ID"
  type        = number
  default     = 103
}

variable "ip_address" {
  description = "Static IPv4 address (CIDR) for the VM, on the management VLAN"
  type        = string
  default     = "192.168.10.103/24"
}

variable "template_vm_id" {
  description = "Template VM ID to clone from"
  type        = number
  default     = 9000
}

variable "cpu_cores" {
  description = "Number of CPU cores allocated to the VM"
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "Memory (MB) allocated to the VM"
  type        = number
  default     = 32768
}

variable "disk_size_gb" {
  description = "Root disk size (GB)"
  type        = number
  default     = 128
}
