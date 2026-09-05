locals {
  manage_router        = var.manage_tailnet && var.manage_subnet_router
  manage_dns           = var.manage_tailnet && var.enable_adguard_dns
  live_acl_policy_json = var.acl_policy_file != "" ? file(var.acl_policy_file) : ""
  live_acl_policy      = try(jsondecode(local.live_acl_policy_json), {})
  acl_approver_routes  = try(toset(keys(local.live_acl_policy.autoApprovers.routes)), toset([]))
}

# This resource is intentionally disabled by default. Before enabling it,
# import the existing policy with `terraform import tailscale_acl.policy acl`.
# It owns the entire tailnet policy, so an unimported apply is not allowed by
# the provider's default overwrite_existing_content=false behavior.
resource "tailscale_acl" "policy" {
  count = var.manage_tailnet ? 1 : 0

  overwrite_existing_content = false
  reset_acl_on_destroy       = false
  # A reviewed live export is mandatory before this resource is enabled. A
  # guessed/minimal policy could silently replace unrelated tailnet grants.
  acl = local.live_acl_policy_json

  lifecycle {
    precondition {
      condition     = trimspace(local.live_acl_policy_json) != "" && can(jsondecode(local.live_acl_policy_json))
      error_message = "manage_tailnet requires a valid live-exported ACL JSON via acl_policy_file or live_acl_policy_json."
    }
    precondition {
      condition     = length(setsubtract(local.acl_approver_routes, var.advertised_routes)) == 0
      error_message = "ACL autoApprovers.routes contains a CIDR not present in advertised_routes; review the live export and route inventory."
    }
  }
}

resource "tailscale_dns_preferences" "magic_dns" {
  count      = var.manage_tailnet ? 1 : 0
  magic_dns  = true
  depends_on = [tailscale_acl.policy]
}

# The tailnet uses one global nameserver for AdGuard. This is gated until the
# Apps VM has passed the final-address/AdGuard readiness check; no split-DNS
# resource is created because the agreed design is global DNS only.
resource "tailscale_dns_nameservers" "adguard" {
  count       = local.manage_dns ? 1 : 0
  nameservers = [var.final_apps_ip]
  depends_on  = [tailscale_acl.policy]
}

data "tailscale_device" "subnet_router" {
  count      = local.manage_router ? 1 : 0
  hostname   = var.subnet_router_hostname
  wait_for   = "30s"
  depends_on = [tailscale_acl.policy]
}

resource "tailscale_device_tags" "subnet_router" {
  count      = local.manage_router ? 1 : 0
  device_id  = data.tailscale_device.subnet_router[0].node_id
  tags       = var.subnet_router_tags
  depends_on = [tailscale_acl.policy]
}

resource "tailscale_device_subnet_routes" "subnet_router" {
  count      = local.manage_router ? 1 : 0
  device_id  = data.tailscale_device.subnet_router[0].node_id
  routes     = var.advertised_routes
  depends_on = [tailscale_acl.policy]
}
