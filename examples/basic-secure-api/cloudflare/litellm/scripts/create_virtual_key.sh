#!/bin/sh
set -eu

# https://docs.litellm.ai/docs/proxy/virtual_keys
# Policies come from litellm_settings.default_key_generate_params in YAML.
# Load .env from the current directory by default; an optional path overrides it.
env_file="${1:-.env}"
case "$env_file" in
    /*) ;;
    *) env_file="./$env_file" ;;
esac

for dependency in curl jq; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "$dependency is required" >&2
        exit 1
    }
done

set -a
. "$env_file"
set +a

: "${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in the environment file}"
: "${APP_API_KEY:?Set APP_API_KEY in the environment file}"
if [ "$APP_API_KEY" = "$LITELLM_MASTER_KEY" ]; then
    echo "APP_API_KEY must differ from LITELLM_MASTER_KEY" >&2
    exit 1
fi

# Only the loopback management API is used; NGINX blocks this public route.
response="$(jq -n '{key: env.APP_API_KEY, key_alias: "app", key_type: "llm_api"}' |
    curl -fsS "http://127.0.0.1:${LITELLM_PORT:-14000}/key/generate" \
        -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H 'Content-Type: application/json' \
        --data-binary @-)"

# Confirm success without printing the secret returned by the API.
printf '%s\n' "$response" | jq -e '.key_alias == "app"' >/dev/null
echo "Registered APP_API_KEY as app; use this key for client API requests."
