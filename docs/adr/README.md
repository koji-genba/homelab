# アーキテクチャ決定記録（ADR）

このディレクトリは、現行構成だけでなく「なぜその構成を選んだか」を残す。
ADR は採用時点の判断を固定するもので、前提が変わった場合は既存 ADR を書き換えず、
新しい ADR で置き換える。

| ADR | 状態 | 判断 |
| --- | --- | --- |
| [0001](0001-single-apps-vm-compose.md) | 承認済み | Kubernetes を単一 Apps VM と Docker Compose へ置き換える |
| [0002](0002-iac-and-deployment-boundaries.md) | 承認済み | Terraform、Ansible、Compose、Git reconcile の責務を分ける |
| [0003](0003-four-network-zones.md) | 実装済み（2026-09-13）。Port 4変更も実機反映済み（2026-09-19） | VLAN を Server、Trusted、IoT、Guest の4ゾーンへ整理する。roaming clientのsubnet route手動切替は[0007](0007-apps-vm-tailnet-dns.md)で置き換え |
| [0004](0004-dns-and-minimal-observability.md) | 承認済み | AdGuard Home と最小監視を採用する。global nameserverの接続先は[0007](0007-apps-vm-tailnet-dns.md)で具体化 |
| [0005](0005-secrets-and-terraform-state.md) | 承認済み | SOPS/age と暗号化 state recovery copy を採用する |
| [0006](0006-ai-dataset-single-export.md) | 承認済み。repo定義済み、pve1/Apps VMは反映済み、DGX 2台の手順Cも2026-10-12に実施済みと確認 | DGX Spark のデータ置き場を単一 NFS export にする。pve1/Apps VMは2026-09-19に反映済み。DGXの実施日は不明、read速度は未測定（[確認方法・記録](../operations/dgx-storage.md#手動反映の記録)） |
| [0007](0007-apps-vm-tailnet-dns.md) | 承認済み。2026-10-12補足あり | Apps VMのtailnet addressへ内部DNSを切り替える（0003と0004の一部を更新）。補足でSMBの正式な接続先とServer route維持を明記 |
| [0008](0008-hermes-agent-hindsight-vms.md) | 実装済み（repo定義済み、2026-10-17）。実機では未検証（初回構築は未実施、ローカル品質閾値は一部達成、創作・rerank速度に残課題） | Hermes常駐エージェントとHindsight記憶をAgent VM（104）とRunner VM（105）へ分離して追加する。Ansible手動反映、Composeはreconcile対象外、記憶はRuri-v3 + PGroonga |
