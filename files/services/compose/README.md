# Docker Compose projectの構成

各directoryは独立してdeployできるprojectである。全projectが外部の`homelab_frontend` networkに参加する。
HTTP(S)のentry pointはedge projectだけで、DNSとSMBは必要なhost portだけを公開する。Ansible roleはNFS
mount guardの成功後にnetworkを作成し、projectを起動する。Composeには意図的にrestart policyを設定しない。
systemdの`homelab-apps.service`を唯一の起動主体とすることで、Dockerがboot時に未検証のlocal directoryを
bind mountして復旧することを防ぐ。

`SECRETS_DIR`はAnsible secrets roleが生成したfileを指す。このtreeに平文の値を置かない。各projectの
literalな`image:`がimageのsource of truthであり、Dependabotはproject単位のupdateを作成できる。
cutover前に限りtagを許可する。lifecycle helperは`docker compose config --images`を実行し、application
gate有効時は全serviceが完全な`repo@sha256:<64 hex chars>`参照であることを要求する。

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
