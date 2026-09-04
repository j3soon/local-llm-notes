#!/bin/bash

set -euo pipefail

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
MODELS_FILE="${CONFIG_DIR}/models.json"
SETTINGS_FILE="${CONFIG_DIR}/settings.json"
DEFAULT_PROVIDER_ID="llm-local"
MODEL_NAME="unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL"
DISPLAY_NAME="Qwen3.8 27B MTP UD-Q4_K_XL"
SERVER_URL="http://llama-cpp:37000/v1"
DUMMY_API_KEY="not-required"
MODELS_TEMP_FILE=""
SETTINGS_TEMP_FILE=""

cleanup() {
    if [ -n "${MODELS_TEMP_FILE}" ]; then
        rm -f -- "${MODELS_TEMP_FILE}"
    fi
    if [ -n "${SETTINGS_TEMP_FILE}" ]; then
        rm -f -- "${SETTINGS_TEMP_FILE}"
    fi
}
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || {
    echo "jq is required to update the Pi configuration." >&2
    exit 1
}

if [ -f "${MODELS_FILE}" ] && ! jq -e '
    type == "object"
    and ((.providers == null) or (.providers | type == "object"))
' "${MODELS_FILE}" >/dev/null 2>&1; then
    echo "Existing Pi models configuration is not a valid JSON object: ${MODELS_FILE}" >&2
    exit 1
fi

if [ -f "${SETTINGS_FILE}" ] && ! jq -e 'type == "object"' "${SETTINGS_FILE}" >/dev/null 2>&1; then
    echo "Existing Pi settings are not a valid JSON object: ${SETTINGS_FILE}" >&2
    exit 1
fi

echo "=== Pi llama.cpp Local/Offline Configuration ==="
echo

read -r -p "Provider ID [${DEFAULT_PROVIDER_ID}]: " PROVIDER_ID
PROVIDER_ID="${PROVIDER_ID:-${DEFAULT_PROVIDER_ID}}"
if [[ -z "${PROVIDER_ID}" || "${PROVIDER_ID}" =~ [[:space:]/] ]]; then
    echo "Provider ID must be nonempty and contain no whitespace or '/'." >&2
    exit 1
fi

read -r -p "Enable image input for this model? [y/N]: " IMAGE_INPUT
IMAGE_INPUT="${IMAGE_INPUT:-n}"
if [[ "${IMAGE_INPUT}" =~ ^[Yy]$ ]]; then
    MODEL_INPUT_JSON='["text", "image"]'
    MODEL_INPUT_LABEL="text + image"
else
    MODEL_INPUT_JSON='["text"]'
    MODEL_INPUT_LABEL="text only"
fi

PROVIDER_ACTION="add"
if [ -f "${MODELS_FILE}" ] && jq -e --arg provider_id "${PROVIDER_ID}" '
    (.providers | type == "object") and (.providers | has($provider_id))
' "${MODELS_FILE}" >/dev/null; then
    PROVIDER_ACTION="replace"
fi

echo
echo "Summary:"
echo "  Provider ID: ${PROVIDER_ID} (${PROVIDER_ACTION})"
echo "  Server URL: ${SERVER_URL}"
echo "  API key: Pi placeholder (the local endpoint is unauthenticated)"
echo "  Model: ${MODEL_NAME}"
echo "  Display: ${DISPLAY_NAME}"
echo "  Model input: ${MODEL_INPUT_LABEL}"
echo "  Pi default provider/model: ${PROVIDER_ID}/${MODEL_NAME}"
echo

read -r -p "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

umask 077
mkdir -p "${CONFIG_DIR}"
MODELS_TEMP_FILE=$(mktemp "${CONFIG_DIR}/models.json.tmp.XXXXXX")
SETTINGS_TEMP_FILE=$(mktemp "${CONFIG_DIR}/settings.json.tmp.XXXXXX")

