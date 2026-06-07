#!/bin/bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BACKUP_FILE="${CONFIG_DIR}/opencode.json.bak"
PROVIDER_ID="llamacpp-local"
MODEL_NAME="Nemotron 3 Super"

echo "=== OpenCode llama.cpp Local/Offline Configuration ==="
echo

mkdir -p "${CONFIG_DIR}"

command -v jq >/dev/null 2>&1 || {
    echo "jq is required to update the OpenCode configuration." >&2
    exit 1
}

if [ -f "${CONFIG_FILE}" ]; then
    cp "${CONFIG_FILE}" "${BACKUP_FILE}"
    echo "Backed up existing config to ${BACKUP_FILE}"
fi

TEMP_FILE=$(mktemp "${CONFIG_DIR}/opencode.json.tmp.XXXXXX")
trap 'rm -f "${TEMP_FILE}"' EXIT

SETUP_CONFIG_JSON=$(cat <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llamacpp-local/Nemotron 3 Super",
  "provider": {
    "llamacpp-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (offline)",
      "options": {
        "baseURL": "http://local-llm-llama-cpp:37000/v1",
        "headers": {
          "Content-Type": "application/json"
        }
      },
      "models": {
        "Nemotron 3 Super": {
          "name": "Nemotron 3 Super"
        }
      }
    }
  }
}
EOF
)

JQ_ARGS=(
    --arg provider_id "${PROVIDER_ID}"
    --argjson setup "${SETUP_CONFIG_JSON}"
)
JQ_FILTER='
  .["$schema"] //= $setup["$schema"]
  | .model = $setup.model
  | .provider //= {}
  | .provider[$provider_id] = $setup.provider[$provider_id]
'

if [ -f "${CONFIG_FILE}" ]; then
    jq "${JQ_ARGS[@]}" "${JQ_FILTER}" "${CONFIG_FILE}" > "${TEMP_FILE}"
else
    jq -n "${JQ_ARGS[@]}" "${JQ_FILTER}" > "${TEMP_FILE}"
fi
mv "${TEMP_FILE}" "${CONFIG_FILE}"
trap - EXIT

echo
echo "Configuration written to ${CONFIG_FILE}"
echo
echo "Run OpenCode from a container attached to local-llm-internal."
