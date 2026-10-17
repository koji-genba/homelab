output "runner_vm_id" {
  description = "Proxmox VMID of the Runner VM"
  value       = proxmox_virtual_environment_vm.runner.vm_id
}

output "runner_management_address" {
  description = "VLAN 10 management address of the Runner VM"
  value       = var.management_ip
}

output "runner_data_disk_size_gb" {
  description = "Size of the Runner VM work disk mounted at /srv/agent-work"
  value       = var.data_disk_size_gb
}
