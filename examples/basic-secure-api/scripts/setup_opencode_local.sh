#!/bin/bash

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
DEFAULT_PROVIDER_ID="llm-local"
MODEL_NAME="unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL"
DISPLAY_NAME="Qwen3.8 27B MTP UD-Q4_K_XL"
SERVER_URL="http://llama-cpp:37000/v1"
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

echo "=== OpenCode llama.cpp Local/Offline Configuration ==="
echo

read -r -p "Provider ID [${DEFAULT_PROVIDER_ID}]: " PROVIDER_ID
PROVIDER_ID="${PROVIDER_ID:-${DEFAULT_PROVIDER_ID}}"
if [[ -z "${PROVIDER_ID}" || "${PROVIDER_ID}" =~ [[:space:]/] ]]; then
    echo "Provider ID must be nonempty and contain no whitespace or '/'." >&2
    exit 1
fi

PROVIDER_ACTION="add"
if [ -f "${CONFIG_FILE}" ] && jq -e --arg provider_id "${PROVIDER_ID}" '
    (.provider | type == "object") and (.provider | has($provider_id))
' "${CONFIG_FILE}" >/dev/null; then
    PROVIDER_ACTION="replace"
fi

echo
echo "Summary:"
echo "  Provider ID: ${PROVIDER_ID} (${PROVIDER_ACTION})"
echo "  Server URL: ${SERVER_URL}"
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
    --arg server_url "${SERVER_URL}"
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
      "name": "llama.cpp (offline)",
      "options": {
        "baseURL": $server_url,
        "headers": {
          "Content-Type": "application/json"
        }
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
echo "Run OpenCode from a container attached to local-llm-internal."
