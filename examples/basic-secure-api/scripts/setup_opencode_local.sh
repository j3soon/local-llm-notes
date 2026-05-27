#!/bin/bash

set -e

CONFIG_DIR="${HOME}/.config/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
BACKUP_FILE="${CONFIG_DIR}/opencode.json.bak"

echo "=== OpenCode llama.cpp Local/Offline Configuration ==="
echo

mkdir -p "${CONFIG_DIR}"

if [ -f "${CONFIG_FILE}" ]; then
    cp "${CONFIG_FILE}" "${BACKUP_FILE}"
    echo "Backed up existing config to ${BACKUP_FILE}"
fi

cat > "${CONFIG_FILE}" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "llamacpp/Nemotron 3 Super",
  "provider": {
    "llamacpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
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

echo
echo "Configuration written to ${CONFIG_FILE}"
echo
echo "Run OpenCode from a container attached to local-llm-internal."
