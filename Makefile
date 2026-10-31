SHELL := /bin/sh

TERRAFORM_ROOT ?= files/infrastructure/terraform/apps-vm
ANSIBLE_ROOT ?= files/infrastructure/ansible/apps
ANSIBLE_INVENTORY ?= $(ANSIBLE_ROOT)/inventory/hosts.yml
TAILSCALE_ROOT ?= files/infrastructure/terraform/tailscale
# Hermes Agent/Runner VM (WS1). Separate roots so their state never mixes with
# the Apps VM state; validated in CI via the dedicated validate targets.
AGENT_VM_ROOT ?= files/infrastructure/terraform/agent-vm
RUNNER_VM_ROOT ?= files/infrastructure/terraform/runner-vm
# Legacy Proxmox VM roots, validated without backend access in CI.
ELASTIFLOW_ROOT ?= files/infrastructure/terraform/elastiflow
TAILSCALE_GATEWAY_ROOT ?= files/infrastructure/terraform/tailscale-gateway
STASHPAD_DEV_ROOT ?= files/infrastructure/terraform/stashpad-dev
# Hermes OS-level Ansible root (groups `agent` and `runner`). ANSIBLE_CONFIG is
# set explicitly because ansible-playbook only reads ansible.cfg from the
# working directory; the Agent root reuses generic roles from the Apps root
# through roles_path.
AGENT_ANSIBLE_ROOT ?= files/infrastructure/ansible/agent
AGENT_ANSIBLE_INVENTORY ?= $(AGENT_ANSIBLE_ROOT)/inventory/hosts.yml
AGENT_ANSIBLE_CONFIG ?= $(AGENT_ANSIBLE_ROOT)/ansible.cfg
# Registered gateway prefs use their own Ansible root and SSH-agent inventory.
GATEWAY_ANSIBLE_ROOT ?= files/infrastructure/ansible/gateway
GATEWAY_ANSIBLE_INVENTORY ?= $(GATEWAY_ANSIBLE_ROOT)/inventory/hosts.yml
GATEWAY_ANSIBLE_CONFIG ?= $(GATEWAY_ANSIBLE_ROOT)/ansible.cfg
GATEWAY_ANSIBLE_ARGS ?=
# ElastiFlow native packages and dashboards, separate from Apps reconcile.
ELASTIFLOW_ANSIBLE_ROOT ?= files/infrastructure/ansible/elastiflow
ELASTIFLOW_ANSIBLE_INVENTORY ?= $(ELASTIFLOW_ANSIBLE_ROOT)/inventory/hosts.yml
ELASTIFLOW_ANSIBLE_CONFIG ?= $(ELASTIFLOW_ANSIBLE_ROOT)/ansible.cfg
ELASTIFLOW_ANSIBLE_ARGS ?=
TERRAFORM_PLAN_ARGS ?=
TERRAFORM_PLAN_NAME := terraform.tfplan
TAILSCALE_PLAN_NAME := terraform.tfplan
TERRAFORM_PLAN_FILE := $(TERRAFORM_ROOT)/$(TERRAFORM_PLAN_NAME)
TAILSCALE_PLAN_FILE := $(TAILSCALE_ROOT)/$(TAILSCALE_PLAN_NAME)
TAILSCALE_ACL_POLICY_REL := $(if $(ACL_POLICY_FILE),$(patsubst $(CURDIR)/%,%,$(abspath $(ACL_POLICY_FILE))),)
TAILSCALE_ACL_POLICY_CONTAINER := /workspace/$(TAILSCALE_ACL_POLICY_REL)
TAILSCALE_ACL_BACKUP_FILE ?= files/infrastructure/secrets/tailscale/acl-policy.sops.json
TAILSCALE_VAR_ARGS := $(if $(MANAGE_TAILNET),-var="manage_tailnet=$(MANAGE_TAILNET)",) \
	$(if $(MANAGE_SUBNET_ROUTER),-var="manage_subnet_router=$(MANAGE_SUBNET_ROUTER)",) \
	$(if $(ENABLE_ADGUARD_DNS),-var="enable_adguard_dns=$(ENABLE_ADGUARD_DNS)",) \
	$(if $(ADGUARD_READY),-var="adguard_ready=$(ADGUARD_READY)",) \
	$(if $(ADGUARD_NAMESERVER_IP),-var="adguard_nameserver_ip=$(ADGUARD_NAMESERVER_IP)",) \
	$(if $(ACL_POLICY_FILE),-var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)",)
