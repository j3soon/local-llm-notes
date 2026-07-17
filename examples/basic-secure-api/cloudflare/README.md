# Cloudflare Tunnel Deployment

This directory contains the recommended deployment using Cloudflare Tunnel for secure, HTTPS-only public access without opening any ports on your firewall.

## Cloudflare Tunnel Setup

1. Create a [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/setup/).
2. Add a public hostname for your desired domain (e.g., `llm.example.com`).
3. Point the tunnel service to `http://nginx:80` (the `nginx` Compose service, reachable from the `cloudflared` container over the Compose network, not `localhost`, since they run in separate containers).
4. Copy `.env.example` to `.env` and set `CLOUDFLARE_TUNNEL_TOKEN`.
5. Enable [Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/) in Cloudflare dashboard.

## Setup

```sh
cd cloudflare
./scripts/gen_env.sh .env
cat .env
docker compose up -d
```

Or manually:

```sh
cd cloudflare
cp .env.example .env
# Edit .env to set SERVER_NAME, LLM_API_KEY, and CLOUDFLARE_TUNNEL_TOKEN
docker compose up -d
```

## Requirements

- `LLAMA_CPP_IMAGE` in `.env` must match your system.
- Use `j3soon/llama.cpp:server-cuda-spark` on DGX Spark.
- Use `ghcr.io/ggml-org/llama.cpp:server-cuda` on x86 CUDA hosts such as RTX PRO 6000.
- `CLOUDFLARE_TUNNEL_TOKEN` must be set in `.env`.
- Port `38000` is exposed locally for the llama.cpp web UI.

## Test

```sh
source .env
curl https://$SERVER_NAME/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

Local llama.cpp UI from the Docker host (bypasses `nginx`, so no API key needed):

```sh
curl http://127.0.0.1:38000/
```

## Local-Only Deployment

For a local-only deployment with no published ports:

```sh
docker compose -f compose.local.yaml up -d
```

## Optional OpenCode Setup

The setup scripts require `jq`. They preserve existing OpenCode settings and providers, replace only their respective provider block, and make their model the default.

### Local Model with Internet Access

Run `../scripts/setup_opencode.sh` to add or update the `llamacpp-remote` provider so OpenCode can talk to the local `llama.cpp` endpoint.

### Local Model with No Internet Access

For the local/offline Compose stack, run `../scripts/setup_opencode_local.sh` from the OpenCode container or environment that uses `local-llm-internal`. It adds or updates the `llamacpp-local` provider to reach `llama.cpp` at `http://llama-cpp:37000/v1` without an API key.

### NVIDIA Nemotron 3

To add NVIDIA-hosted Nemotron 3 Ultra and Super:

```sh
../scripts/setup_opencode_nvidia_nemotron_3.sh
opencode
```

The script prompts for an NVIDIA API key, then adds or updates the `nvidia` provider using NVIDIA's OpenAI-compatible inference endpoint. Nemotron 3 Ultra is selected as the default model.

References: [NVIDIA Nemotron 3 Ultra API](https://build.nvidia.com/nvidia/nemotron-3-ultra-550b-a55b), [NVIDIA Nemotron 3 Super API](https://build.nvidia.com/nvidia/nemotron-3-super-120b-a12b), [OpenCode custom providers](https://opencode.ai/docs/providers/#custom-provider), and [opencode-nemotron-free](https://github.com/j3soon/opencode-nemotron-free).

## Security Scan

Use `../scripts/basic_security_scan.sh` to verify the exposed surface and auth behavior. Unlike the certbot call, no port is passed, since Cloudflare Tunnel serves on the standard HTTPS port. The TLS and certificate checks then target Cloudflare's edge instead of our own origin, which verifies your Cloudflare-side TLS configuration (the "Always Use HTTPS" setting and Universal SSL certificate) rather than anything in this repo.

```sh
SERVER_NAME='<value from .env>'
LLM_API_KEY='<value from .env>'
../scripts/basic_security_scan.sh "$SERVER_NAME" "$LLM_API_KEY"
```

`llama-cpp` stays private on the Compose network, except for a localhost-only UI binding on `127.0.0.1:38000`. Cloudflare Tunnel, forwarding into `nginx`, is the only remotely reachable entrypoint.

Remote clients can access only `/v1/chat/completions`, gated by `Authorization: Bearer $LLM_API_KEY` (checked by `nginx`, same as the certbot setup); plain HTTP is redirected to HTTPS by Cloudflare's "Always Use HTTPS" setting. Full, unauthenticated access remains available from localhost via `127.0.0.1:38000` (directly to `llama-cpp`, bypassing `nginx`). Remove the `127.0.0.1:38000:37000` mapping in [`compose.yaml`](./compose.yaml) to disable it.
