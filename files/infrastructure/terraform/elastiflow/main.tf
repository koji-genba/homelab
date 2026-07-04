# Cloud-init用ユーザーデータ
resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name

  source_raw {
    data = <<-EOF
    #cloud-config
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ${var.ssh_public_key}
        sudo: ALL=(ALL) NOPASSWD:ALL

    packages:
      - qemu-guest-agent
      - net-tools
      - curl
      - wget
      - vim
      - htop
      - tmux
      - jq
      - dnsutils
      - tcpdump
      - ca-certificates
      - gnupg
      - apt-transport-https
      - libpcap-dev

    package_update: true
    package_upgrade: false
    timezone: Asia/Tokyo

    runcmd:
      - systemctl enable --now qemu-guest-agent
      - echo "ElastiFlow VM initialized at $(date)" > /var/log/cloud-init-custom.log
      - hostnamectl set-hostname elastiflow

    final_message: "Cloud-init completed at $TIMESTAMP"
    EOF

    file_name = "elastiflow-cloud-init.yaml"
  }
}

# VM定義（k8s実績ベース）
resource "proxmox_virtual_environment_vm" "elastiflow" {
  name        = "elastiflow"
  node_name   = var.node_name
  vm_id       = var.vm_id
  description = "ElastiFlow (flow-collector + Elasticsearch + Kibana) - network flow analytics"
  tags        = ["infrastructure", "network", "monitoring"]

  started = true
  on_boot = true

  agent {
    enabled = true
    trim    = true
    type    = "virtio"
  }

  clone {
    vm_id        = var.template_vm_id
    full         = true
    datastore_id = var.datastore_id
  }

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

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size_gb
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  initialization {
    datastore_id = var.datastore_id

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.domain
    }

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_config.id
  }

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = 10
    queues  = var.cpu_cores
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      clone[0].vm_id,
      tags,
    ]
  }
}