# toolboxはdigestで固定して実行する。publish workflowは`.github/workflows/toolbox-image.yml`
# 自身の変更でも起動し、同じ`:1.0.1`タグを上書きするため、タグ参照では引かれるimageが再現しない。
# 2026-09-06のPR #8（actions/checkoutのbump）はDockerfileを変えていないのにtagを
# sha256:7607f2c7...からsha256:9da8408a...へ移した。compose.yamlが全imageをdigest固定するのと
# 同じ規律をtoolboxにも適用する。
# imageを更新するときは、workflowのpublish後に`docker buildx imagetools inspect`で
# 新しいdigestを確認し、TOOLBOX_IMAGE_DIGESTを差し替える。
# ローカルでビルドしたimageを試すときは`make TOOLBOX_IMAGE=ghcr.io/koji-genba/homelab-toolbox:1.0.1 ansible-check`のように明示する（実際のTOOLBOX_IMAGE_REPO / TOOLBOX_IMAGE_TAGに合わせる）。
TOOLBOX_IMAGE_REPO ?= ghcr.io/koji-genba/homelab-toolbox
TOOLBOX_IMAGE_TAG ?= 1.0.1
TOOLBOX_IMAGE_DIGEST ?= sha256:f334f3e98592af0e58b7d939f8c357ca9b549b549086e1812b516ebce4197155
TOOLBOX_IMAGE ?= $(TOOLBOX_IMAGE_REPO)@$(TOOLBOX_IMAGE_DIGEST)
TOOLBOX_BUILD_IMAGE ?= $(TOOLBOX_IMAGE_REPO):$(TOOLBOX_IMAGE_TAG)
TOOLBOX_USERNAME ?= homelab-toolbox
TOOLBOX_USER := $(shell id -u):$(shell id -g)
TOOLBOX_SSH_MOUNT := $(if $(SSH_AUTH_SOCK),-v "$(SSH_AUTH_SOCK):/run/ssh-agent" -e SSH_AUTH_SOCK=/run/ssh-agent,)
TOOLBOX_AGE_MOUNT := $(if $(AGE_IDENTITY_FILE),-v "$(AGE_IDENTITY_FILE):/run/secrets/age-identity:ro" -e AGE_IDENTITY_FILE=/run/secrets/age-identity -e SOPS_AGE_KEY_FILE=/run/secrets/age-identity,)
TOOLBOX_KNOWN_HOSTS_MOUNT := $(if $(wildcard $(HOME)/.ssh/known_hosts),-v "$(HOME)/.ssh/known_hosts:/etc/ssh/ssh_known_hosts:ro",)
TOOLBOX_RECIPIENT_ENV := $(if $(AGE_RECIPIENT),-e AGE_RECIPIENT=$(AGE_RECIPIENT),)
# Provider credentials are added only to the runner for the matching root.
# The `-e NAME` form deliberately keeps secret values out of Make's expansion
# and dry-run output.
TOOLBOX_PROXMOX_ENV := \
	-e TF_VAR_proxmox_api_token \
	-e TF_VAR_ssh_public_key
TOOLBOX_TAILSCALE_ENV := \
	-e TAILSCALE_OAUTH_CLIENT_ID \
	-e TAILSCALE_OAUTH_CLIENT_SECRET \
	-e TAILSCALE_API_KEY

