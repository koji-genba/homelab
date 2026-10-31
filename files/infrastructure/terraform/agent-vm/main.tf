# The Agent VM imports its own copy of the pinned Debian cloud image. The image
# object is intentionally owned by this root only: runner-vm declares a
# different file_name, so two Terraform states never manage the same object.
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
    # Host-specific snippet name; never shared with another Terraform root.
    file_name = "agent-cloud-init.yaml"
    data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      deploy_user    = var.deploy_user
      ssh_public_key = var.ssh_public_key
      vm_name        = var.vm_name
    })
  }
}

resource "proxmox_virtual_environment_vm" "agent" {
  name        = var.vm_name
  vm_id       = var.vm_id
  node_name   = var.node_name
  description = "Homelab Hermes Agent VM; off-tailnet VLAN 10 management address ${var.management_ip}; no public services"
  tags        = ["homelab", "agent", "hermes", "vlan10"]

  started = true
  on_boot = true

  # PVE stopall reverses order; down_delay is the shutdown timeout.
  startup {
    order      = 3
    down_delay = 180
  }

  agent {
    enabled = true
    trim    = true
    type    = "virtio"
  }

  scsi_hardware = "virtio-scsi-single"

  cpu {
    cores   = var.cpu_cores
    sockets = 1
    type    = "host"
    units   = 1024
  }

  memory {
    dedicated = var.memory_mb
    floating  = 0
  }

  # OS disk: imported from the pinned Debian 13 cloud image. This must stay
  # scsi0 so the VM boots without an explicit boot order.
  disk {
    datastore_id = var.datastore_id
    import_from  = proxmox_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = var.os_disk_size_gb
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  # Data disk: blank, formatted and mounted at /srv/agent by Ansible. It is
  # addressed by its stable Proxmox by-id path, not by /dev/sdX ordering.
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi1"
    size         = var.data_disk_size_gb
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

  operating_system {
    type = "l26"
  }

  serial_device {}

  # Cloud-init is consumed at VM creation. Refreshing the creation-time
  # snippet must not replace an existing VM; a new/recreated VM still reads
  # the current snippet ID during creation.
  reboot_after_update = true

  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
    ]
  }
}
