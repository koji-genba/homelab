# Docker Compose projectの構成

各directoryは独立してdeployできるprojectである。全projectが外部の`homelab_frontend` networkに参加する。
定義は11 projects / 12 services（searxngだけ2 services）である。起動順は
`edge dns samba stashpad-prod stashpad-staging sillytavern open-webui searxng sparkdash homepage monitoring`、停止は逆順。
[Homepage](../../../docs/operations/homepage.md)は静的YAMLによるサービスリンク集である。
設定6ファイル（YAML 4件、`custom.css`、`custom.js`）をread-only bindし、logsと生成ファイルはtmpfsに置く。Docker socketは渡さない。
[sparkDash](../../../docs/operations/sparkdash.md)は専用named volumeでconfigを保持するremote monitorで、
初回はimageからuid/gid 10001とmode 0700を引き継ぐ。自動backupは構築せず、VM外の暗号化backupも必須とせず、volume喪失時は再deployとUIでの2台の再登録で復旧する。

HTTP(S)のentry pointはedge projectだけで、DNSとSMBは必要なhost portだけを公開する。
内部名はApps VMのtailnet IPへ解決される（[ADR-0007](../../../docs/adr/0007-apps-vm-tailnet-dns.md)）。
host portを公開するprojectは、LAN側の`*_BIND_IP`に加えて`${APPS_TAILNET_IP}`にもbindする。
LAN側だけだとtailnet clientから届かない。新しいFQDNは
`files/infrastructure/ansible/apps/roles/secrets/templates/AdGuardHome.yaml.j2`の`rewrites`へ
`{{ web_ip }}`で追加し、`scripts/tests/adguard-config-fixture.sh`の`service_names`も更新する。Ansible roleが共有
networkを確認・作成し、project起動前にNFS mount guardを成功させる。Composeには意図的にrestart policyを設定しない。
systemdの`homelab-apps.service`を唯一の起動主体とすることで、Dockerがboot時に未検証のlocal directoryを
bind mountして復旧することを防ぐ。

`SECRETS_DIR`はAnsible secrets roleが生成したfileを指す。このtreeに平文の値を置かない。各projectの
literalな`image:`がimageのsource of truthであり、Dependabotはproject単位のupdateを作成できる。
cutover前に限りtagを許可する。lifecycle helperは`docker compose config --images`を実行し、application
gate有効時は全serviceが完全な`repo@sha256:<64 hex chars>`参照であることを要求する。

## projectの追加

全体手順は[アプリケーションのライフサイクル](../../../docs/operations/application-lifecycle.md#新しいcompose-projectの追加)を
参照する。

- 新しいdirectoryの`compose.yaml`を追加し、[Compose roleのtasks](../../infrastructure/ansible/apps/roles/compose/tasks/main.yml)のdigest gate一覧へ追加する。
- 同roleの[起動](../../infrastructure/ansible/apps/roles/compose/templates/homelab-compose-up.sh.j2)、[停止](../../infrastructure/ansible/apps/roles/compose/templates/homelab-compose-down.sh.j2)、[rollback](../../infrastructure/ansible/apps/roles/compose/templates/homelab-rollback-app.sh.j2)、[dead-man](../../infrastructure/ansible/apps/roles/compose/templates/healthchecks-ping.sh.j2)、[reconcile](../../infrastructure/ansible/apps/roles/compose/templates/homelab-app-reconcile.sh.j2)のproject一覧を更新する。reconcileはpath判定と`.env.example`変更時の全project一覧を持つ。
- 管理端末側の[rollback allow-list](../../../scripts/rollback-app.sh)と[Dependabot](../../../.github/dependabot.yml)のdirectoryを更新する。
- secretが必要なら[secrets role](../../infrastructure/ansible/apps/roles/secrets/tasks/main.yml)、[key inventory](../../infrastructure/secrets/runtime.yaml.example)、暗号化bundleを更新する。envが必要なら[compose.env template](../../infrastructure/ansible/apps/roles/compose/templates/compose.env.j2)と[.env.example](.env.example)を更新し、検証用の[compose-config.sh](../../../scripts/compose-config.sh)にもsecret/envを用意する。
- 新しいFQDNのAdGuard rewriteと[DNS fixture](../../../scripts/tests/adguard-config-fixture.sh)を更新する。NFSが必要なら[group_vars](../../infrastructure/ansible/apps/group_vars/apps.yml)のmount / marker宣言も更新する。

初回追加はApps VMのcheckoutを更新した後、管理端末の最新checkoutから`make ansible-apply`を実行する。
Compose roleのGit taskは`update: false`で、Ansible自体は既存checkoutを進めない。
secret / AdGuard設定 / `compose.env`の変更を検出すると、cutover有効時に全11 projectsをforce-recreateする。

## image更新と管理用wrapper

stagingは定期実行の`stashpad-staging-image` workflowが更新する。publicな
`ghcr.io/koji-genba/stashpad:edge`のmanifest digestを解決し、変更するのは
`stashpad-staging/compose.yaml`だけである。productionはこのworkflowから編集せず、review済みcommitで
promotionする。workflowが`main`へpushできるのはrepository permissionとbranch protectionが許可する場合
だけである。protected branchではscheduleを有効にする前に、review対象update PRを作成する設定にする。

管理用Make wrapperは、version固定toolbox内でTerraform、Ansible、SOPS、age、linterを実行する。
repositoryをhost UID/GIDとしてmountし、`SSH_AUTH_SOCK`が設定されている場合だけSSH agentを渡す。
`AGE_IDENTITY_FILE`が指定された場合だけ、復旧したage identityを
`/run/secrets/age-identity`へread-onlyでmountする。state-backup worktree用にcontainerの`/tmp`は書込み可能
なままにする。wrapperはhost credential helperをmountしないため、HTTPSによるstate-backup pushはサポートしない。
SSH origin/push URLを設定してoptional agentを使う。credentialを丸ごとtoolboxやApps VMへmountしない。
