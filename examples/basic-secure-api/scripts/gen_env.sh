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

prompt_llama_cpp_image() {
    default_value="$1"

    cat >&2 <<EOF
Select LLAMA_CPP_IMAGE:
  1) Standard CUDA host: ghcr.io/ggml-org/llama.cpp:server-cuda
  2) DGX Spark: j3soon/llama.cpp:server-cuda-spark
Press Enter to keep the default, or type a custom image.
EOF
    printf "LLAMA_CPP_IMAGE [%s]: " "$default_value" >&2
    IFS= read -r value
    case "$value" in
        "")
            value="$default_value"
            ;;
        1)
            value="ghcr.io/ggml-org/llama.cpp:server-cuda"
            ;;
        2)
            value="j3soon/llama.cpp:server-cuda-spark"
            ;;
    esac

    printf '%s\n' "$value"
}

server_name="$(prompt "SERVER_NAME" "llm.example.com")"
letsencrypt_email="$(prompt "LETSENCRYPT_EMAIL" "admin@example.com")"
letsencrypt_staging="$(prompt "LETSENCRYPT_STAGING" "0")"

generated_api_key="sk-$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 48)"
api_key="$(prompt "LLM_API_KEY" "$generated_api_key")"

if uname -m | grep -qi 'aarch64\|arm64'; then
    default_llama_cpp_image="j3soon/llama.cpp:server-cuda-spark"
else
    default_llama_cpp_image="ghcr.io/ggml-org/llama.cpp:server-cuda"
fi
llama_cpp_image="$(prompt_llama_cpp_image "$default_llama_cpp_image")"

cat > "$out_file" <<EOF
SERVER_NAME=$server_name
LETSENCRYPT_EMAIL=$letsencrypt_email
LETSENCRYPT_STAGING=$letsencrypt_staging
LLM_API_KEY=$api_key
LLAMA_CPP_IMAGE=$llama_cpp_image
EOF

echo "Wrote $out_file"