# Management host prerequisite: Git, Docker, Make and SSH. Terraform,
# Ansible, SOPS, age, shellcheck, and linters run in the pinned toolbox.
# The repository is mounted as the invoking UID/GID. The toolbox's own
# container-local /tmp is writable for state-backup worktrees. A recovered age
# identity is mounted separately and read-only only when AGE_IDENTITY_FILE is
# supplied; it is never copied into the repository or the Apps VM.
TOOLBOX_RUN_BASE = docker run --rm --network host --user $(TOOLBOX_USER) \
	-v "$(CURDIR):/workspace" -w /workspace \
	$(TOOLBOX_SSH_MOUNT) $(TOOLBOX_AGE_MOUNT) $(TOOLBOX_KNOWN_HOSTS_MOUNT) \
	$(TOOLBOX_RECIPIENT_ENV) \
	-e HOME=/tmp/homelab-toolbox -e USER=$(TOOLBOX_USERNAME) -e LOGNAME=$(TOOLBOX_USERNAME)
TOOLBOX_RUN = $(TOOLBOX_RUN_BASE) $(TOOLBOX_IMAGE)
TOOLBOX_PROXMOX_RUN = $(TOOLBOX_RUN_BASE) $(TOOLBOX_PROXMOX_ENV) $(TOOLBOX_IMAGE)
TOOLBOX_TAILSCALE_RUN = $(TOOLBOX_RUN_BASE) $(TOOLBOX_TAILSCALE_ENV) $(TOOLBOX_IMAGE)

.PHONY: toolbox-build toolbox-requirements terraform-init terraform-fmt terraform-validate terraform-validate-tailscale terraform-validate-agent-vm terraform-validate-runner-vm terraform-validate-elastiflow terraform-validate-tailscale-gateway terraform-validate-stashpad-dev terraform-plan terraform-apply
.PHONY: ansible-lint-elastiflow ansible-check-elastiflow ansible-apply-elastiflow
.PHONY: ansible-lint ansible-check ansible-apply ansible-lint-agent ansible-check-agent ansible-apply-agent ansible-lint-gateway ansible-check-gateway ansible-apply-gateway gateway-routes-test ansible-bootstrap-paths-test compose-reconcile-fixture terraform-apps-vm-lifecycle-test terraform-agent-runner-vm-lifecycle-test toolbox-uid-test cloud-init-test agent-vm-cloud-init-test runner-vm-cloud-init-test runner-privilege-fixture runner-firewall-fixture agent-runner-scope-fixture agent-dnat-guard-fixture compose-config adguard-config-check gatus-config-check mover-test archive-snapshot-test shellcheck secrets-scan preflight
.PHONY: state-backup-preflight state-backup-preflight-test state-backup state-backup-push state-restore state-restore-test state-backup-test rollback-app
.PHONY: secrets-encrypt secrets-decrypt-check secrets-encrypt-agent secrets-decrypt-check-agent
.PHONY: tailscale-acl-encrypt tailscale-acl-decrypt tailscale-init tailscale-acl-preflight tailscale-plan tailscale-apply tailscale-import-core tailscale-import-acl tailscale-import-dns tailscale-import-router tailscale-acl-path-test tailscale-import-gates-test

toolbox-build:
	docker build --tag $(TOOLBOX_BUILD_IMAGE) files/tools/homelab-toolbox

# 再生成には固定toolboxを使い、toolboxディレクトリだけをmountする。鍵・認証情報は渡さない。
toolbox-requirements:
	docker run --rm --platform linux/amd64 --user $(TOOLBOX_USER) \
		-e HOME=/tmp -v "$(CURDIR)/files/tools/homelab-toolbox:/src" \
		--entrypoint python3 $(TOOLBOX_IMAGE) /src/regenerate-requirements.py

terraform-init:
	$(TOOLBOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) init -input=false

