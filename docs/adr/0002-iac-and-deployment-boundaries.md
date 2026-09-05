# ADR-0002: IaCとデプロイの責務を分ける

- 状態: 承認済み
- 日付: 2026-08-29

## 背景

現行構成では、リポジトリに定義があっても実機との差分や手動導入箇所があり、Git cloneから
復旧できる保証がない。一方、すべてを自動反映にすると、ネットワークやsecretの誤変更が
単一ホスト全体へ直ちに影響する。

## 決定

責務を次のように固定する。

| 層 | 責務 | 反映方法 |
| --- | --- | --- |
| Terraform | Proxmox VM、cloud image、仮想hardware/network、Tailscale管理設定 | 手動 `make` target |
| cloud-init | 最小ユーザー、SSH公開鍵、Ansible到達までのbootstrap | Terraformから投入 |
| Ansible | Docker、NFS mount、directory、systemd、nftables、Compose配置、ログ制限 | 手動 `make` target |
| Compose | コンテナ、network、healthcheck、mount、image digest | Git reconcile対象 |
| SOPS/age | 暗号化secret | 管理端末で復号しAnsibleで転送 |
| systemd timer | main branchのfast-forward同期、検証、対象project更新 | Apps VMで自動 |
| IX2215/ECW5211 | Git上の期待状態と手順 | 実機へ手動反映 |

管理端末には Git、Docker、Make、SSH のみを要求し、Terraform、Ansible、SOPS、lintは
バージョン固定した管理ツールコンテナから実行する。

自動reconcileは、Compose定義、image digest、非secretのCaddy/Gatus設定を対象とする。
AdGuard Homeの設定は管理者認証hashとGit管理のDNS ruleを同時にレンダリングするため、
Ansibleの明示適用対象とする。Terraform、その他のAnsible設定、secret、NFS、systemd、
firewall、物理ネットワークは自動反映しない。CIは検証とimage buildだけを行い、
自宅環境へ接続しない。

## デプロイ手順

1. working treeがcleanであることを確認する。
2. `origin/main` をfetchし、fast-forwardだけを許可する。
3. 変更対象projectを判定する。
4. Composeとservice固有設定を検証する。
5. digest固定imageをpullする。
6. 対象projectだけを更新する。
7. healthcheckと外形probeを通す。
8. commit SHA、image digest、結果をjournalへ記録する。
9. 失敗時は明示した旧commit/digestへ `make rollback-app` で戻す。

## 影響

- アプリケーション更新は簡単になるが、基盤変更には明示操作が必要になる。
- Git main branchがアプリケーションの望ましい状態（desired state）になる。
- 自動rollbackの複雑なcontrollerは導入せず、検証と小さい更新単位で事故範囲を抑える。
