#!/bin/sh
set -eu

out_file="${1:-.env}"

if [ -e "$out_file" ]; then
    echo "$out_file already exists" >&2
    exit 1
fi

prompt() {
    prompt_text="$1"
    default_value="$2"

    printf "%s [%s]: " "$prompt_text" "$default_value" >&2
    IFS= read -r value
    if [ -z "$value" ]; then
        value="$default_value"
    fi

    printf '%s\n' "$value"
}

server_name="$(prompt "SERVER_NAME" "llm.example.com")"
letsencrypt_email="$(prompt "LETSENCRYPT_EMAIL" "admin@example.com")"
letsencrypt_staging="$(prompt "LETSENCRYPT_STAGING" "0")"

generated_api_key="sk-$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 48)"
api_key="$(prompt "LLM_API_KEY" "$generated_api_key")"

cat > "$out_file" <<EOF
SERVER_NAME=$server_name
LETSENCRYPT_EMAIL=$letsencrypt_email
LETSENCRYPT_STAGING=$letsencrypt_staging
LLM_API_KEY=$api_key
EOF

echo "Wrote $out_file"
