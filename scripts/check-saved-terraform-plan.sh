#!/bin/sh
set -eu

plan=${1:-}
test -n "$plan" || { echo "saved Terraform plan path is required" >&2; exit 2; }
test -f "$plan" || { echo "missing saved Terraform plan: $plan" >&2; exit 1; }
test ! -L "$plan" || { echo "saved Terraform plan must not be a symlink: $plan" >&2; exit 1; }
mode=$(stat -c '%a' "$plan")
test "$mode" = 600 || {
  echo "saved Terraform plan must be mode 0600: $plan (mode $mode)" >&2
  exit 1
}
