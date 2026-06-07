#!/bin/bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BACKUP_FILE="${CONFIG_DIR}/opencode.json.bak"

echo "=== OpenCode NVIDIA Nemotron 3 Ultra Configuration ==="
echo

echo "Get an API key from:"
echo "https://build.nvidia.com/settings/api-keys"
echo
read -r -s -p "NVIDIA API key: " NVIDIA_API_KEY
echo
if [ -z "${NVIDIA_API_KEY}" ]; then
    echo "NVIDIA API key cannot be empty." >&2
    exit 1
fi

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
  "model": "nvidia/nvidia/nemotron-3-ultra-550b-a55b",
  "provider": {
    "nvidia": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "NVIDIA NIM",
      "options": {
        "baseURL": "https://integrate.api.nvidia.com/v1",
        "apiKey": "NVIDIA_API_KEY"
      },
      "models": {
        "nvidia/nemotron-3-ultra-550b-a55b": {
          "name": "Nemotron 3 Ultra"
        }
      }
    }
  }
}
EOF
)

SETUP_CONFIG_JSON=$(jq \
    --arg api_key "${NVIDIA_API_KEY}" \
    '.provider.nvidia.options.apiKey = $api_key' \
    <<< "${SETUP_CONFIG_JSON}")

JQ_ARGS=(--argjson setup "${SETUP_CONFIG_JSON}")
JQ_FILTER='
  .["$schema"] //= $setup["$schema"]
  | .model = $setup.model
  | .provider //= {}
  | .provider.nvidia = $setup.provider.nvidia
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
echo "Run 'opencode' to use NVIDIA Nemotron 3 Ultra."
