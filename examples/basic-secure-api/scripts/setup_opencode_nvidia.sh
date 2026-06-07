#!/bin/bash

set -euo pipefail

CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BACKUP_FILE="${CONFIG_DIR}/opencode.json.bak"

echo "=== OpenCode NVIDIA Nemotron 3 Ultra Configuration ==="
echo

if [ -z "${NVIDIA_API_KEY:-}" ]; then
    echo "NVIDIA_API_KEY must be set before running this script." >&2
    exit 1
fi

mkdir -p "${CONFIG_DIR}"

if [ -f "${CONFIG_FILE}" ]; then
    cp "${CONFIG_FILE}" "${BACKUP_FILE}"
    echo "Backed up existing config to ${BACKUP_FILE}"
fi

cat > "${CONFIG_FILE}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "nvidia/nvidia/nemotron-3-ultra-550b-a55b",
  "provider": {
    "nvidia": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "NVIDIA NIM",
      "options": {
        "baseURL": "https://integrate.api.nvidia.com/v1",
        "apiKey": "${NVIDIA_API_KEY}"
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

echo
echo "Configuration written to ${CONFIG_FILE}"
echo "Run 'opencode' to use NVIDIA Nemotron 3 Ultra."
