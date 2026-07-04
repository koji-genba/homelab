output "elastiflow_ip" {
  description = "ElastiFlow container IP address"
  value       = split("/", var.ip_address)[0]
}

output "kibana_url" {
  description = "Kibana Web UI URL"
  value       = "http://${split("/", var.ip_address)[0]}:5601"
}

output "sflow_collector_target" {
  description = "IX2215側でsFlow collectorとして設定するIP:ポート"
  value       = "${split("/", var.ip_address)[0]}:6343"
}

output "next_steps" {
  description = "Next configuration steps"
  value = [
    "1. SSH to container: ssh root@${split("/", var.ip_address)[0]}",
    "2. Run the setup script: scp install.sh root@${split("/", var.ip_address)[0]}:/root/ && ssh root@${split("/", var.ip_address)[0]} bash /root/install.sh",
    "3. Configure sFlow export on IX2215 (see ../../network/README.md)",
    "4. Open Kibana at http://${split("/", var.ip_address)[0]}:5601 and import the ElastiFlow dashboards",
  ]
}
