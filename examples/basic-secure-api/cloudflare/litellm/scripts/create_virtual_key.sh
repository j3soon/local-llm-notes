#!/bin/sh
set -eu

# Source the same shell-compatible .env used by gen_env.sh, including JSON values.
env_file="${1:-.env}"
case "$env_file" in
    /*) ;;
    *) env_file="./$env_file" ;;
esac
set -a
. "$env_file"
set +a

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$script_dir/virtual_keys.py" register
