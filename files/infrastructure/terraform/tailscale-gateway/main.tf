# k8s実績ベースのTailscale Gateway VM設定
# 成功実績のあるk8s-cluster設定をベースに必要最小限の変更のみ

# Cloud-init用ユーザーデータ（k8sベース + Tailscale特化）
resource "proxmox_virtual_environment_file" "tailscale_cloud_config" {
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
    
    # 基本パッケージ（k8s実績ベース、Tailscale特化）
    packages:
      - qemu-guest-agent      # ← k8sで実績あり（重要）
      - curl                  # Tailscale インストール用
      - iptables             # Subnet Router用
      - net-tools            # ネットワーク管理用
      - dnsutils             # DNS動作確認用
    
    package_update: true
    package_upgrade: false
    timezone: Asia/Tokyo
    
    # k8s実績ベースのruncmd（Tailscale特化）
    runcmd:
      - systemctl enable --now qemu-guest-agent  # ← k8s実績設定（重要）
      - echo "VM initialized at $(date)" > /var/log/cloud-init-custom.log
      - hostnamectl set-hostname tailscale-gateway
      
      # IP転送有効化（Subnet Router必須）
      - echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
      - echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
      - sysctl -p
      
      # UDP GRO forwarding最適化
      - ethtool -K eth0 rx-udp-gro-forwarding on 2>/dev/null || true
      - ethtool -K eth1 rx-udp-gro-forwarding on 2>/dev/null || true
      
      # Tailscale公式インストール
      - curl -fsSL https://tailscale.com/install.sh | sh
      - systemctl enable tailscaled
      - systemctl start tailscaled
      
      # 完了ログ
      - echo "Tailscale Gateway setup completed at $(date)" > /var/log/tailscale-setup.log
    
    final_message: "Cloud-init completed at $TIMESTAMP"
    EOF

    file_name = "tailscale-cloud-init.yaml"
  }
}

# VM定義（k8s実績ベース、Tailscale用にカスタマイズ）
resource "proxmox_virtual_environment_vm" "tailscale_gateway" {
  name        = "tailscale-gateway"
  node_name   = var.node_name
  vm_id       = 105
  description = "Tailscale Subnet Router for external access"
  tags        = ["infrastructure", "network", "tailscale"]
  
  started = true
  on_boot = true

  # k8s実績ベースのagent設定
  agent {
    enabled = true
    trim    = true
    type    = "virtio"
    # k8sではタイムアウト指定なしで成功 → 同じ設定を採用
  }

  # k8s実績ベースのclone設定
  clone {
    vm_id        = var.template_vm_id
    full         = true
    datastore_id = "vmpool"  # k8s実績設定
  }

  # CPU設定（k8s worker相当）
  cpu {
    cores   = 1
    sockets = 1
    type    = "host"
    units   = 1024
  }

  # メモリ設定（Tailscale Gateway最適化）
  memory {
    dedicated = 768   # k8s: 4-6GB → Tailscale: 768MB（適度に確保）
    floating  = 0     # k8s実績設定
  }

  # ディスク設定（k8s実績ベース、テンプレートサイズ維持）
  disk {
    datastore_id = "vmpool"  # k8s実績設定
    size         = 20        # テンプレートサイズ（リサイズ制限回避）
    interface    = "scsi0"
    iothread     = true      # k8s実績設定
    ssd          = true      # k8s実績設定  
    discard      = "on"      # k8s実績設定
  }

  # 初期化設定（k8s実績ベース）
  initialization {
    datastore_id = "vmpool"  # k8s実績設定
    
    ip_config {
      ipv4 {
        address = "192.168.10.30/24"
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
    
    user_data_file_id = proxmox_virtual_environment_file.tailscale_cloud_config.id
  }

  # ネットワーク設定（k8s実績ベース、VLAN10のみ）
  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = 10  # 管理VLAN（k8s実績）
  }

  # OS設定（k8s実績）
  operating_system {
    type = "l26"
  }

  # シリアルデバイス（k8s実績）
  serial_device {}

  # ライフサイクル（k8s実績ベース）
  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      clone[0].vm_id,
      tags,
    ]
  }
}