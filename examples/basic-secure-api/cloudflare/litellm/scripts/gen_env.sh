#!/bin/sh
set -eu
umask 077

out_file="${1:-.env}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
template_file="$script_dir/../.env.example"

for dependency in openssl jq awk; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "$dependency is required" >&2
        exit 1
    }
done

if [ -L "$out_file" ] || { [ -e "$out_file" ] && [ ! -f "$out_file" ]; }; then
    echo "$out_file must be a regular file" >&2
    exit 1
fi

# Read the selected file, not provider credentials inherited from the shell.
unset SERVER_NAME CLOUDFLARE_TUNNEL_TOKEN OPENAI_API_KEY AZURE_API_KEY \
    AZURE_API_BASE AZURE_API_VERSION VLLM_API_BASE VLLM_API_KEY \
    VLLM_API_BASE_SECONDARY VLLM_API_KEY_SECONDARY \
    LITELLM_MASTER_KEY LITELLM_SALT_KEY APP_API_KEY APP_API_KEYS POSTGRES_PASSWORD \
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
vllm_api_base_secondary="${VLLM_API_BASE_SECONDARY:-$(prompt VLLM_API_BASE_SECONDARY https://llm-secondary.example.com/v1)}"
vllm_api_key_secondary="${VLLM_API_KEY_SECONDARY-$(prompt 'VLLM_API_KEY_SECONDARY (optional; comment out qwen-secondary in YAML if empty)' '')}"

master_key="${LITELLM_MASTER_KEY:-sk-$(openssl rand -hex 32)}"
salt_key="${LITELLM_SALT_KEY:-sk-$(openssl rand -hex 32)}"
# Preserve an existing list, including additional native request fields.
# Retain an existing single application token when generating the initial list.
app_api_keys="${APP_API_KEYS:-$(jq -nc \
    --arg full "sk-$(openssl rand -hex 32)" \
    --arg qwen "${APP_API_KEY:-sk-$(openssl rand -hex 32)}" \
    '[{key_alias:"full-access",key:$full,models:["all-proxy-models"]},{key_alias:"qwen-only",key:$qwen}]')}"
if ! printf '%s' "$app_api_keys" | jq empty; then
    echo "APP_API_KEYS contains invalid JSON in $out_file. Check for trailing commas before ] or }." >&2
    echo "Left $out_file unchanged" >&2
    exit 1
fi
printf '%s' "$app_api_keys" | jq -se 'length == 1 and (.[0] | type == "array" and length > 0)' >/dev/null || {
    echo "APP_API_KEYS must be a single nonempty JSON array; left $out_file unchanged" >&2
    exit 1
}

while :; do
    printf 'Append a new client key? [y/N]: ' >&2
    IFS= read -r append_answer || append_answer=''
    case "$append_answer" in
        y|Y|yes|YES) ;;
        *) break ;;
    esac

    while :; do
        key_alias="$(prompt_required key_alias)"
        if ! jq -ne --arg alias "$key_alias" \
            '$alias | test("[^\\s]") and (explode | all(. >= 32))' >/dev/null; then
            echo "key_alias must contain text and no control characters" >&2
        elif printf '%s' "$app_api_keys" | jq -e --arg alias "$key_alias" \
            'any(.[]; .key_alias == $alias)' >/dev/null; then
            echo "key_alias already exists; choose a new alias" >&2
        else
            break
        fi
    done

    while :; do
        printf 'models JSON array (Enter for YAML default; all models: ["all-proxy-models"]): ' >&2
        if ! IFS= read -r key_models; then
            echo "No model selection received; left $out_file unchanged" >&2
            exit 1
        fi
        [ -n "$key_models" ] || break
        if printf '%s' "$key_models" | jq -e \
            'type == "array" and all(.[]; type == "string" and test("[^\\s]"))' >/dev/null 2>&1; then
            break
        fi
        echo "models must be a JSON array of nonempty model names" >&2
    done

    new_key="sk-$(openssl rand -hex 32)"
    app_api_keys="$(printf '%s' "$app_api_keys" | jq -c \
        --arg alias "$key_alias" --arg key "$new_key" --argjson models "${key_models:-null}" \
        '. + [{key_alias:$alias, key:$key} + (if $models == null then {} else {models:$models} end)]')"
    printf 'Added client key "%s" to the pending environment file.\n' "$key_alias" >&2
done

# One compact object per line; unicode escapes keep apostrophes compatible with
# the surrounding single quotes in both shell and Compose .env files.
app_api_keys_quoted="$(printf '%s' "$app_api_keys" | jq -er '
    "\u0027[\n" + (map("  " + (tojson | gsub("\u0027"; "\\u0027"))) | join(",\n")) + "\n]\u0027"
')"
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
# .env.example owns comments and layout. Pass values via ENVIRON so awk does
# not interpret backslashes in credentials or the shell-quoted JSON key list.
GEN_ENV_SERVER_NAME="$server_name" \
GEN_ENV_CLOUDFLARE_TUNNEL_TOKEN="$cloudflare_tunnel_token" \
GEN_ENV_LITELLM_MASTER_KEY="$master_key" \
GEN_ENV_LITELLM_SALT_KEY="$salt_key" \
GEN_ENV_APP_API_KEYS="$app_api_keys_quoted" \
GEN_ENV_POSTGRES_PASSWORD="$postgres_password" \
GEN_ENV_LITELLM_LOG="${LITELLM_LOG-INFO}" \
GEN_ENV_LITELLM_BIND="${LITELLM_BIND-127.0.0.1:}" \
GEN_ENV_LITELLM_PORT="${LITELLM_PORT-14000}" \
GEN_ENV_OPENAI_API_KEY="$openai_api_key" \
GEN_ENV_AZURE_API_KEY="$azure_api_key" \
GEN_ENV_AZURE_API_BASE="$azure_api_base" \
GEN_ENV_AZURE_API_VERSION="${AZURE_API_VERSION:-v1}" \
GEN_ENV_VLLM_API_BASE="$vllm_api_base" \
GEN_ENV_VLLM_API_KEY="$vllm_api_key" \
GEN_ENV_VLLM_API_BASE_SECONDARY="$vllm_api_base_secondary" \
GEN_ENV_VLLM_API_KEY_SECONDARY="$vllm_api_key_secondary" \
awk '
    /^[A-Z_][A-Z0-9_]*=/ {
        name = substr($0, 1, index($0, "=") - 1)
        setting = "GEN_ENV_" name
        if (!(setting in ENVIRON)) {
            print "No generated value for template setting " name > "/dev/stderr"
            exit 1
        }
        print name "=" ENVIRON[setting]
        # Replace the whole multiline JSON assignment, including its closing quote.
        if (name == "APP_API_KEYS" && $0 !~ /\047$/) {
            while (getline > 0) {
                if ($0 ~ /\047$/) break
            }
        }
        next
    }
    { print }
' "$template_file" > "$tmp_file"

if [ -f "$out_file" ]; then
    backup_file="$(mktemp "${out_file}_$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.bak")"
    cp -- "$out_file" "$backup_file"
    chmod 600 "$backup_file"
    echo "Backed up $out_file to $backup_file"
fi
mv -f -- "$tmp_file" "$out_file"

echo "Wrote $out_file (mode 600)"
echo "Register client keys with ./scripts/create_virtual_key.sh $out_file"
echo "Set the proxy Cloudflare Tunnel origin to http://nginx:80."
echo "Edit litellm-config.yaml to select models and comment out those with empty API keys."
