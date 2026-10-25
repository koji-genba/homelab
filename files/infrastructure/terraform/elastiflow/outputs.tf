output "elastiflow_ip" {
  description = "ElastiFlow VM IP address"
  value       = split("/", var.ip_address)[0]
}

output "kibana_url" {
  description = "Kibana Web UI URL"
  value       = "https://elastiflow.kojigenba-srv.com"
}

output "sflow_collector_target" {
  description = "IX2215側でsFlow collectorとして設定するIP:ポート"
  value       = "${split("/", var.ip_address)[0]}:6343"
}

output "next_steps" {
  description = "Next configuration steps"
  value = [
    "1. Wait for cloud-init completion on VM ${split("/", var.ip_address)[0]} and prepare SSH-agent / known_hosts",
    "2. From repository root, run make ansible-apply-elastiflow (packages, configuration and pinned dashboards)",
    "3. Configure sFlow export on IX2215 (see ../../network/README.md)",
    "4. Open https://elastiflow.kojigenba-srv.com and verify ingestion / dashboards; re-run Ansible to check changed=0",
  ]
}
