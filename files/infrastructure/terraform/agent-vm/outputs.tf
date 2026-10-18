output "agent_vm_id" {
  description = "Proxmox VMID of the Agent VM"
  value       = proxmox_virtual_environment_vm.agent.vm_id
}

output "agent_management_address" {
  description = "VLAN 10 management address of the Agent VM"
  value       = var.management_ip
}

output "agent_data_disk_size_gb" {
  description = "Size of the Agent VM data disk mounted at /srv/agent"
  value       = var.data_disk_size_gb
}
