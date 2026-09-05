resource "proxmox_download_file" "debian_cloud_image" {
  content_type       = "import"
  datastore_id       = var.snippet_datastore_id
  node_name          = var.node_name
  url                = var.debian_cloud_image_url
  file_name          = var.cloud_image_file_name
  checksum           = var.debian_cloud_image_checksum
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = var.snippet_datastore_id
  node_name    = var.node_name

  source_raw {
    file_name = "apps-cloud-init.yaml"
    data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      deploy_user    = var.deploy_user
      ssh_public_key = var.ssh_public_key
    })
  }
}

resource "proxmox_virtual_environment_vm" "apps" {
  name        = var.vm_name
  vm_id       = var.vm_id
  node_name   = var.node_name
  description = "Homelab Apps VM; Phase 1 management address ${var.management_ip}; final address is planned, not claimed"
  tags        = ["homelab", "apps", "docker", "phase1"]

  started = true
  on_boot = true

  agent {
    enabled = true
    trim    = true
    type    = "virtio"
  }

  scsi_hardware = "virtio-scsi-single"

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
    units   = 1024
  }

  memory {
    dedicated = 12288
    floating  = 0
  }

  # Import the downloaded cloud image directly; no hand-maintained template
  # VM or clone source is involved.
  disk {
    datastore_id = var.datastore_id
    import_from  = proxmox_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = 40
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = var.management_ip
        gateway = var.management_gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.domain
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_config.id
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.management_vlan_id
  }

  # The second NIC is deliberately address-less. Ansible/systemd-networkd
  # adds legacy service addresses only after a human-confirmed cutover.
  dynamic "network_device" {
    for_each = var.legacy_service_nic ? [true] : []
    content {
      bridge  = var.network_bridge
      model   = "virtio"
      vlan_id = var.service_vlan_id
    }
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

}
