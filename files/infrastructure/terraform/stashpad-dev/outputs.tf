output "stashpad_dev_ip" {
  description = "stashPadDev VM IP address"
  value       = split("/", var.ip_address)[0]
}

output "vm_info" {
  description = "VM basic information"
  value = {
    vm_id     = proxmox_virtual_environment_vm.stashpad_dev.vm_id
    name      = proxmox_virtual_environment_vm.stashpad_dev.name
    node_name = proxmox_virtual_environment_vm.stashpad_dev.node_name
    cores     = var.cpu_cores
    memory_mb = var.memory_mb
    disk_gb   = var.disk_size_gb
    started   = proxmox_virtual_environment_vm.stashpad_dev.started
  }
}

output "next_steps" {
  description = "Next configuration steps"
  value = [
    "SSH to VM: ssh -i ~/.ssh/id_ed25519 ubuntu@${split("/", var.ip_address)[0]}",
  ]
}
