# Tailscale Gateway VM の出力定義
# 現在の設定が適切なため変更不要

output "tailscale_gateway_ip" {
  description = "Tailscale Gateway VM IP address"
  value       = "192.168.10.30"
}

output "advertised_routes" {
  description = "Routes to be advertised by Tailscale subnet router"
  value = {
    management = "192.168.10.0/24"
    services   = "192.168.11.0/24"
  }
}

# 追加で有用な情報（オプション）
output "vm_info" {
  description = "VM basic information"
  value = {
    vm_id     = proxmox_virtual_environment_vm.tailscale_gateway.vm_id
    name      = proxmox_virtual_environment_vm.tailscale_gateway.name
    node_name = proxmox_virtual_environment_vm.tailscale_gateway.node_name
    started   = proxmox_virtual_environment_vm.tailscale_gateway.started
  }
}

output "next_steps" {
  description = "Next configuration steps"
  value = [
    "1. SSH to VM: ssh -i ~/.ssh/k8s_ed25519 ubuntu@192.168.10.30",
    "2. Authenticate Tailscale: sudo tailscale up --advertise-routes=192.168.10.0/24,192.168.11.0/24 --accept-dns=false --hostname=home-gateway",
    "3. Approve routes in Tailscale admin console",
    "4. Test connection from mobile device"
  ]
}