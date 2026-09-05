output "apps_vm_id" {
  description = "Proxmox VMID of the Apps VM"
  value       = proxmox_virtual_environment_vm.apps.vm_id
}

output "phase1_management_address" {
  description = "Address assigned during the non-disruptive Phase 1 bootstrap"
  value       = var.management_ip
}

output "planned_final_management_address" {
  description = "Final management address; informational only and not configured here"
  value       = var.final_management_ip
}
