#!/bin/sh
set -eu

# Run in the same toolbox/root as import, without provider credentials.
# This root uses the default local backend and default workspace only.
root=$1
manage_tailnet=$2
enable_adguard_dns=$3
adguard_ready=$4
manage_subnet_router=$5
if test -e "$root/terraform.tfstate.d" || test -L "$root/terraform.tfstate.d"; then
  echo "Unexpected workspace state directory; only the default workspace is supported; import aborted" >&2
  exit 1
fi
# Check existence only. Never infer an empty state from a Terraform error.
if test ! -e "$root/terraform.tfstate" && test ! -L "$root/terraform.tfstate"; then
  exit 0
fi
addresses=$(terraform -chdir="$root" state list -no-color) || {
  echo "Cannot list Tailscale state; import aborted" >&2
  exit 1
}

printf '%s\n' "$addresses" | while IFS= read -r address; do
  case "$address" in
    'tailscale_acl.policy[0]')
      test "$manage_tailnet" = true || {
        echo "Existing ACL state requires MANAGE_TAILNET=true; import aborted" >&2
        exit 1
      }
      ;;
    'tailscale_dns_configuration.adguard[0]')
      if ! { test "$manage_tailnet" = true && test "$enable_adguard_dns" = true && test "$adguard_ready" = true; }; then
        echo "Existing DNS state requires MANAGE_TAILNET=true ENABLE_ADGUARD_DNS=true ADGUARD_READY=true after readiness checks; import aborted" >&2
        exit 1
      fi
      ;;
    'tailscale_device_tags.subnet_router[0]'|'tailscale_device_subnet_routes.subnet_router[0]')
      if ! { test "$manage_tailnet" = true && test "$manage_subnet_router" = true; }; then
        echo "Existing router state requires MANAGE_TAILNET=true MANAGE_SUBNET_ROUTER=true after inventory review; import aborted" >&2
        exit 1
      fi
      ;;
  esac
done
