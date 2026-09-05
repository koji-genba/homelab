output "final_apps_ip" {
  description = "The address Tailscale DNS will use only after the explicit readiness gate"
  value       = var.final_apps_ip
}

output "management_mode" {
  description = "Whether this root is allowed to manage the imported tailnet"
  value       = var.manage_tailnet
}

output "dns_mode" {
  description = "Whether AdGuard is selected as the tailnet global DNS server"
  value       = var.enable_adguard_dns
}
