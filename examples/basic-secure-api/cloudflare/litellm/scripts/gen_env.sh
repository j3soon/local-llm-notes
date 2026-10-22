#!/bin/sh
set -eu
umask 077

out_file="${1:-.env}"

if [ -L "$out_file" ] || { [ -e "$out_file" ] && [ ! -f "$out_file" ]; }; then
    echo "$out_file must be a regular file" >&2
    exit 1
fi

# Read the selected file, not provider credentials inherited from the shell.
unset SERVER_NAME CLOUDFLARE_TUNNEL_TOKEN OPENAI_API_KEY AZURE_API_KEY \
    AZURE_API_BASE AZURE_API_VERSION VLLM_API_BASE VLLM_API_KEY \
    LITELLM_MASTER_KEY LITELLM_SALT_KEY APP_API_KEY POSTGRES_PASSWORD \
    LITELLM_LOG LITELLM_BIND LITELLM_PORT
if [ -f "$out_file" ]; then
    case "$out_file" in
        /*) . "$out_file" ;;
        *) . "./$out_file" ;;
    esac
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

server_name="${SERVER_NAME:-$(prompt SERVER_NAME proxy.example.com)}"
cloudflare_tunnel_token="${CLOUDFLARE_TUNNEL_TOKEN:-$(prompt_required CLOUDFLARE_TUNNEL_TOKEN)}"
# An explicitly empty optional key is a saved choice, not a missing setting.
openai_api_key="${OPENAI_API_KEY-$(prompt 'OPENAI_API_KEY (optional; direct OpenAI is disabled in YAML)' '')}"
azure_api_key="${AZURE_API_KEY-$(prompt 'AZURE_API_KEY (Azure models enabled in YAML; comment them out if empty)' '')}"
azure_api_base="${AZURE_API_BASE-}"
if [ -n "$azure_api_key" ]; then
    azure_api_base="${AZURE_API_BASE:-$(prompt AZURE_API_BASE https://your-resource.openai.azure.com)}"
fi
vllm_api_base="${VLLM_API_BASE:-$(prompt VLLM_API_BASE https://llm.example.com/v1)}"
vllm_api_key="${VLLM_API_KEY-$(prompt 'VLLM_API_KEY (optional; comment out Qwen in YAML if empty)' '')}"

master_key="${LITELLM_MASTER_KEY:-sk-$(openssl rand -hex 32)}"
salt_key="${LITELLM_SALT_KEY:-sk-$(openssl rand -hex 32)}"
app_api_key="${APP_API_KEY:-sk-$(openssl rand -hex 32)}"
postgres_password="${POSTGRES_PASSWORD:-$(openssl rand -hex 32)}"

if [ -e "$out_file" ]; then
    printf 'Back up and overwrite %s using template settings? [y/N]: ' "$out_file" >&2
    IFS= read -r answer || answer=''
    case "$answer" in
        y|Y|yes|YES) ;;
        *) echo "Left $out_file unchanged"; exit 0 ;;
    esac
fi

# Write beside the destination and replace it only after the file is complete.
tmp_file="$(mktemp "${out_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp_file"' 0
trap 'exit 1' HUP INT TERM
cat > "$tmp_file" <<EOF
# Point this tunnel's public hostname to http://nginx:80 (API only).
SERVER_NAME=$server_name
CLOUDFLARE_TUNNEL_TOKEN=$cloudflare_tunnel_token

# Keep these secrets with the database; do not regenerate the salt on restart.
LITELLM_MASTER_KEY=$master_key
LITELLM_SALT_KEY=$salt_key
# Register this client key with ./scripts/create_virtual_key.sh.
APP_API_KEY=$app_api_key
POSTGRES_PASSWORD=$postgres_password
LITELLM_LOG=${LITELLM_LOG-INFO}

# No local access: remove/comment litellm's ports section in compose.yaml.
# LITELLM_BIND chooses the address; an empty value does not disable the mapping.
LITELLM_BIND=${LITELLM_BIND-127.0.0.1:}
LITELLM_PORT=${LITELLM_PORT-14000}

# For empty provider keys, comment out their model blocks and permissions in YAML.
OPENAI_API_KEY=$openai_api_key
AZURE_API_KEY=$azure_api_key
AZURE_API_BASE=$azure_api_base
# LiteLLM selects Azure's current /openai/v1/ API without a dated api-version.
AZURE_API_VERSION=${AZURE_API_VERSION:-v1}
VLLM_API_BASE=$vllm_api_base
VLLM_API_KEY=$vllm_api_key
EOF

if [ -f "$out_file" ]; then
    backup_file="$(mktemp "${out_file}_$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.bak")"
    cp -- "$out_file" "$backup_file"
    chmod 600 "$backup_file"
    echo "Backed up $out_file to $backup_file"
fi
mv -f -- "$tmp_file" "$out_file"

echo "Wrote $out_file (mode 600)"
echo "Set the proxy Cloudflare Tunnel origin to http://nginx:80."
echo "Edit litellm-config.yaml to select models and comment out those with empty API keys."
