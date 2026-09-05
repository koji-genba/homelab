terraform {
  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Pin the exact provider build used by this root.
      version = "= 0.111.1"
    }
  }
}
