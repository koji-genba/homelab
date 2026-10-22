terraform {
  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Pin the exact provider build used by this root. Must match apps-vm.
      version = "0.117.0"
    }
  }
}
