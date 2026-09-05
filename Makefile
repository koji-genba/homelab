SHELL := /bin/sh

TERRAFORM_ROOT ?= files/infrastructure/terraform/apps-vm
ANSIBLE_ROOT ?= files/infrastructure/ansible/apps
ANSIBLE_INVENTORY ?= $(ANSIBLE_ROOT)/inventory/hosts.yml
TAILSCALE_ROOT ?= files/infrastructure/terraform/tailscale
TERRAFORM_PLAN_NAME := terraform.tfplan
TAILSCALE_PLAN_NAME := terraform.tfplan
TERRAFORM_PLAN_FILE := $(TERRAFORM_ROOT)/$(TERRAFORM_PLAN_NAME)
TAILSCALE_PLAN_FILE := $(TAILSCALE_ROOT)/$(TAILSCALE_PLAN_NAME)
TAILSCALE_ACL_POLICY_REL := $(if $(ACL_POLICY_FILE),$(patsubst $(CURDIR)/%,%,$(abspath $(ACL_POLICY_FILE))),)
TAILSCALE_ACL_POLICY_CONTAINER := /workspace/$(TAILSCALE_ACL_POLICY_REL)
TAILSCALE_VAR_ARGS := $(if $(MANAGE_TAILNET),-var="manage_tailnet=$(MANAGE_TAILNET)",) \
	$(if $(MANAGE_SUBNET_ROUTER),-var="manage_subnet_router=$(MANAGE_SUBNET_ROUTER)",) \
	$(if $(ENABLE_ADGUARD_DNS),-var="enable_adguard_dns=$(ENABLE_ADGUARD_DNS)",) \
	$(if $(ADGUARD_READY),-var="adguard_ready=$(ADGUARD_READY)",) \
	$(if $(ACL_POLICY_FILE),-var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)",)
TOOLBOX_IMAGE ?= ghcr.io/koji-genba/homelab-toolbox:1.0.1
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

.PHONY: toolbox-build terraform-init terraform-fmt terraform-validate terraform-validate-tailscale terraform-plan terraform-apply
.PHONY: ansible-lint ansible-check ansible-apply ansible-bootstrap-paths-test terraform-apps-vm-lifecycle-test toolbox-uid-test cloud-init-test compose-config adguard-config-check shellcheck secrets-scan preflight
.PHONY: state-backup-preflight state-backup-preflight-test state-backup state-backup-push state-restore state-restore-test state-backup-test rollback-app
.PHONY: secrets-encrypt secrets-decrypt-check
.PHONY: tailscale-init tailscale-acl-preflight tailscale-plan tailscale-apply tailscale-import-core tailscale-import-acl tailscale-import-magic-dns tailscale-import-dns tailscale-import-router tailscale-acl-path-test

toolbox-build:
	docker build --tag $(TOOLBOX_IMAGE) files/tools/homelab-toolbox

terraform-init:
	$(TOOLBOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) init -input=false

terraform-fmt:
	$(TOOLBOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) fmt -check -recursive
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) fmt -check -recursive

terraform-validate: terraform-init
	$(TOOLBOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) validate

terraform-validate-tailscale:
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) init -backend=false -input=false
	$(TOOLBOX_RUN) terraform -chdir=$(TAILSCALE_ROOT) validate

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
	$(MAKE) tailscale-import-acl MANAGE_TAILNET="$(MANAGE_TAILNET)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(MAKE) tailscale-import-magic-dns MANAGE_TAILNET="$(MANAGE_TAILNET)" ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-acl: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_acl.policy[0]' acl
	$(MAKE) tailscale-plan MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-magic-dns: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_dns_preferences.magic_dns[0]' dns_preferences
	$(MAKE) tailscale-plan MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-dns: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	test "$(ENABLE_ADGUARD_DNS)" = true
	test "$(ADGUARD_READY)" = true
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var='enable_adguard_dns=true' -var='adguard_ready=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_dns_nameservers.adguard[0]' dns_nameservers
	$(MAKE) tailscale-plan MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true ADGUARD_READY=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

tailscale-import-router: tailscale-init
	test "$(MANAGE_TAILNET)" = true
	test "$(MANAGE_SUBNET_ROUTER)" = true
	test -n "$(TAILSCALE_DEVICE_ID)"
	$(MAKE) tailscale-acl-preflight MANAGE_TAILNET=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var='manage_subnet_router=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_device_tags.subnet_router[0]' "$(TAILSCALE_DEVICE_ID)"
	$(MAKE) tailscale-plan MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"
	$(TOOLBOX_TAILSCALE_RUN) terraform -chdir=$(TAILSCALE_ROOT) import -input=false -var='manage_tailnet=true' -var='manage_subnet_router=true' -var="acl_policy_file=$(TAILSCALE_ACL_POLICY_CONTAINER)" 'tailscale_device_subnet_routes.subnet_router[0]' "$(TAILSCALE_DEVICE_ID)"
	$(MAKE) tailscale-plan MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true ACL_POLICY_FILE="$(ACL_POLICY_FILE)"

terraform-plan: terraform-validate
	$(TOOLBOX_PROXMOX_RUN) terraform -chdir=$(TERRAFORM_ROOT) plan -input=false -out=$(TERRAFORM_PLAN_NAME)
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

ansible-bootstrap-paths-test:
	./scripts/tests/ansible-bootstrap-paths-fixture.sh

terraform-apps-vm-lifecycle-test:
	./scripts/tests/terraform-apps-vm-lifecycle-fixture.sh

toolbox-uid-test:
	$(TOOLBOX_RUN) ./scripts/tests/toolbox-uid-fixture.sh

cloud-init-test:
	./scripts/tests/cloud-init-apps-vm-fixture.sh

compose-config:
	./scripts/compose-config.sh

adguard-config-check:
	$(TOOLBOX_RUN) env ADGUARD_BINARY=/usr/local/bin/adguardhome-check ./scripts/tests/adguard-config-fixture.sh

shellcheck:
	$(TOOLBOX_RUN) shellcheck scripts/*.sh scripts/tests/*.sh

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

rollback-app:
	./scripts/rollback-app.sh
