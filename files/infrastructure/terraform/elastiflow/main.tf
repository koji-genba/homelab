# ElastiFlow用LXCコンテナ（unprivileged）
# Elasticsearch / Kibana / ElastiFlow flow-collector は Docker を使わず
# ネイティブ.debパッケージでインストールする（詳細は install.sh 参照）。
# そのため nesting/keyctl などの特権系featureは不要。

resource "proxmox_virtual_environment_container" "elastiflow" {
  node_name    = var.node_name
  vm_id        = var.vm_id
  description  = "ElastiFlow (flow-collector + Elasticsearch + Kibana) - network flow analytics"
  tags         = ["infrastructure", "network", "monitoring"]
  unprivileged = true

  started       = true
  start_on_boot = true

  operating_system {
    template_file_id = var.container_template_file_id
    type             = "debian"
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size_gb
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  initialization {
    hostname = "elastiflow"

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
      keys = [var.ssh_public_key]
    }
  }

  network_interface {
    name    = "eth0"
    bridge  = var.network_bridge
    vlan_id = 10 # 管理VLAN（Tailscale Gatewayと同様、インフラ監視系として配置）
  }

  features {
    nesting = false
  }

  lifecycle {
    ignore_changes = [
      tags,
    ]
  }
}
