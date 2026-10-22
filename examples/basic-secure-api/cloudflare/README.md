# Cloudflare Tunnel Deployment

This directory contains the recommended deployment using Cloudflare Tunnel for secure, HTTPS-only public access without opening any ports on your firewall.

## Cloudflare Tunnel Setup

1. Create a [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/setup/).
2. Add a public hostname for your desired domain (e.g., `llm.example.com`).
3. Point the tunnel service to `http://nginx:80` (the `nginx` Compose service, reachable from the `cloudflared` container over the Compose network, not `localhost`, since they run in separate containers).
4. Copy `.env.example` to `.env` and set `CLOUDFLARE_TUNNEL_TOKEN`.
5. Enable [Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/) and set [Minimum TLS Version](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/minimum-tls-version/) to **TLS 1.2** in Cloudflare.

## Setup

```sh
cd cloudflare
./scripts/gen_env.sh .env
docker compose up -d
```

For Qwen3.8 NVFP4 with vLLM and MTP 2 (`LLAMA_CPP_IMAGE` is ignored):

```sh
docker compose -f compose.vllm.yaml up -d
```

The vLLM configuration explicitly enables [automatic prefix caching](https://docs.vllm.ai/en/latest/features/automatic_prefix_caching/) to reuse KV cache for shared prompt prefixes. It also enables [prompt token details](https://docs.vllm.ai/en/latest/cli/serve/#--enable-prompt-tokens-details), reporting cached tokens in API responses under `usage.prompt_tokens_details.cached_tokens`. For streaming requests, set `"stream_options": {"include_usage": true}` to receive usage. Standard Prometheus metrics, including prefix-cache queries and hits, and periodic statistics logging are enabled by default; keep `--disable-log-stats` unset.

Inspect metrics or statistics from the Docker host:

```sh
docker compose -f compose.vllm.yaml exec vllm curl -fsS http://localhost:8000/metrics
docker compose -f compose.vllm.yaml logs -f vllm
```

Prometheus on the same Compose network can scrape `http://vllm:8000/metrics`. The metrics endpoint stays private and is blocked by the public NGINX routes.

Or manually:

```sh
cd cloudflare
cp .env.example .env
# Edit .env to set SERVER_NAME, LLM_API_KEY, and CLOUDFLARE_TUNNEL_TOKEN
docker compose up -d
```

## Requirements

- For llama.cpp, `LLAMA_CPP_IMAGE` in `.env` must match your system.
- Use `j3soon/llama.cpp:server-cuda-spark` on DGX Spark or `ghcr.io/ggml-org/llama.cpp:server-cuda` on x86 CUDA hosts.
- `CLOUDFLARE_TUNNEL_TOKEN` must be set in `.env`.
- The llama.cpp stack exposes its web UI on host-local port `38000`; the vLLM stack publishes no host ports.

The default stack runs `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL`; `compose.vllm.yaml` runs `unsloth/Qwen3.8-27B-NVFP4`. Both enable MTP 2, following the [repo README](../../../README.md#qwen38). The vLLM stack enables tool calling, the full 262,144-token model context, and up to four simultaneous sequences. NVFP4 requires an NVIDIA Blackwell GPU. Run the internet-enabled llama.cpp stack first to download the GGUF model before starting `compose.local.yaml`.

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

For vLLM, also include `"model": "unsloth/Qwen3.8-27B-NVFP4"` in the request body.

vLLM supports authenticated streaming and non-streaming requests through the [Responses API](https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/#responses-api) at `POST /v1/responses`. Apply NGINX configuration changes without restarting the model:

```sh
docker compose -f compose.vllm.yaml restart nginx
```

Local llama.cpp UI from the Docker host (bypasses `nginx`, so no API key needed):

```sh
curl http://127.0.0.1:38000/
```

## Local-Only Deployment

For a local-only llama.cpp deployment with no published ports:

```sh
docker compose -f compose.local.yaml up -d
```

## Optional OpenCode and Pi Setup

The setup scripts require Bash and `jq`. They validate and atomically update existing configuration, preserve unrelated settings and providers, and make the configured model the default. Each script asks for a provider ID; accepting the default creates or updates `llm-remote` or `llm-local`, while a custom ID creates or updates only that exact entry.

### Remote or Published Endpoint

Choose the client you use, download its remote setup script from this repository, and run it:

```sh
# OpenCode
curl -fsSLO https://raw.githubusercontent.com/j3soon/local-llm-notes/main/examples/basic-secure-api/scripts/setup_opencode.sh
chmod +x setup_opencode.sh
./setup_opencode.sh

# Pi
curl -fsSLO https://raw.githubusercontent.com/j3soon/local-llm-notes/main/examples/basic-secure-api/scripts/setup_pi.sh
chmod +x setup_pi.sh
./setup_pi.sh
```

The remote scripts accept authenticated and unauthenticated OpenAI-compatible endpoints. When supplied, the API key is embedded in `~/.config/opencode/opencode.json` for OpenCode or `~/.pi/agent/models.json` for Pi; any timestamped `.bak.<timestamp>` file created on a later update also contains the credential. Keep these files private. Pi stores a non-secret placeholder when the endpoint needs no key because Pi requires a configured API-key value to make a custom model available.

### Local Model with No Internet Access

Choose the corresponding local script:

```sh
# OpenCode
curl -fsSLO https://raw.githubusercontent.com/j3soon/local-llm-notes/main/examples/basic-secure-api/scripts/setup_opencode_local.sh
chmod +x setup_opencode_local.sh
./setup_opencode_local.sh

# Pi
curl -fsSLO https://raw.githubusercontent.com/j3soon/local-llm-notes/main/examples/basic-secure-api/scripts/setup_pi_local.sh
chmod +x setup_pi_local.sh
./setup_pi_local.sh
```

The local scripts use the unauthenticated endpoint `http://llama-cpp:37000/v1`; Pi stores a dummy API key as required for keyless custom providers. OpenCode or Pi must run in a container attached to the external `local-llm-internal` Docker network. Mount the selected client's host configuration into the home directory of the container user (the example below assumes the container runs as root):

```yaml
services:
  agent:
    image: your-agent-image
    volumes:
      - ${HOME}/.config/opencode:/root/.config/opencode # OpenCode
      - ${HOME}/.pi/agent:/root/.pi/agent               # Pi
    networks:
      - local-llm-internal

networks:
  local-llm-internal:
    external: true
```

### NVIDIA Nemotron 3

To add NVIDIA-hosted Nemotron 3 Ultra and Super:

```sh
../scripts/setup_opencode_nvidia_nemotron_3.sh
opencode
```

The script prompts for an NVIDIA API key, then adds or updates the `nvidia` provider using NVIDIA's OpenAI-compatible inference endpoint. Nemotron 3 Ultra is selected as the default model.

References: [NVIDIA Nemotron 3 Ultra API](https://build.nvidia.com/nvidia/nemotron-3-ultra-550b-a55b), [NVIDIA Nemotron 3 Super API](https://build.nvidia.com/nvidia/nemotron-3-super-120b-a12b), [OpenCode custom providers](https://opencode.ai/docs/providers/#custom-provider), and [opencode-nemotron-free](https://github.com/j3soon/opencode-nemotron-free).

## Security Scan

For the vLLM deployment, run from this directory:

```sh
./scripts/basic_security_scan.sh
# Optional environment file and model:
./scripts/basic_security_scan.sh .env unsloth/Qwen3.8-27B-NVFP4
```

The scan loads `.env` automatically and requires `curl`, `jq`, `openssl`, and `timeout`. It checks HTTPS/TLS, missing and invalid keys, blocked routes and methods, model discovery, and four small inference requests: streaming and non-streaming Chat Completions and Responses, with generated text and consistent token usage. It exits on the first failure and checks responses for configured secrets and obvious internal details. TLS checks cover Cloudflare's public edge; inspect the Docker host firewall separately. vLLM reports token usage; USD costs are calculated by LiteLLM.

For the llama.cpp deployment, use the shared scan:

```sh
. ./.env
../scripts/basic_security_scan.sh "$SERVER_NAME" "$LLM_API_KEY"
```

The model server stays private on the Compose network. The llama.cpp stack additionally has a localhost-only UI binding on `127.0.0.1:38000`; the vLLM stack publishes no ports. Cloudflare Tunnel, forwarding into `nginx`, is the only remotely reachable entrypoint.

Remote clients can access only `GET /v1/models`, `POST /v1/chat/completions`, and `POST /v1/responses`, gated by `Authorization: Bearer $LLM_API_KEY`; the vLLM stack also validates the same key at the model server. Plain HTTP is redirected to HTTPS by Cloudflare's "Always Use HTTPS" setting. The llama.cpp UI remains available without authentication from localhost via `127.0.0.1:38000`; remove that mapping from [`compose.yaml`](./compose.yaml) to disable it.

## LiteLLM Proxy

For a standalone gateway routing OpenAI GPT and the existing Qwen3.8 27B vLLM API through model aliases, see [litellm/](./litellm/). Its separate [`litellm/compose.yaml`](./litellm/compose.yaml) and `litellm/.env` run as the `local-llm-proxy` project, with persistent per-request usage and spend logs. Keep the vLLM deployment running independently.
