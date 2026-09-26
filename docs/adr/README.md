# アーキテクチャ決定記録（ADR）

このディレクトリは、現行構成だけでなく「なぜその構成を選んだか」を残す。
ADR は採用時点の判断を固定するもので、前提が変わった場合は既存 ADR を書き換えず、
新しい ADR で置き換える。

| ADR | 状態 | 判断 |
| --- | --- | --- |
| [0001](0001-single-apps-vm-compose.md) | 承認済み | Kubernetes を単一 Apps VM と Docker Compose へ置き換える |
| [0002](0002-iac-and-deployment-boundaries.md) | 承認済み | Terraform、Ansible、Compose、Git reconcile の責務を分ける |
| [0003](0003-four-network-zones.md) | 承認済み | VLAN を Server、Trusted、IoT、Guest の4ゾーンへ整理する |
| [0004](0004-dns-and-minimal-observability.md) | 承認済み | AdGuard Home と最小監視を採用する |
| [0005](0005-secrets-and-terraform-state.md) | 承認済み | SOPS/age と暗号化 state recovery copy を採用する |
| [0006](0006-ai-dataset-single-export.md) | 承認済み | DGX Spark のデータ置き場を単一 NFS export にする |
| [0007](0007-apps-vm-tailnet-dns.md) | 承認済み | Apps VMのtailnet addressへ内部DNSを切り替える（0003と0004の一部を更新） |
