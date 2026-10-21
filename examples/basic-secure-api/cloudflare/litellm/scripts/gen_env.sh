#!/bin/sh
set -eu
umask 077

out_file="${1:-.env}"

if [ -e "$out_file" ] || [ -L "$out_file" ]; then
    echo "$out_file already exists" >&2
    exit 1
fi

prompt() {
    prompt_text="$1"
    default_value="$2"

    printf '%s [%s]: ' "$prompt_text" "$default_value" >&2
    IFS= read -r value
    printf '%s\n' "${value:-$default_value}"
}

prompt_required() {
    prompt_text="$1"

    while :; do
        printf '%s (required): ' "$prompt_text" >&2
        if ! IFS= read -r value; then
            echo "$prompt_text is required" >&2
            exit 1
        fi
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return
        fi
        echo "$prompt_text cannot be empty" >&2
    done
}

server_name="$(prompt SERVER_NAME proxy.example.com)"
cloudflare_tunnel_token="$(prompt_required CLOUDFLARE_TUNNEL_TOKEN)"
openai_api_key="$(prompt_required OPENAI_API_KEY)"
vllm_api_base="$(prompt VLLM_API_BASE https://llm.example.com/v1)"
vllm_api_key="$(prompt_required 'VLLM_API_KEY (existing vLLM LLM_API_KEY)')"

master_key="sk-$(openssl rand -hex 32)"
salt_key="sk-$(openssl rand -hex 32)"
postgres_password="$(openssl rand -hex 32)"

# Refuse overwrites even if another process creates the file during the prompts.
set -C
cat > "$out_file" <<EOF
# Point this tunnel's public hostname to http://nginx:80 (API only).
SERVER_NAME=$server_name
CLOUDFLARE_TUNNEL_TOKEN=$cloudflare_tunnel_token

# Keep these secrets with the database; do not regenerate the salt on restart.
LITELLM_MASTER_KEY=$master_key
LITELLM_SALT_KEY=$salt_key
POSTGRES_PASSWORD=$postgres_password
LITELLM_LOG=INFO

# No local access: remove/comment litellm's ports section in compose.yaml.
# LITELLM_BIND chooses the address; an empty value does not disable the mapping.
LITELLM_BIND=127.0.0.1:
LITELLM_PORT=14000

OPENAI_API_KEY=$openai_api_key
VLLM_API_BASE=$vllm_api_base
VLLM_API_KEY=$vllm_api_key
EOF

echo "Wrote $out_file (mode 600)"
echo "Set the proxy Cloudflare Tunnel origin to http://nginx:80."
