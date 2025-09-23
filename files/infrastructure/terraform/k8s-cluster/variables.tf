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
  description = "SSH public key for VM access"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
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

variable "network_vlan" {
  description = "VLAN ID for k8s management network"
  type        = number
  default     = 10
}

variable "gateway_vlan10" {
  description = "Network gateway for VLAN10"
  type        = string
  default     = "192.168.10.1"
}

variable "gateway_vlan11" {
  description = "Network gateway for VLAN11"
  type        = string
  default     = "192.168.11.1"
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

variable "template_vm_id" {
  description = "Template VM ID to clone from"
  type        = number
  default     = 9000
}