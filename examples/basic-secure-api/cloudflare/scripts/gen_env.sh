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

prompt_required() {
    prompt_text="$1"

    while :; do
        printf "%s (required): " "$prompt_text" >&2
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
cloudflare_tunnel_token="$(prompt_required "CLOUDFLARE_TUNNEL_TOKEN")"

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
CLOUDFLARE_TUNNEL_TOKEN=$cloudflare_tunnel_token
LLM_API_KEY=$api_key
LLAMA_CPP_IMAGE=$llama_cpp_image
EOF

echo "Wrote $out_file"
