# ADR-0001: Kubernetesを単一Apps VMとDocker Composeへ置き換える

- 状態: 承認済み
- 日付: 2026-08-29

## 背景

現在の Kubernetes は、単一の Proxmox 物理ホスト上に control plane 1台と worker 2台を
配置している。利用者向けワークロードは stashPad prod/staging、SillyTavern、Samba、Unbound
の5 Podである一方、クラスタ維持のための Pod は約37個ある。物理ホスト障害に対する可用性は
増えておらず、導入方式も Terraform、Kubespray、手動 manifest、Helm、Flux に分散した。

優先順位は、復旧の容易さ、日常運用、機能追加、理解しやすさ、費用の順とする。学習目的で
Kubernetes を維持する必要はない。ただし、現在利用している機能は減らさない。

## 決定

Proxmox 上に Debian 13 の `apps` VMを1台作り、rootful Docker Engine と Docker Compose v2
でサービスを実行する。初期リソースは4 vCPU、12 GiB RAM、40 GiB root diskとする。

Composeプロジェクトは次の単位に分ける。

- `edge`: Caddy
- `dns`: AdGuard Home
- `samba`: Samba
- `stashpad-prod`
- `stashpad-staging`
- `sillytavern`
- `monitoring`: Gatus

Webプロジェクトは外部公開しない共有frontend networkでCaddyに接続する。Docker socketは
コンテナへ渡さない。ホストで公開するサービスportは、最終的に DNS 53、HTTP 80、
HTTPS 443、SMB 445だけとする。

## 理由

- 単一物理ホストでは、3台の Kubernetes VMは物理障害の可用性を増やさない。
- Composeは現在の単一replicaワークロードと運用規模に合う。
- プロジェクトを分けることで、Webアプリの更新時にDNSやSambaを再作成せずに済む。
- VM境界は Proxmox のIaC、スナップショット、コンソール、リソース制御をそのまま利用できる。
- k3s/Nomadはクラスタ運用を残し、Podman Quadletは既存イメージとCompose資産の移植コストを
  増やすため採用しない。

## 影響

- Apps VMの停止で全サービスが停止する。これは現在の単一物理ホストという障害境界と同じで、
  許容する。
- コンテナ再起動順序だけに頼らず、NFSマウントをsystemdで検証してfail closedにする。
- データはNFS上に置き、Apps VMを使い捨て可能にする。
- 復旧性はVMスナップショットではなく、VMを削除してIaCから再構築する試験で確認する。
