#!/bin/bash

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
DEFAULT_PROVIDER_ID="llm-remote"
DEFAULT_PROVIDER_NAME="llama.cpp (remote)"
DEFAULT_MODEL_NAME="unsloth/Qwen3.8-27B-NVFP4"
TEMP_FILE=""

cleanup() {
    if [ -n "${TEMP_FILE}" ]; then
        rm -f -- "${TEMP_FILE}"
    fi
}
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || {
    echo "jq is required to update the OpenCode configuration." >&2
    exit 1
}

if [ -f "${CONFIG_FILE}" ] && ! jq -e '
    type == "object"
    and ((.provider == null) or (.provider | type == "object"))
' "${CONFIG_FILE}" >/dev/null 2>&1; then
    echo "Existing OpenCode configuration is not a valid JSON object: ${CONFIG_FILE}" >&2
    exit 1
fi

echo "=== OpenCode llama.cpp Remote Configuration ==="
echo

read -r -p "Provider ID [${DEFAULT_PROVIDER_ID}]: " PROVIDER_ID
PROVIDER_ID="${PROVIDER_ID:-${DEFAULT_PROVIDER_ID}}"
if [[ -z "${PROVIDER_ID}" || "${PROVIDER_ID}" =~ [[:space:]/] ]]; then
    echo "Provider ID must be nonempty and contain no whitespace or '/'." >&2
    exit 1
fi

read -r -p "llama.cpp server URL (e.g., https://llm.example.com/v1): " SERVER_URL
if [ -z "${SERVER_URL}" ]; then
    echo "Server URL must be nonempty." >&2
    exit 1
fi

read -r -s -p "API key (press Enter for no auth): " API_KEY
echo
read -r -p "Provider display name [${DEFAULT_PROVIDER_NAME}]: " PROVIDER_NAME
PROVIDER_NAME="${PROVIDER_NAME:-${DEFAULT_PROVIDER_NAME}}"
read -r -p "Model name [${DEFAULT_MODEL_NAME}]: " MODEL_NAME
MODEL_NAME="${MODEL_NAME:-${DEFAULT_MODEL_NAME}}"

read -r -p "Display name [${MODEL_NAME}]: " DISPLAY_NAME
DISPLAY_NAME="${DISPLAY_NAME:-${MODEL_NAME}}"

PROVIDER_ACTION="add"
if [ -f "${CONFIG_FILE}" ] && jq -e --arg provider_id "${PROVIDER_ID}" '
    (.provider | type == "object") and (.provider | has($provider_id))
' "${CONFIG_FILE}" >/dev/null; then
    PROVIDER_ACTION="replace"
fi

echo
echo "Summary:"
echo "  Provider ID: ${PROVIDER_ID} (${PROVIDER_ACTION})"
echo "  Provider name: ${PROVIDER_NAME}"
echo "  Server URL: ${SERVER_URL}"
if [ -n "${API_KEY}" ]; then
    echo "  API key: set (will be stored in ${CONFIG_FILE})"
else
    echo "  API key: not set"
fi
echo "  Model: ${MODEL_NAME}"
echo "  Display: ${DISPLAY_NAME}"
echo "  Default model: ${PROVIDER_ID}/${MODEL_NAME}"
echo

read -r -p "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

umask 077
mkdir -p "${CONFIG_DIR}"
TEMP_FILE=$(mktemp "${CONFIG_DIR}/opencode.json.tmp.XXXXXX")

JQ_ARGS=(
    --arg provider_id "${PROVIDER_ID}"
    --arg provider_name "${PROVIDER_NAME}"
    --arg server_url "${SERVER_URL}"
    --arg api_key "${API_KEY}"
    --arg model_id "${MODEL_NAME}"
    --arg display_name "${DISPLAY_NAME}"
)
JQ_FILTER='
  (. // {})
  | .["$schema"] //= "https://opencode.ai/config.json"
  | .model = ($provider_id + "/" + $model_id)
  | .provider //= {}
  | .provider[$provider_id] = {
       "npm": "@ai-sdk/openai-compatible",
       "name": $provider_name,
      "options": {
        "baseURL": $server_url,
        "headers": (
          {"Content-Type": "application/json"}
          + if $api_key == "" then {} else {"Authorization": ("Bearer " + $api_key)} end
        )
      },
      "models": {
        ($model_id): {
          "name": $display_name
        }
      }
    }
'

if [ -f "${CONFIG_FILE}" ]; then
    jq "${JQ_ARGS[@]}" "${JQ_FILTER}" "${CONFIG_FILE}" > "${TEMP_FILE}"
else
    jq -n "${JQ_ARGS[@]}" "${JQ_FILTER}" > "${TEMP_FILE}"
fi

if ! jq -e --arg provider_id "${PROVIDER_ID}" --arg model_ref "${PROVIDER_ID}/${MODEL_NAME}" '
    type == "object"
    and (.model == $model_ref)
    and (.provider | type == "object")
    and (.provider[$provider_id] | type == "object")
' "${TEMP_FILE}" >/dev/null; then
    echo "Generated OpenCode configuration failed validation; no files were changed." >&2
    exit 1
fi

if [ -f "${CONFIG_FILE}" ] && cmp -s "${TEMP_FILE}" "${CONFIG_FILE}"; then
    echo
    echo "Configuration is already up to date; no files were changed."
    exit 0
fi

if [ -f "${CONFIG_FILE}" ]; then
    BACKUP_FILE="${CONFIG_FILE}.bak.$(date '+%Y%m%dT%H%M%S%N')"
    cp -- "${CONFIG_FILE}" "${BACKUP_FILE}"
    chmod 600 "${BACKUP_FILE}"
    echo "Backed up existing config to ${BACKUP_FILE}"
fi

mv -- "${TEMP_FILE}" "${CONFIG_FILE}"
TEMP_FILE=""

echo
echo "Configuration written to ${CONFIG_FILE}"
echo
echo "Run 'opencode' and it will start on ${PROVIDER_ID}/${MODEL_NAME}."
