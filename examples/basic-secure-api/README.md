# Basic Secure API

Run `llama.cpp` with secure public access. Choose one of the following deployment methods:

## Options

### Cloudflare Tunnel (Recommended)

Secure HTTPS access without opening any ports. See [cloudflare/](cloudflare/).

```sh
cd cloudflare
./scripts/gen_env.sh .env
docker compose up -d
```

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

- `LLAMA_CPP_IMAGE` in `.env` must match your system.
- Use `j3soon/llama.cpp:server-cuda-spark` on DGX Spark.
- Use `ghcr.io/ggml-org/llama.cpp:server-cuda` on x86 CUDA hosts such as RTX PRO 6000.

This example runs `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL` with MTP speculative decoding, following the [repo README](../../README.md#qwen38). The Q4 model requires 17GB-19GB total RAM and VRAM, plus about 2GB of additional memory for MTP.

## Local-Only Deployment

For local deployments with no published ports, both directories include `compose.local.yaml`:

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
