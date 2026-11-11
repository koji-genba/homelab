#!/bin/sh
# Manage main protection only; App repository access is configured manually.
# Operator login only; never run this from Hermes/Runner.
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/github-agent-repo.py" onboard "$@"