terraform-fmt:
	$(TOOLBOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(ELASTIFLOW_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_GATEWAY_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(STASHPAD_DEV_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(AGENT_VM_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(RUNNER_VM_ROOT) fmt -check -recursive

terraform-validate: terraform-init
	$(TOOLBOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) validate

terraform-validate-tailscale:
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) validate

# Agent/Runner VM roots are separate from the Apps VM root so their state never
# mixes. `-backend=false` keeps this read-only (CI-safe): no remote state access.
terraform-validate-agent-vm:
	$(TOOLBOX_RUN) terraform -chdir=$(AGENT_VM_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(AGENT_VM_ROOT) validate

terraform-validate-runner-vm:
	$(TOOLBOX_RUN) terraform -chdir=$(RUNNER_VM_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(RUNNER_VM_ROOT) validate

terraform-validate-elastiflow:
	$(TOOLBOX_RUN) terraform -chdir=$(ELASTIFLOW_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(ELASTIFLOW_ROOT) validate

terraform-validate-tailscale-gateway:
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_GATEWAY_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_GATEWAY_ROOT) validate

terraform-validate-stashpad-dev:
	$(TOOLBOX_RUN) terraform -chdir=$(STASHPAD_DEV_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(STASHPAD_DEV_ROOT) validate

# Tailscale changes are deliberately explicit/manual. Import existing objects
# before planning; apply also records encrypted Terraform state using the
# default state-backup push policy.
tailscale-init:
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) init -backend=false -input=false

tailscale-acl-preflight:
	test "$(MANAGE_TAILNET)" != true || test -n "$(ACL_POLICY_FILE)" || { echo "MANAGE_TAILNET=true requires ACL_POLICY_FILE" >&2; exit 1; }
	if test -n "$(ACL_POLICY_FILE)"; then TAILSCALE_REPO_ROOT="$(CURDIR)" ./scripts/validate-tailscale-acl-path.sh "$(ACL_POLICY_FILE)" >/dev/null; fi

tailscale-plan: tailscale-init
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET="$(MANAGE_TAILNET)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) plan -input=false -out=$(TAILSCALE_PLAN_NAME) $(TAILSCALE_VAR_ARGS)
	chmod 0600 "$(TAILSCALE_PLAN_FILE)"

tailscale-apply: tailscale-init
	./scripts/check-saved-terraform-plan.sh "$(TAILSCALE_PLAN_FILE)"
	$(MAKE) state-backup-preflight
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) apply -input=false "$(TAILSCALE_PLAN_NAME)"
	rm -f "$(TAILSCALE_PLAN_FILE)"
	$(MAKE) state-backup

# Import existing Tailscale resources only with explicit live-inventory gates.
# The quoted addresses are intentional: the [0] is part of Terraform's
# resource address, not a shell glob.
tailscale-import-core:
	$(MAKE) tailscale-import-acl MANAGE_TAILNET="$(MANAGE_TAILNET)" ENABLE_ADGUARD_DNS="$(ENABLE_ADGUARD_DNS)" ADGUARD_READY="$(ADGUARD_READY)" MANAGE_SUBNET_ROUTER="$(MANAGE_SUBNET_ROUTER)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-acl: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_RUN) sh ./scripts/check-tailscale-import-gates.sh "$(TAILSCALE_ROOT)" "$(MANAGE_TAILNET)" "$(ENABLE_ADGUARD_DNS)" "$(ADGUARD_READY)" "$(MANAGE_SUBNET_ROUTER)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_acl.policy[0]' acl
	$(MAKE) tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS="$(ENABLE_ADGUARD_DNS)" ADGUARD_READY="$(ADGUARD_READY)" MANAGE_SUBNET_ROUTER="$(MANAGE_SUBNET_ROUTER)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-dns: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	test "$(ENABLE_ADGUARD_DNS)" = true
	test "$(ADGUARD_READY)" = true
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_RUN) sh ./scripts/check-tailscale-import-gates.sh "$(TAILSCALE_ROOT)" "$(MANAGE_TAILNET)" "$(ENABLE_ADGUARD_DNS)" "$(ADGUARD_READY)" "$(MANAGE_SUBNET_ROUTER)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var='enable_adguard_dns=true' -var='adguard_ready=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_dns_configuration.adguard[0]' dns_configuration
	$(MAKE) tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true ADGUARD_READY=true MANAGE_SUBNET_ROUTER="$(MANAGE_SUBNET_ROUTER)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-router: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	test "$(MANAGE_SUBNET_ROUTER)" = true
	test -n "$(TAILSCALE_DEVICE_ID)"
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_RUN) sh ./scripts/check-tailscale-import-gates.sh "$(TAILSCALE_ROOT)" "$(MANAGE_TAILNET)" "$(ENABLE_ADGUARD_DNS)" "$(ADGUARD_READY)" "$(MANAGE_SUBNET_ROUTER)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var='manage_subnet_router=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_device_tags.subnet_router[0]' "$(TAILSCALE_DEVICE_ID)"
	$(MAKE) tailscale-plan MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true ENABLE_ADGUARD_DNS="$(ENABLE_ADGUARD_DNS)" ADGUARD_READY="$(ADGUARD_READY)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var='manage_subnet_router=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_device_subnet_routes.subnet_router[0]' "$(TAILSCALE_DEVICE_ID)"
	$(MAKE) tailscale-plan MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true ENABLE_ADGUARD_DNS="$(ENABLE_ADGUARD_DNS)" ADGUARD_READY="$(ADGUARD_READY)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

terraform-plan: terraform-validate
	$(TOOLBOX_PROXMOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) plan -input=false -out=$(TERRAFORM_PLAN_NAME) $(TERRAFORM_PLAN_ARGS)
	chmod 0600 "$(TERRAFORM_PLAN_FILE)"

terraform-apply: terraform-validate
	./scripts/check-saved-terraform-plan.sh "$(TERRAFORM_PLAN_FILE)"
	$(MAKE) state-backup-preflight
	$(TOOLBOX_PROXMOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) apply -input=false "$(TERRAFORM_PLAN_NAME)"
	rm -f "$(TERRAFORM_PLAN_FILE)"
	$(MAKE) state-backup

ansible-lint:
	$(TOOLBOX_RUN) ansible-lint $(ANSIBLE_ROOT)/site.yml

ansible-check:
	$(TOOLBOX_RUN) ansible-playbook -i $(ANSIBLE_INVENTORY) $(ANSIBLE_ROOT)/site.yml --syntax-check

ansible-apply:
	$(TOOLBOX_RUN) ansible-playbook -i $(ANSIBLE_INVENTORY) $(ANSIBLE_ROOT)/site.yml

# Hermes OS-level Ansible root. ANSIBLE_CONFIG is passed explicitly: the root's
# ansible.cfg sets roles_path so generic roles (e.g. docker) are reused from the
# Apps root, and ansible only auto-discovers ansible.cfg from the cwd. Applying
# this playbook touches live VMs, so it is never wired into CI.
ansible-lint-agent:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(AGENT_ANSIBLE_CONFIG) ansible-lint $(AGENT_ANSIBLE_ROOT)/site.yml

ansible-check-agent:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(AGENT_ANSIBLE_CONFIG) ansible-playbook -i $(AGENT_ANSIBLE_INVENTORY) $(AGENT_ANSIBLE_ROOT)/site.yml --syntax-check

ansible-apply-agent:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(AGENT_ANSIBLE_CONFIG) ansible-playbook -i $(AGENT_ANSIBLE_INVENTORY) $(AGENT_ANSIBLE_ROOT)/site.yml

# Gateway prefs root. Only lint and syntax-check run in CI; apply is manual.
ansible-lint-gateway:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(GATEWAY_ANSIBLE_CONFIG) ansible-lint $(GATEWAY_ANSIBLE_ROOT)/site.yml

ansible-check-gateway:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(GATEWAY_ANSIBLE_CONFIG) ansible-playbook -i $(GATEWAY_ANSIBLE_INVENTORY) $(GATEWAY_ANSIBLE_ROOT)/site.yml --syntax-check

# Live operation, manual only. GATEWAY_ANSIBLE_ARGS=--check previews prefs.
ansible-apply-gateway:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(GATEWAY_ANSIBLE_CONFIG) ansible-playbook -i $(GATEWAY_ANSIBLE_INVENTORY) $(GATEWAY_ANSIBLE_ROOT)/site.yml $(GATEWAY_ANSIBLE_ARGS)

# ElastiFlow root. Apply is a manual live operation; CI runs static checks only.
ansible-lint-elastiflow:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(ELASTIFLOW_ANSIBLE_CONFIG) ansible-lint $(ELASTIFLOW_ANSIBLE_ROOT)/site.yml

ansible-check-elastiflow:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(ELASTIFLOW_ANSIBLE_CONFIG) ansible-playbook -i $(ELASTIFLOW_ANSIBLE_INVENTORY) $(ELASTIFLOW_ANSIBLE_ROOT)/site.yml --syntax-check

ansible-apply-elastiflow:
	$(TOOLBOX_RUN) env ANSIBLE_CONFIG=$(ELASTIFLOW_ANSIBLE_CONFIG) ansible-playbook -i $(ELASTIFLOW_ANSIBLE_INVENTORY) $(ELASTIFLOW_ANSIBLE_ROOT)/site.yml $(ELASTIFLOW_ANSIBLE_ARGS)

gateway-routes-test:
	./scripts/tests/gateway-routes-fixture.sh

ansible-bootstrap-paths-test:
	./scripts/tests/ansible-bootstrap-paths-fixture.sh

terraform-apps-vm-lifecycle-test:
	./scripts/tests/terraform-apps-vm-lifecycle-fixture.sh

terraform-agent-runner-vm-lifecycle-test:
	./scripts/tests/terraform-agent-runner-vm-lifecycle-fixture.sh

toolbox-uid-test:
	$(TOOLBOX_RUN) ./scripts/tests/toolbox-uid-fixture.sh

cloud-init-test:
	./scripts/tests/cloud-init-apps-vm-fixture.sh

agent-vm-cloud-init-test:
	./scripts/tests/agent-vm-cloud-init-fixture.sh

runner-vm-cloud-init-test:
	./scripts/tests/runner-vm-cloud-init-fixture.sh

runner-privilege-fixture:
	./scripts/tests/runner-privilege-fixture.sh

runner-firewall-fixture:
	./scripts/tests/runner-firewall-fixture.sh

agent-runner-scope-fixture:
	./scripts/tests/agent-runner-scope-fixture.sh

agent-dnat-guard-fixture:
	./scripts/tests/agent-dnat-guard-fixture.sh

# WS5 Agent operations regression. These are static checks over the committed
# role/templates; they never touch the Agent VM.
.PHONY: agent-backup-fixture agent-healthcheck-fixture agent-restore-fixture agent-rebuild-fixture
agent-backup-fixture:
	./scripts/tests/agent-backup-fixture.sh

agent-healthcheck-fixture:
	./scripts/tests/agent-healthcheck-fixture.sh

agent-restore-fixture:
	./scripts/tests/agent-restore-fixture.sh

agent-rebuild-fixture:
	./scripts/tests/agent-rebuild-fixture.sh

compose-config:
	./scripts/compose-config.sh

adguard-config-check:
	$(TOOLBOX_RUN) env ADGUARD_BINARY=/usr/local/bin/adguardhome-check ./scripts/tests/adguard-config-fixture.sh

gatus-config-check:
	./scripts/tests/gatus-config-fixture.sh

compose-reconcile-fixture:
	./scripts/tests/compose-reconcile-fixture.sh

mover-test:
	./scripts/tests/mover-fixture.sh

archive-snapshot-test:
	./scripts/tests/archive-snapshot-fixture.sh

.PHONY: hf-downloader-test
hf-downloader-test:
	$(TOOLBOX_RUN) env PYTHONDONTWRITEBYTECODE=1 python3 scripts/tests/hf-downloader-test.py

shellcheck:
	$(TOOLBOX_RUN) shellcheck scripts/*.sh scripts/tests/*.sh files/infrastructure/storage/archive-snapshot.sh

secrets-scan:
	./scripts/validate-secrets.sh

preflight:
	./scripts/preflight-apps.sh

state-backup:
	$(TOOLBOX_RUN) ./scripts/state-backup.sh --no-push
	git push origin refs/heads/state-backup:refs/heads/state-backup

state-backup-push: state-backup

state-backup-preflight:
	$(TOOLBOX_RUN) ./scripts/state-backup-preflight.sh
	git push --dry-run origin HEAD:refs/heads/state-backup-preflight >/dev/null
	@echo "state-backup host SSH push dry-run: ready"

state-restore:
	$(TOOLBOX_RUN) ./scripts/state-restore.sh

state-backup-test:
	$(TOOLBOX_RUN) ./scripts/tests/state-backup-fixture.sh

state-restore-test:
	$(TOOLBOX_RUN) ./scripts/tests/state-restore-fixture.sh

state-backup-preflight-test:
	$(TOOLBOX_RUN) ./scripts/tests/state-backup-preflight-fixture.sh

tailscale-acl-path-test:
	./scripts/tests/tailscale-acl-path-fixture.sh

tailscale-import-gates-test:
	sh ./scripts/tests/tailscale-import-gates-fixture.sh

# ACL recovery copy: binary SOPS keeps policy keys inside the encrypted blob.
tailscale-acl-encrypt:
	test -n "$(AGE_RECIPIENT)" || { echo "AGE_RECIPIENT is required" >&2; exit 1; }
	TAILSCALE_REPO_ROOT="$(CURDIR)" ./scripts/validate-tailscale-acl-path.sh "$(ACL_POLICY_FILE)" >/dev/null
	mkdir -p "$$(dirname -- "$(TAILSCALE_ACL_BACKUP_FILE)")"
	TAILSCALE_REPO_ROOT="$(CURDIR)" ./scripts/validate-tailscale-acl-path.sh --allow-missing "$(TAILSCALE_ACL_BACKUP_FILE)" >/dev/null
	test ! -e "$(TAILSCALE_ACL_BACKUP_FILE)" && test ! -L "$(TAILSCALE_ACL_BACKUP_FILE)" || { echo "refusing to overwrite existing ACL backup" >&2; exit 1; }
	$(TOOLBOX_RUN) sh -eu -c '\
		umask 077; \
		tmp=$$(mktemp "$$(dirname -- "$$2")/.acl-encrypt.XXXXXX"); \
		trap '\''rm -f "$$tmp"'\'' EXIT HUP INT TERM; \
		sops encrypt --age "$$AGE_RECIPIENT" --input-type binary --output-type json "$$1" >"$$tmp"; \
		ln "$$tmp" "$$2"' sh "$(TAILSCALE_ACL_POLICY_CONTAINER)" "$(TAILSCALE_ACL_BACKUP_FILE)"

tailscale-acl-decrypt:
	test -n "$(AGE_IDENTITY_FILE)" && test -r "$(AGE_IDENTITY_FILE)" || { echo "AGE_IDENTITY_FILE must be readable" >&2; exit 1; }
	test -f "$(TAILSCALE_ACL_BACKUP_FILE)" && test ! -L "$(TAILSCALE_ACL_BACKUP_FILE)" || { echo "missing regular ACL backup" >&2; exit 1; }
	TAILSCALE_REPO_ROOT="$(CURDIR)" ./scripts/validate-tailscale-acl-path.sh --allow-missing "$(ACL_POLICY_FILE)" >/dev/null
	$(TOOLBOX_RUN) sh -eu -c '\
		umask 077; \
		tmp=$$(mktemp "$$(dirname -- "$$2")/.acl-decrypt.XXXXXX"); \
		trap '\''rm -f "$$tmp"'\'' EXIT HUP INT TERM; \
		sops decrypt --input-type json --output-type binary "$$1" >"$$tmp"; \
		if test -e "$$2"; then \
			{ test -f "$$2" && test ! -L "$$2"; } || { echo "ACL policy is not a regular file" >&2; exit 1; }; \
			if cmp -s "$$tmp" "$$2"; then echo "ACL: 一致"; else echo "ACL: 不一致" >&2; exit 1; fi; \
		else ln "$$tmp" "$$2"; echo "ACL: 復元しました"; fi' sh "$(TAILSCALE_ACL_BACKUP_FILE)" "$(TAILSCALE_ACL_POLICY_CONTAINER)"

secrets-encrypt:
	test -n "$(AGE_RECIPIENT)" || { echo "AGE_RECIPIENT is required" >&2; exit 1; }
	test -f files/infrastructure/secrets/runtime.yaml || { echo "missing ignored plaintext input: files/infrastructure/secrets/runtime.yaml" >&2; exit 1; }
	test ! -e files/infrastructure/secrets/runtime.sops.yaml || { echo "refusing to overwrite existing runtime.sops.yaml" >&2; exit 1; }
	$(TOOLBOX_RUN) sops encrypt --age "$(AGE_RECIPIENT)" --output files/infrastructure/secrets/runtime.sops.yaml files/infrastructure/secrets/runtime.yaml
	chmod 0600 files/infrastructure/secrets/runtime.sops.yaml

secrets-decrypt-check:
	test -n "$(AGE_IDENTITY_FILE)" && test -r "$(AGE_IDENTITY_FILE)" || { echo "AGE_IDENTITY_FILE must be readable" >&2; exit 1; }
	test -f files/infrastructure/secrets/runtime.sops.yaml || { echo "missing files/infrastructure/secrets/runtime.sops.yaml" >&2; exit 1; }
	$(TOOLBOX_RUN) env SOPS_AGE_KEY_FILE=/run/secrets/age-identity sops decrypt files/infrastructure/secrets/runtime.sops.yaml >/dev/null

# Hermes Agent bundle. The plaintext runtime.yaml is gitignored; only the SOPS
# bundle is committed. WS1 owns this protection path only; WS2 populates the
# bundle contents.
secrets-encrypt-agent:
	test -n "$(AGE_RECIPIENT)" || { echo "AGE_RECIPIENT is required" >&2; exit 1; }
	test -f files/infrastructure/secrets/agent/runtime.yaml || { echo "missing ignored plaintext input: files/infrastructure/secrets/agent/runtime.yaml" >&2; exit 1; }
	test ! -e files/infrastructure/secrets/agent/runtime.sops.yaml || { echo "refusing to overwrite existing agent/runtime.sops.yaml" >&2; exit 1; }
	$(TOOLBOX_RUN) sops encrypt --age "$(AGE_RECIPIENT)" --output files/infrastructure/secrets/agent/runtime.sops.yaml files/infrastructure/secrets/agent/runtime.yaml
	chmod 0600 files/infrastructure/secrets/agent/runtime.sops.yaml

secrets-decrypt-check-agent:
	test -n "$(AGE_IDENTITY_FILE)" && test -r "$(AGE_IDENTITY_FILE)" || { echo "AGE_IDENTITY_FILE must be readable" >&2; exit 1; }
	test -f files/infrastructure/secrets/agent/runtime.sops.yaml || { echo "missing files/infrastructure/secrets/agent/runtime.sops.yaml" >&2; exit 1; }
	$(TOOLBOX_RUN) env SOPS_AGE_KEY_FILE=/run/secrets/age-identity sops decrypt files/infrastructure/secrets/agent/runtime.sops.yaml >/dev/null

rollback-app:
	./scripts/rollback-app.sh

# Agent VM Compose project static validation. The project lives outside
# files/services/compose/ on purpose, so scripts/compose-config.sh (and the Apps
# reconcile path) never pick it up; this target reuses the same rollback-safe
# rendering check the CI static job runs.
.PHONY: agent-compose-config
agent-compose-config:
	./scripts/agent-compose-config.sh
