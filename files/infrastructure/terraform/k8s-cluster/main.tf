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
      - nfs-common
      - rpcbind
      - dnsutils
      - telnet
      - tcpdump
      - rsync
      - tree
      - unzip
    
    package_update: true
    package_upgrade: false
    timezone: Asia/Tokyo
    
    runcmd:
      - systemctl enable --now qemu-guest-agent
      - systemctl enable --now rpcbind
      - echo "VM initialized with comprehensive toolset at $(date)" > /var/log/cloud-init-custom.log
      - hostnamectl set-hostname $(hostname -s)
      - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
      - sysctl -p
    
    final_message: "Cloud-init completed with comprehensive toolset at $TIMESTAMP"
    EOF

    file_name = "k8s-cloud-init.yaml"
  }
}

# VM定義をlocalsで管理
locals {
  vms = {
    "k8s-master01" = {
      vm_id    = 101
      cores    = 2
      memory   = 6144
      disk     = 50
      ip_vlan10 = "192.168.10.21"
      ip_vlan11 = "192.168.11.21"
    }
    "k8s-worker01" = {
      vm_id    = 102
      cores    = 2
      memory   = 4096
      disk     = 40
      ip_vlan10 = "192.168.10.22"
      ip_vlan11 = "192.168.11.22"
    }
    "k8s-worker02" = {
      vm_id    = 103
      cores    = 2
      memory   = 4096
      disk     = 40
      ip_vlan10 = "192.168.10.23"
      ip_vlan11 = "192.168.11.23"
    }
  }
}

# VMリソース（for_eachで一括定義）
resource "proxmox_virtual_environment_vm" "k8s_nodes" {
  for_each = local.vms

  name        = each.key
  node_name   = var.node_name
  vm_id       = each.value.vm_id
  description = "Kubernetes ${contains(["k8s-master01"], each.key) ? "Master" : "Worker"} Node"
  tags        = contains(["k8s-master01"], each.key) ? ["kubernetes", "master"] : ["kubernetes", "worker"]
  
  # 起動時の動作設定
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
    datastore_id = "vmpool"  # 明示的にvmpoolを指定
  }

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "host"
    units   = 1024
  }

  memory {
    dedicated = each.value.memory
    floating  = 0  # バルーニング無効
  }

  disk {
    datastore_id = "vmpool"  # 明示的にvmpoolを指定
    size         = each.value.disk
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
  }

  initialization {
    datastore_id = "vmpool"  # Cloud-initディスクもvmpoolに配置
    
    # VLAN10 IP設定（管理用）
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan10}/24"
        gateway = var.gateway_vlan10
      }
    }

    # VLAN11 IP設定（サービス用）
    ip_config {
      ipv4 {
        address = "${each.value.ip_vlan11}/24"
        gateway = var.gateway_vlan11
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

  # VLAN10 NIC（管理用）
  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = 10
  }

  # VLAN11 NIC（サービス用）
  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = 11
  }

  operating_system {
    type = "l26"  # Linux 2.6 - 6.X Kernel
  }

  serial_device {}  # シリアルコンソール有効化

  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      clone[0].vm_id,
      tags,
    ]
  }
}

# VM作成完了を待つためのnull_resource
resource "null_resource" "wait_for_vms" {
  depends_on = [proxmox_virtual_environment_vm.k8s_nodes]

  provisioner "local-exec" {
    command = "echo 'Waiting for VMs to be ready...' && sleep 30"
  }
}