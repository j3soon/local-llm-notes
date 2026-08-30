# Basic Secure API

Run `llama.cpp` or vLLM with secure public access. Choose one of the following deployment methods:

## Options

### Cloudflare Tunnel (Recommended)

Secure HTTPS access without opening any ports. See [cloudflare/](cloudflare/).

```sh
cd cloudflare
./scripts/gen_env.sh .env
docker compose up -d
```

For Qwen3.8 NVFP4 with vLLM and MTP 2, use `docker compose -f compose.vllm.yaml up -d` instead.

### Certbot/NGINX (Legacy)

Direct deployment with Let's Encrypt certificates. See [certbot/](certbot/).

```sh
cd certbot
mkdir -p ../../../.cache state/letsencrypt state/www
./scripts/gen_env.sh
docker compose up -d
docker compose restart nginx  # After first certificate
```

## Common Requirements

- For llama.cpp, `LLAMA_CPP_IMAGE` in `.env` must match your system.
- Use `j3soon/llama.cpp:server-cuda-spark` on DGX Spark or `ghcr.io/ggml-org/llama.cpp:server-cuda` on x86 CUDA hosts.
- The vLLM NVFP4 option requires an NVIDIA Blackwell GPU.

The default Compose files run `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL`. The Cloudflare vLLM option runs `unsloth/Qwen3.8-27B-NVFP4`. Both enable MTP 2, following the [repo README](../../README.md#qwen38).

## Local-Only Deployment

For local llama.cpp deployments with no published ports, both directories include `compose.local.yaml`:

```sh
cd <certbot|cloudflare>
docker compose -f compose.local.yaml up -d
```

## Test

```sh
source .env
# Cloudflare (no port)
curl https://$SERVER_NAME/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}'

# Certbot (port 37000)
curl https://$SERVER_NAME:37000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{"messages": [{"role": "user", "content": "Hello"}]}'
```

Local llama.cpp UI:

```sh
curl http://127.0.0.1:38000/
```
