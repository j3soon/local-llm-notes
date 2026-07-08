#!/bin/bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BACKUP_FILE="${CONFIG_DIR}/opencode.json.bak"

echo "=== OpenCode llama.cpp Configuration ==="
echo

read -p "llama.cpp server URL (e.g., http://127.0.0.1:8080/v1): " SERVER_URL
read -p "API key (press Enter for no auth): " API_KEY
read -p "Model name (e.g., unsloth/Qwen3.5-122B-A10B-MTP-GGUF:UD-Q4_K_XL): " MODEL_NAME
read -p "Display name [${MODEL_NAME}]: " DISPLAY_NAME
DISPLAY_NAME="${DISPLAY_NAME:-${MODEL_NAME}}"

PROVIDER_ID="llamacpp-remote"

echo
echo "Summary:"
echo "  Provider ID: ${PROVIDER_ID}"
echo "  Server URL: ${SERVER_URL}"
echo "  Model: ${MODEL_NAME}"
echo "  Display: ${DISPLAY_NAME}"
echo

read -p "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
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
  "model": "llamacpp-remote/MODEL_NAME",
  "provider": {
    "llamacpp-remote": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (remote)",
      "options": {
        "baseURL": "SERVER_URL",
        "headers": {
          "Content-Type": "application/json"
        }
      },
      "models": {
        "MODEL_NAME": {
          "name": "DISPLAY_NAME"
        }
      }
    }
  }
}
EOF
)

SETUP_CONFIG_JSON=$(jq \
    --arg server_url "${SERVER_URL}" \
    --arg api_key "${API_KEY}" \
    --arg model_id "${MODEL_NAME}" \
    --arg display_name "${DISPLAY_NAME}" \
    '
      .model = ("llamacpp-remote/" + $model_id)
      | .provider["llamacpp-remote"].options.baseURL = $server_url
      | .provider["llamacpp-remote"].options.headers +=
          if $api_key == "" then {} else {"Authorization": ("Bearer " + $api_key)} end
      | .provider["llamacpp-remote"].models = {
          ($model_id): {
            "name": $display_name
          }
        }
    ' <<< "${SETUP_CONFIG_JSON}")

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
echo "Run 'opencode' and it will start on ${PROVIDER_ID}/${MODEL_NAME}."