MODELS_JQ_ARGS=(
    --arg provider_id "${PROVIDER_ID}"
    --arg server_url "${SERVER_URL}"
    --arg api_key "${DUMMY_API_KEY}"
    --arg model_id "${MODEL_NAME}"
    --arg display_name "${DISPLAY_NAME}"
    --argjson model_input "${MODEL_INPUT_JSON}"
)
MODELS_JQ_FILTER='
  (. // {})
  | .providers //= {}
  | .providers[$provider_id] = {
      "name": "llama.cpp (offline)",
      "baseUrl": $server_url,
      "api": "openai-completions",
      "apiKey": $api_key,
      "models": [
        {
          "id": $model_id,
          "name": $display_name,
          "input": $model_input
        }
      ]
    }
'

if [ -f "${MODELS_FILE}" ]; then
    jq "${MODELS_JQ_ARGS[@]}" "${MODELS_JQ_FILTER}" "${MODELS_FILE}" > "${MODELS_TEMP_FILE}"
else
    jq -n "${MODELS_JQ_ARGS[@]}" "${MODELS_JQ_FILTER}" > "${MODELS_TEMP_FILE}"
fi

SETTINGS_JQ_ARGS=(
    --arg provider_id "${PROVIDER_ID}"
    --arg model_id "${MODEL_NAME}"
)
SETTINGS_JQ_FILTER='
  (. // {})
  | .defaultProvider = $provider_id
  | .defaultModel = $model_id
'

if [ -f "${SETTINGS_FILE}" ]; then
    jq "${SETTINGS_JQ_ARGS[@]}" "${SETTINGS_JQ_FILTER}" "${SETTINGS_FILE}" > "${SETTINGS_TEMP_FILE}"
else
    jq -n "${SETTINGS_JQ_ARGS[@]}" "${SETTINGS_JQ_FILTER}" > "${SETTINGS_TEMP_FILE}"
fi

if ! jq -e --arg provider_id "${PROVIDER_ID}" --arg model_id "${MODEL_NAME}" --argjson model_input "${MODEL_INPUT_JSON}" '
    type == "object"
    and (.providers | type == "object")
    and (.providers[$provider_id] | type == "object")
    and (.providers[$provider_id].baseUrl | type == "string" and length > 0)
    and (.providers[$provider_id].api == "openai-completions")
    and (.providers[$provider_id].apiKey | type == "string" and length > 0)
    and (.providers[$provider_id].models | type == "array")
    and any(.providers[$provider_id].models[]; .id == $model_id and (.input | type == "array") and ((.input | sort) == ($model_input | sort)))
' "${MODELS_TEMP_FILE}" >/dev/null; then
    echo "Generated Pi models configuration failed validation; no files were changed." >&2
    exit 1
fi

if ! jq -e --arg provider_id "${PROVIDER_ID}" --arg model_id "${MODEL_NAME}" '
    type == "object"
    and (.defaultProvider == $provider_id)
    and (.defaultModel == $model_id)
' "${SETTINGS_TEMP_FILE}" >/dev/null; then
    echo "Generated Pi settings failed validation; no files were changed." >&2
    exit 1
fi

MODELS_CHANGED=true
SETTINGS_CHANGED=true
if [ -f "${MODELS_FILE}" ] && cmp -s "${MODELS_TEMP_FILE}" "${MODELS_FILE}"; then
    MODELS_CHANGED=false
fi
if [ -f "${SETTINGS_FILE}" ] && cmp -s "${SETTINGS_TEMP_FILE}" "${SETTINGS_FILE}"; then
    SETTINGS_CHANGED=false
fi

if [ "${MODELS_CHANGED}" = false ] && [ "${SETTINGS_CHANGED}" = false ]; then
    echo
    echo "Pi configuration is already up to date; no files were changed."
    exit 0
fi

BACKUP_TIMESTAMP=$(date '+%Y%m%dT%H%M%S%N')
MODELS_BACKUP_FILE="${MODELS_FILE}.bak.${BACKUP_TIMESTAMP}"
SETTINGS_BACKUP_FILE="${SETTINGS_FILE}.bak.${BACKUP_TIMESTAMP}"

if [ "${MODELS_CHANGED}" = true ]; then
    if [ -f "${MODELS_FILE}" ]; then
        cp -- "${MODELS_FILE}" "${MODELS_BACKUP_FILE}"
        chmod 600 "${MODELS_BACKUP_FILE}"
        echo "Backed up existing models to ${MODELS_BACKUP_FILE}"
    fi
    mv -- "${MODELS_TEMP_FILE}" "${MODELS_FILE}"
    MODELS_TEMP_FILE=""
fi

if [ "${SETTINGS_CHANGED}" = true ]; then
    if [ -f "${SETTINGS_FILE}" ]; then
        cp -- "${SETTINGS_FILE}" "${SETTINGS_BACKUP_FILE}"
        chmod 600 "${SETTINGS_BACKUP_FILE}"
        echo "Backed up existing settings to ${SETTINGS_BACKUP_FILE}"
    fi
    mv -- "${SETTINGS_TEMP_FILE}" "${SETTINGS_FILE}"
    SETTINGS_TEMP_FILE=""
fi

echo
echo "Pi configuration written to ${CONFIG_DIR}"
echo
echo "Run Pi from a container attached to local-llm-internal."
