# LiteLLM Proxy

Standalone OpenAI-compatible gateway for Azure OpenAI, optional direct OpenAI, and self-hosted Qwen through vLLM. [Compose](./compose.yaml) follows the [official quickstart](https://raw.githubusercontent.com/BerriAI/litellm/main/docker/docker-compose.quickstart.yml), with LiteLLM 1.106.2, Postgres, NGINX, and Cloudflare Tunnel in the separate `local-llm-proxy` project. Keep [vLLM](../compose.vllm.yaml) running for Qwen; GPT requests work independently.

## Setup

From `examples/basic-secure-api/cloudflare/litellm`:

```sh
./scripts/gen_env.sh
```

This generates `.env` with provider settings and independent master, salt, application, and database secrets. **The application key must also be registered after startup**, as shown below. The script requires `openssl`, reuses existing template values, and asks before overwriting `.env`. It backs up the original with mode 600 and writes only settings from `.env.example`; extra variables are removed. Alternatively, copy `.env.example`, fill its values, and run `chmod 600 .env`.

Configure providers in `.env` and [litellm-config.yaml](./litellm-config.yaml):

- **Azure:** enabled by default for `azure/gpt-6.1-sol` and `azure/gpt-6-luna`. Set `AZURE_API_KEY`, `AZURE_API_BASE` to the resource root without a trailing slash, and `AZURE_API_VERSION=v1`. Azure deployment names must match `litellm_params.model`.
- **Qwen:** set `VLLM_API_BASE` to the upstream HTTPS endpoint, such as `https://llm.example.com/v1`, and `VLLM_API_KEY` to its `LLM_API_KEY`. Keep the `hosted_vllm/` provider prefix in `litellm_params.model`; clients use the full served name `unsloth/Qwen3.8-27B-NVFP4`.
- **Direct OpenAI:** uncomment its model entries and key permissions, then set `OPENAI_API_KEY`.
- **Unused providers:** comment out their complete model entries and their names in `default_key_generate_params.models`. Empty API keys do not reliably disable models. Keep at least one active model.

Create a separate [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/setup/), set `CLOUDFLARE_TUNNEL_TOKEN` and `SERVER_NAME`, and point its public hostname to `http://nginx:80`. Enable [Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/) and set [Minimum TLS Version](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/minimum-tls-version/) to **TLS 1.2**. The vLLM upstream uses its own tunnel; no shared Docker network is required.

Start and register the inference key:

```sh
docker compose config --quiet
docker compose up -d --wait
./scripts/create_virtual_key.sh
docker compose ps
```

Registration requires `curl`, `jq`, and local access. Declaring `APP_API_KEY` in `.env` alone does not create a virtual key in Postgres or the Admin UI. Keep the master key for administration.

Run Compose commands from this directory. After changing model configuration, run `docker compose restart litellm`; after changing environment variables or mounts, run `docker compose up -d` and `docker compose restart nginx`. After changing NGINX configuration, restart `nginx`.

## Azure API

Azure uses the [v1 API](https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle?tabs=python#api-version-changelog). LiteLLM's `api_version: v1` selects `/openai/v1/` without a dated query parameter; LiteLLM adds this path to the resource root.

Keep Azure `model_info.id` values stable and unique for [database reconciliation](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/proxy/proxy_server.py). If a deployment name differs from its underlying model, set `model_info.base_model` for pricing. The optional Model Router entry has no fixed base model because its underlying model varies. See [LiteLLM Azure](https://docs.litellm.ai/docs/providers/azure) and [Microsoft Model Router](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/model-router).

## Admin access and security

Open <http://127.0.0.1:14000/ui> on the Docker host. Sign in as `admin` with `LITELLM_MASTER_KEY` as the password. From another computer:

```sh
ssh -N -L 14000:127.0.0.1:14000 user@docker-host
```

`LITELLM_BIND=127.0.0.1:` and `LITELLM_PORT=14000` publish container port 4000 on loopback port 14000; the trailing colon is required. To disable local access, remove/comment the `litellm.ports` section. `LITELLM_BIND` selects an address and cannot disable port publishing.

The public tunnel connects through dedicated NGINX rules. The UI, docs, and management APIs are blocked. Only these authenticated routes are allowed:

- `GET /v1/models`
- `GET /v1/model/info`
- `POST /v1/chat/completions`
- `POST /v1/responses`

LiteLLM authenticates bearer tokens, including virtual keys. Model metadata is filtered by permissions and removes sensitive connection fields. Provider credentials stay on the proxy. See the [UI guide](https://docs.litellm.ai/docs/proxy/ui) and [virtual-key documentation](https://docs.litellm.ai/docs/proxy/virtual_keys).

## Key limits

`default_key_generate_params` sets the `app` key's model permissions, **$20 per 30 days**, and **60 requests per minute**. Four users sharing this key share those limits. Each additional key receives its own budget and rate limit. Qwen's configured cost is zero, so the dollar budget does not constrain it.

Each model API call counts toward RPM; an agent run can make several calls. Streaming chunks do not count separately. RPM limits frequency; `max_parallel_requests` separately limits simultaneous requests ([rate limits](https://docs.litellm.ai/docs/proxy/users)).

Defaults are copied when the key is registered. Change an existing key through the local Admin UI or `/key/update`; rerunning the registration script does not overwrite it.

## Requests and reasoning

Clients use `https://$SERVER_NAME/v1` with `APP_API_KEY`:

```sh
. ./.env
curl -fsS "https://$SERVER_NAME/v1/models" \
  -H "Authorization: Bearer $APP_API_KEY"

curl -fsS "https://$SERVER_NAME/v1/chat/completions" \
  -H "Authorization: Bearer $APP_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"azure/gpt-6-luna","messages":[{"role":"user","content":"What is 17 times 23?"}],"reasoning_effort":"low"}'
```

All configured models support streaming. Set `stream: true` and, for Chat Completions, `stream_options: {"include_usage": true}` to receive final token usage. Read the stream through completion.

| Model | Default reasoning | Advertised options |
| --- | --- | --- |
| Qwen | xhigh | none, low, medium, xhigh |
| GPT Luna | low | none, low, medium, high, xhigh, max |
| GPT Sol | low | low, medium, high, xhigh, max |

GPT accepts `reasoning_effort`. Qwen uses `chat_template_kwargs`: `enable_thinking: false` disables reasoning; otherwise set `enable_thinking: true` and `reasoning_effort` to low, medium, or xhigh. In the Python SDK, pass these through `extra_body`. Clients may override deployment defaults. Metadata's `chat_reasoning_options` advertises parameters for clients; the upstream validates them. Qwen returns reasoning text in `reasoning_content`, while GPT may return reasoning token counts without text. See the [Qwen template](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4/blob/main/chat_template.jinja).

Qwen supports image input through `image_url` content parts ([model card](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)). For tool calls, send standard `tools` and `tool_choice`, execute the returned calls in the client, and send their results with matching `tool_call_id` values. vLLM enables the Qwen reasoning/tool parsers; LiteLLM does not execute tools. See [vLLM integration](https://docs.litellm.ai/docs/providers/vllm) and [tool calling](https://docs.vllm.ai/en/latest/features/tool_calling/).

## Usage, costs, and logs

- **Non-streaming:** tokens are in JSON `usage`; total USD cost is in the `x-litellm-response-cost` header rather than the message body.
- **Streaming:** `include_cost_in_streaming_usage` enables final `usage.cost`, including inside Responses' `response.completed` event. Chat clients must request `stream_options.include_usage: true`. Initial streaming cost headers may be placeholders; read the final usage event.
- **Pricing:** GPT uses LiteLLM's [cost map](https://docs.litellm.ai/docs/proxy/model_cost_map). Qwen has explicit zero input/output/cache-read rates; edit these USD-per-token rates for internal chargeback ([custom pricing](https://docs.litellm.ai/docs/proxy/custom_pricing)). Provider cost excludes GPU operating costs.
- **Breakdown:** total is uncached input + cached input + output. Reasoning cost is already part of output and must not be added again. Use upstream token counts and final streaming usage; interrupted streams may lack a complete receipt. Keep `always_include_stream_usage` unset and do not place `stream_options` in model defaults.

**LiteLLM 1.106.2 limitation:** Qwen's calculated zero may be omitted from the non-streaming total-cost header and final streaming `usage.cost`, while token usage and zero component costs remain available. Luna's positive costs are reported. Treat a missing cost as unavailable, not as zero. This deployment uses LiteLLM's built-in reporting without custom callbacks. See the pinned [header implementation](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/proxy/common_request_processing.py) and [stream builder](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/main.py).

Postgres stores per-request tokens, USD spend, prompts, and responses in its named volume. Inspect request details in the local UI or query logs:

```sh
curl -fsS 'http://127.0.0.1:14000/spend/logs/v2?page=1&page_size=10' \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
docker compose logs -f litellm
```

`LITELLM_LOG=INFO` controls operational JSON logs; `DEBUG` adds troubleshooting detail. Prompt/response persistence is controlled separately by `turn_off_message_logging: false` and `store_prompts_in_spend_logs: true`. Spend writes are asynchronous. `docker compose down` preserves history; `down -v` deletes it. Keep the salt and database together. Postgres 18 data is mounted under `/var/lib/postgresql` ([image documentation](https://hub.docker.com/_/postgres)). See [spend tracking](https://docs.litellm.ai/docs/proxy/cost_tracking) and [logging settings](https://docs.litellm.ai/docs/proxy/config_settings).

`drop_params: false` rejects unsupported parameters; `true` silently removes them ([parameter handling](https://docs.litellm.ai/docs/completion/drop_params)). Router retries and automatic cross-provider fallback are disabled.

## Security scan

After registering the key, run:

```sh
./scripts/basic_security_scan.sh
# Optional environment file and model:
./scripts/basic_security_scan.sh .env unsloth/Qwen3.8-27B-NVFP4
```

Requires `curl`, `jq`, `openssl`, and `timeout`; loads `.env` automatically. It checks HTTPS/TLS, authentication, blocked routes/methods, model discovery/metadata, and two small Chat Completions requests with token usage and streaming cost. Provider charges may apply. Qwen currently fails the streaming-cost assertion because of the LiteLLM limitation above; that failure alone does not indicate an authentication or inference problem. The scan does not verify database persistence, the host firewall, or successful Responses inference.
