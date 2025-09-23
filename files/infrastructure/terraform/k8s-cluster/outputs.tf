output "vm_ips" {
  description = "IP addresses of created VMs"
  value = {
    for name, config in local.vms :
    name => {
      vlan10 = config.ip_vlan10
      vlan11 = config.ip_vlan11
    }
  }
}

output "ssh_commands" {
  description = "SSH connection commands"
  value = {
    for name, config in local.vms :
    name => "ssh -i ~/.ssh/k8s_ed25519 ubuntu@${config.ip_vlan10}"
  }
}

output "cluster_info" {
  description = "Kubernetes cluster information"
  value = {
    master_nodes = [for k, v in local.vms : "${k} (VLAN10: ${v.ip_vlan10}, VLAN11: ${v.ip_vlan11})" if contains(["k8s-master01"], k)]
    worker_nodes = [for k, v in local.vms : "${k} (VLAN10: ${v.ip_vlan10}, VLAN11: ${v.ip_vlan11})" if contains(["k8s-worker01", "k8s-worker02"], k)]
    total_nodes  = length(local.vms)
    network_mgmt = "VLAN 10 (192.168.10.0/24) - Management"
    network_svc  = "VLAN 11 (192.168.11.0/24) - Services"
  }
}

output "ansible_inventory_hint" {
  description = "Ansible inventory configuration"
  value = <<-EOT
    Configure ~/kubespray/inventory/mycluster/hosts.yaml with:
    - Master: ${local.vms["k8s-master01"].ip_vlan10} (Management IP)
    - Workers: ${local.vms["k8s-worker01"].ip_vlan10}, ${local.vms["k8s-worker02"].ip_vlan10}
    - SSH Key: ~/.ssh/k8s_ed25519
    - User: ubuntu
    
    Note: Use VLAN10 IPs for management/SSH access
    Note: VLAN11 IPs will be used for MetalLB services
  EOT
}

output "next_steps" {
  description = "Next steps after VM creation"
  value = [
    "1. Wait for VMs to fully boot (1-2 minutes)",
    "2. Test SSH connectivity using the commands above",
    "3. Configure kubespray inventory at ~/kubespray/inventory/mycluster/hosts.yaml",
    "4. Run: cd ~/kubespray && ansible all -i inventory/mycluster/hosts.yaml -m ping --private-key=~/.ssh/k8s_ed25519 --user=ubuntu",
    "5. Deploy cluster: ansible-playbook -i inventory/mycluster/hosts.yaml cluster.yml --become --private-key=~/.ssh/k8s_ed25519 --user=ubuntu",
    "6. Get kubeconfig: scp ubuntu@${local.vms["k8s-master01"].ip_vlan10}:/etc/kubernetes/admin.conf ~/.kube/config",
    "7. Configure MetalLB with VLAN11 IP range (192.168.11.100-200)"
  ]
}

output "vm_details" {
  description = "Detailed VM specifications"
  value = {
    for name, config in local.vms : name => {
      vm_id     = config.vm_id
      ip_vlan10 = config.ip_vlan10
      ip_vlan11 = config.ip_vlan11
      cores     = config.cores
      memory    = "${config.memory}MB"
      disk      = "${config.disk}GB"
      role      = contains(["k8s-master01"], name) ? "master" : "worker"
    }
  }
}

output "metallb_config_hint" {
  description = "MetalLB configuration hint"
  value = <<-EOT
    MetalLB IP Pool Configuration:
    - Range: 192.168.11.100-192.168.11.200
    - Network: VLAN11 (Service Network)
    - Node VLAN11 IPs: ${join(", ", [for k, v in local.vms : v.ip_vlan11])}
    
    After cluster is ready, configure MetalLB with this IP range.
  EOT
}