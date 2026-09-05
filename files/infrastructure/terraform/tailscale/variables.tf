variable "tailnet" {
  description = "Tailnet ID or legacy tailnet name, supplied after live inventory"
  type        = string
  default     = "example.com"
}

variable "manage_tailnet" {
  description = "Enable manual, import-first management of existing tailnet policy and DNS"
  type        = bool
  default     = false
}

variable "acl_policy_file" {
  description = "Path to the reviewed live tailnet ACL export; required when manage_tailnet is true"
  type        = string
  default     = ""

  validation {
    condition     = !var.manage_tailnet || (var.acl_policy_file != "" && fileexists(var.acl_policy_file))
    error_message = "manage_tailnet requires acl_policy_file pointing to an existing live ACL export."
  }
}

variable "enable_adguard_dns" {
  description = "Permit Tailscale global DNS to use the ready Apps VM AdGuard address"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_adguard_dns || var.manage_tailnet
    error_message = "enable_adguard_dns requires manage_tailnet=true and an explicit reviewed apply."
  }
}

variable "adguard_ready" {
  description = "Operator confirmation that AdGuard is serving the final address"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_adguard_dns || var.adguard_ready
    error_message = "AdGuard DNS cannot be enabled until adguard_ready=true is explicitly set."
  }
}

variable "final_apps_ip" {
  description = "Final single Apps VM service address; this root never claims it"
  type        = string
  default     = "192.168.10.101"

  validation {
    condition     = can(cidrhost("${var.final_apps_ip}/32", 0)) && var.final_apps_ip == "192.168.10.101"
    error_message = "The final Apps address is intentionally fixed to 192.168.10.101 for this migration."
  }
}

variable "subnet_router_hostname" {
  description = "Existing Tailscale device hostname to tag and enable routes on (Tailnet hostname, not the PVE VM name)"
  type        = string
  # The PVE VM is named tailscale-gateway, while its existing Tailnet device
  # hostname is home-gateway. Keep those identities distinct for import-first
  # management of the live router.
  default = "home-gateway"
}

variable "manage_subnet_router" {
  description = "Enable management of the already-registered subnet router device"
  type        = bool
  default     = false
}

variable "subnet_router_tags" {
  description = "Tags to assign to the existing subnet-router device; empty preserves its current untagged state"
  type        = set(string)
  # The live device currently has AdvertiseTags=null and is user-owned. Keep
  # this empty unless a reviewed live export explicitly calls for new tags.
  default = []
}

variable "advertised_routes" {
  description = "Routes already advertised by the imported subnet-router device, including exit-node routes"
  type        = set(string)
  # Preserve every route currently advertised by home-gateway. The default
  # includes both exit-node routes and both local subnet routes so enabling
  # Terraform management cannot withdraw an existing capability implicitly.
  default = [
    "0.0.0.0/0",
    "::/0",
    "192.168.10.0/24",
    "192.168.11.0/24",
  ]
}
