#!/bin/sh
# Read main protection only; does not check App repository access.
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/github-agent-repo.py" check "$@"
