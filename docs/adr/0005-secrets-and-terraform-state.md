# ADR-0005: SOPS/ageと暗号化state recovery copyを採用する

- 状態: 承認済み
- 日付: 2026-08-29

## 背景

Gitを唯一の信頼できる情報源（source of truth）にしながら、credentialを平文で保存したくない。単一管理者のhomelabに
remote state serviceやsecret managerを増やすと、復旧時の依存と運用負荷が増える。

## 決定

secretはSOPS/ageで暗号化してmain branchに保存する。日常用age private keyは管理端末、
recovery copyはKeePassXCに保存する。Apps VMにはage private keyを置かない。deploy時に管理端末で
復号し、Ansibleが`/etc/homelab/secrets`へroot所有、mode `0600`で転送する。

Terraform provider credentialはKeePassXCから管理端末へ一時注入し、Makeのallowlist経由で
対応するTerraform rootのtoolboxへ環境変数として渡す。runtime SOPS bundleには含めず、VM
passwordやTailscale auth keyをTerraform resourceに保持しない設計を優先する。

Terraform stateは各rootの管理端末ローカルfileをactive stateとする。apply成功後、state全体を
age暗号化し、同じGit remoteの`state-backup`専用branchへrecovery copyとして保存する。

- 平文 `*.tfstate*` はGit ignoreし、mode `0600`とする。preflight/backupは別modeを拒否し、
  自動修正しない。
- `state-backup` branchのfileはTerraform backendとして使わない。
- 単一管理者前提のためremote lockingは導入しない。
- backup前に暗号化結果を復号可能か検査する。
- CIで平文state、private key、既知secret pathの混入を拒否する。
- stateを失った場合に備え、既存resourceのimport手順も残す。

自作imageは秘密を含めず、public GHCRで配布する。private registry tokenという追加secretを
Apps VMへ持ち込まない。

## 既存リポジトリの整理

worktreeには既存環境のTerraform stateやsecret実体があるが、2026-08-29の確認時点ではignoreされ、
Git履歴にも追跡記録はなかった。新構成でもこの境界をCIで検査する。旧credentialのrotate/revokeは
漏洩対応ではなく、Kubernetes廃止後に不要な権限を残さないため実施する。

## 影響

- 復旧に必要な外部要素はGit remote、KeePassXC内のage鍵とprovider credentialになる。
- age鍵が漏洩した場合、SOPS secretとstate backupの両方が影響を受けるため、鍵管理を共通の
  セキュリティ境界として扱う。
- SaaS state backendは不要だが、複数人による同時applyには対応しない。
