# Basic Secure API

Runs `llama.cpp` behind NGINX with a static Bearer token and a Let's Encrypt certificate.

The llama.cpp web UI is also exposed on `http://127.0.0.1:38000` for host-local access only.

## Setup

```sh
cd examples/basic-secure-api
mkdir -p ../../.cache state/letsencrypt state/www
./scripts/gen_env.sh
cat .env
docker compose up -d
# Only needed the first time, after Certbot gets the initial certificate.
docker compose restart nginx
```

For a local-only deployment with no published ports and no outbound internet access from the LLM container, use:

```sh
docker compose -f compose.local.yaml up -d
```

Requirements:

- `LLAMA_CPP_IMAGE` in `.env` must match your system.
- Use `j3soon/llama.cpp:server-cuda-spark` on DGX Spark.
- Use `ghcr.io/ggml-org/llama.cpp:server-cuda` on x86 CUDA hosts such as RTX PRO 6000.
- `SERVER_NAME` in `.env` must resolve to this host.
- Port `80` and `37000` must be reachable from the public internet for the ACME challenge and API access.
- `docker compose restart nginx` is needed once after Certbot gets the first certificate so NGINX switches from HTTP bootstrap mode to HTTPS mode.
- `compose.local.yaml` does not publish any ports and puts `llm` on an internal Docker network only.

Note: This example assumes 96GB VRAM (e.g., RTX PRO 6000), with context size currently set to 512K, as mentioned in the [Reddit benchmark](https://www.reddit.com/r/LocalLLaMA/comments/1rrw3g4/nemotron3super120ba12b_nvfp4_inference_benchmark/). Also note that Nemotron 3 Super is specialized for long context length due to its architecture [using Mamba-2 layers](https://developer.nvidia.com/blog/introducing-nemotron-3-super-an-open-hybrid-mamba-transformer-moe-for-agentic-reasoning/).

## Optional OpenCode Setup

Run `./scripts/setup_opencode.sh` to write `~/.config/opencode/opencode.json` so OpenCode can talk to the local `llama.cpp` endpoint.

For the local/offline Compose stack, run `./scripts/setup_opencode_local.sh` from the OpenCode container or environment that uses `local-llm-internal`. It configures OpenCode to reach `llama.cpp` at `http://local-llm-llama-cpp:37000/v1` without an API key.

## Test

```sh
source .env
curl https://$SERVER_NAME:37000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

Local llama.cpp UI from the Docker host:

```sh
curl http://127.0.0.1:38000/
```

## Internal Network

`compose.local.yaml` creates an internal Docker network named `local-llm-internal`.
Anything attached to that network can reach the LLM service by name, but containers on that network cannot reach the internet.

Example for another compose file:

```yaml
services:
  agent:
    image: your-agent-image
    networks:
      - local-llm-internal

networks:
  local-llm-internal:
    external: true
```

## Security Scan

Use `./scripts/basic_security_scan.sh` to verify the exposed surface and auth behavior.

```sh
SERVER_NAME='<value from .env>'
LLM_API_KEY='<value from .env>'
./scripts/basic_security_scan.sh "$SERVER_NAME" "$LLM_API_KEY"
```

`llm` stays private on the Compose network, except for a localhost-only UI binding on `127.0.0.1:38000`. NGINX is the only remotely reachable entrypoint.

Remote clients can access only `/v1/chat/completions`. Full access remains available from localhost.

Edit [`compose.yaml`](./compose.yaml) if you want a different model or API port. Edit [`nginx-http01.conf`](./nginx-http01.conf) and [`nginx-tls.conf`](./nginx-tls.conf) if you want to change the proxy behavior.
Edit [`compose.local.yaml`](./compose.local.yaml) if you want a network-isolated local deployment without any published ports.
