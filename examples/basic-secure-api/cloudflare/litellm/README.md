# LiteLLM Proxy

Standalone [LiteLLM](https://docs.litellm.ai/docs/proxy/docker_quick_start) deployment for OpenAI GPT, optional Azure OpenAI, and the existing Qwen3.8 27B vLLM API. It follows the [official Compose quickstart](https://raw.githubusercontent.com/BerriAI/litellm/main/docker/docker-compose.quickstart.yml), adding model configuration and an API-only NGINX gateway behind Cloudflare Tunnel. The four services are LiteLLM, Postgres, NGINX, and `cloudflared`, using their own `local-llm-proxy` Compose project with no GPU. Start and stop [vLLM](../compose.vllm.yaml) independently; leave its Compose file and `.env` as they are. Qwen requests require that upstream to be running; GPT requests work without it.

## Setup

From `examples/basic-secure-api/cloudflare/litellm`:

```sh
./scripts/gen_env.sh .env
```

Generating `APP_API_KEY` only saves its secret in `.env`. Register it after starting the stack with `./scripts/create_virtual_key.sh` below; until then, the UI shows no virtual keys.

The script prompts for missing proxy/provider settings and generates missing master/salt/application/database secrets. If `.env` exists, it reuses values for template settings (including explicitly empty optional API keys) and asks for confirmation before replacing the file. On confirmation, it saves the original as `.env_<UTC timestamp>.<random suffix>.bak` with mode 600, then writes only the template settings; variables outside the template are dropped. These backups are ignored by Git. Answering no or pressing Enter leaves it unchanged. The completed file is written atomically with mode 600. Provider keys may be left empty; model selection is manual in YAML. It requires `openssl`. Alternatively, copy `.env.example` to `.env`, run `chmod 600 .env`, and fill in the values manually.

- For manual setup, generate independent master, salt, and application keys with `openssl rand -hex 32` (prefix each with `sk-`), and a hex Postgres password with the same command. The script generates these automatically. Keep the salt and database together across restarts.
- Direct OpenAI is commented out by default. To enable it, uncomment its model blocks and permissions and set `OPENAI_API_KEY`. Both `gpt-6.1-sol` and `gpt-6-luna` use that key. Model names and provider prefixes are defined directly in `litellm-config.yaml`; change both `model_name` and `litellm_params.model` when selecting another model.
- For Qwen, set `VLLM_API_BASE` to the **existing** endpoint, such as `https://llm.example.com/v1`, and `VLLM_API_KEY` to that deployment's `LLM_API_KEY`. The upstream model in `litellm-config.yaml` must match `/v1/models`, with the `hosted_vllm/` routing prefix. Clients request the full served model name `unsloth/Qwen3.8-27B-NVFP4`.
- Create a **separate** [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/setup/) for this stack, set its token and a new `SERVER_NAME` in `.env`, and point its public hostname to `http://nginx:80`. Enable Always Use HTTPS. `SERVER_NAME` is used in the curl examples; configure the hostname in Cloudflare too.

The vLLM stack publishes no host port. Its existing HTTPS endpoint is reachable from this proxy without joining its Docker network. `localhost` inside LiteLLM refers to the proxy container. Never point `VLLM_API_BASE` at LiteLLM itself.

Start the stack and register the application key once from the Docker host (requires `curl`, `jq`, and the local port mapping):

```sh
docker compose config --quiet
docker compose up -d --wait
./scripts/create_virtual_key.sh
docker compose ps
```

Run all Compose commands from this directory, including `logs`, `restart`, and `down`. Its local `.env` and `compose.yaml` belong to the separate `local-llm-proxy` project. The Compose image pins [v1.106.2](https://github.com/BerriAI/litellm/releases/tag/v1.106.2). After editing model routing/pricing in `litellm-config.yaml`, restart `litellm`; after editing environment variables, run `up -d` again.

## Optional providers and Azure OpenAI

Before starting, fill the keys for the models you intend to use. For each unused provider, **comment out its complete entries in `model_list` and its names in `litellm_settings.default_key_generate_params.models`**. Leaving an API key empty does not reliably disable a model or remove it from discovery; commenting out the model removes its route. Keep at least one active model. Master, salt, and application keys remain required.

Azure `gpt-6.1-sol` and `gpt-6-luna` are enabled by default in `litellm-config.yaml`:

1. Set `AZURE_API_KEY`, `AZURE_API_BASE` (the resource root, e.g. `https://your-resource.openai.azure.com/`), and `AZURE_API_VERSION` in `.env`.
2. Confirm that the `gpt-6.1-sol` and `gpt-6-luna` deployments exist in your Azure resource. Model Router remains commented out; uncomment its block and matching permission only if you want it.
3. Start the stack, then register the application key as shown in Setup above. Clients request `azure/gpt-6.1-sol` or `azure/gpt-6-luna`, keeping Azure routes separate from direct OpenAI.

The Azure configuration uses API version `2024-12-01-preview`. The YAML includes the two enabled GPT deployments and an optional Model Router example; copy the direct-model block for other deployments. Set `model_info.base_model` to the actual Azure model for pricing when a deployment name differs. Model Router chooses its underlying model, so its example has no fixed `base_model` or custom price.

Keep each Azure entry's explicit `model_info.id` stable and unique. In this deployment, Azure entries passed standalone router initialization but disappeared from both model-list APIs and Model Management; assigning explicit IDs restored them. LiteLLM's [database reconciliation](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/proxy/proxy_server.py) removes deployments whose IDs are absent from its current config/database list. The exact source of the generated-ID mismatch was not established.

References: [LiteLLM Azure OpenAI](https://docs.litellm.ai/docs/providers/azure), [Microsoft Model Router](https://learn.microsoft.com/en-us/azure/foundry/openai/concepts/model-router).

## Admin access

- On the Docker host, open <http://127.0.0.1:14000/ui>. Sign in as `admin` with `LITELLM_MASTER_KEY` as the password ([LiteLLM UI guide](https://docs.litellm.ai/docs/proxy/ui)).
- For a remote Docker host, run `ssh -N -L 14000:127.0.0.1:14000 user@docker-host`, then open the same URL on your computer.
- `LITELLM_BIND=127.0.0.1:` and `LITELLM_PORT=14000` produce `127.0.0.1:14000:4000`: host port 14000 forwards to container port 4000. The trailing colon is intentional. These are also the Compose defaults. To disable local access, remove/comment the `litellm.ports` section; `LITELLM_BIND` chooses an address and cannot disable publishing. The API remains available through Cloudflare.
- **The Admin UI and management endpoints are blocked through Cloudflare.** The tunnel connects to NGINX, whose dedicated local `nginx.conf` allows only model discovery and inference routes. It does not mount or depend on the vLLM stack's NGINX configuration. Local port 14000 connects directly to LiteLLM for administration.

## Requests

`APP_API_KEY` holds the secret in `.env`; permissions and limits are defined in `litellm_settings.default_key_generate_params` in `litellm-config.yaml`. The script registers an inference-only key named `app` through the loopback `/key/generate` API. LiteLLM stores it in Postgres; declaring a key in `.env` alone does not register it. No key registration happens automatically at startup, and the script does not overwrite an already registered key. Defaults are copied when a key is created; manage that key's later policy changes through the local Admin UI or `/key/update` ([virtual-key documentation](https://docs.litellm.ai/docs/proxy/virtual_keys)).

The configured defaults allow the three active model entries, a $20 budget resetting every 30 days, and 60 requests per minute. With four users sharing `APP_API_KEY`, both limits apply to their combined usage. Each additional key receives its own budget and rate limit. Qwen has zero configured cost, so its usage is constrained by the rate limit rather than the dollar budget. Edit the defaults before registration to choose your limits.

RPM counts model API calls, not complete conversations or agent runs. A simple turn usually makes one call; an agent turn can make several calls as it processes tool results. Streaming chunks do not count as separate requests. RPM limits request frequency, while `max_parallel_requests` separately limits simultaneous in-flight requests; neither setting counts people ([rate-limit documentation](https://docs.litellm.ai/docs/proxy/users)).

Clients use `https://$SERVER_NAME/v1` with `APP_API_KEY` as their API key. This key permits inference and model discovery without management access. Provider keys stay on the proxy. Cloudflare Tunnel forwards through NGINX to LiteLLM. NGINX permits `GET /v1/models`, `POST /v1/chat/completions`, and `POST /v1/responses`; other paths return 403, including `/ui`, `/docs`, and management APIs. LiteLLM authenticates API keys, including virtual keys. Streaming uses [unbuffered proxying](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering). Keep the master key for trusted administration.

```sh
set -a
source .env
set +a

curl -fsS "https://$SERVER_NAME/v1/models" \
  -H "Authorization: Bearer $APP_API_KEY"

curl -fsS "https://$SERVER_NAME/v1/chat/completions" \
  -H "Authorization: Bearer $APP_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"azure/gpt-6.1-sol","messages":[{"role":"user","content":"What is 17 times 23?"}],"reasoning_effort":"medium"}'

curl -fsS -N "https://$SERVER_NAME/v1/chat/completions" \
  -H "Authorization: Bearer $APP_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"unsloth/Qwen3.8-27B-NVFP4","messages":[{"role":"user","content":"What is 17 times 23?"}],"chat_template_kwargs":{"reasoning_effort":"medium"},"stream":true,"stream_options":{"include_usage":true}}'
```

Both models support streaming; non-streaming requests return `usage` directly. Reasoning depends on the upstream model: GPT accepts `reasoning_effort`, while Qwen's template settings can be passed as `chat_template_kwargs` (Python SDK: `extra_body={"chat_template_kwargs": {...}}`). Qwen returns parsed reasoning in `reasoning_content` when supplied by vLLM. GPT may report reasoning token counts without exposing reasoning text. For GPT models that need it, LiteLLM bridges reasoning plus function tools through OpenAI's Responses API, retaining the client's Chat Completions interface ([implementation](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/main.py)).

For tool calling, pass standard OpenAI `tools` and `tool_choice` fields to either model. For example:

```sh
curl -fsS "https://$SERVER_NAME/v1/chat/completions" \
  -H "Authorization: Bearer $APP_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"unsloth/Qwen3.8-27B-NVFP4","messages":[{"role":"user","content":"What is the weather in Taipei?"}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Get current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],"tool_choice":"auto"}'
```

The client executes returned tool calls, then sends the assistant message and `role: "tool"` result with the matching `tool_call_id` in the next request. The proxy does not execute functions. The existing vLLM deployment already enables `--enable-auto-tool-choice --tool-call-parser qwen3_xml --reasoning-parser qwen3`. These upstream parsers are required; proxy capability metadata alone cannot enable them. See [LiteLLM's vLLM integration](https://docs.litellm.ai/docs/providers/vllm) and [vLLM tool calling](https://docs.vllm.ai/en/latest/features/tool_calling/).

## Usage, costs, and logging

Qwen supports image input using OpenAI-style `image_url` content parts ([model card](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4)). Its `supports_vision` metadata advertises that capability; vLLM performs image processing. Keep the `hosted_vllm/` routing prefix in `litellm_params.model`, while clients use `unsloth/Qwen3.8-27B-NVFP4` ([provider routing](https://docs.litellm.ai/docs/providers/vllm)). Both GPT models have automatic pricing entries in LiteLLM's [cost map](https://docs.litellm.ai/docs/proxy/model_cost_map).

Postgres persists per-request token counts, model, request ID, and USD spend in the project's named volume. Open `http://127.0.0.1:14000/ui` (username `admin`, password `LITELLM_MASTER_KEY`) to inspect usage, or query individual logs locally:

```sh
curl -fsS 'http://127.0.0.1:14000/spend/logs/v2?page=1&page_size=10' \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
docker compose logs -f litellm
```

The database uses `postgres:18-alpine`, tracking PostgreSQL 18 patch releases. The volume is mounted at `/var/lib/postgresql`, with data stored in `/var/lib/postgresql/18/docker` ([image documentation](https://hub.docker.com/_/postgres)).

Operational logs use JSON and are available through `docker compose logs`. The example sets `LITELLM_LOG=INFO` for normal operational logs. Set it to `DEBUG` for detailed troubleshooting output. This level does not affect prompt/response persistence in Postgres. `turn_off_message_logging: false` enables message content in logging integrations, and `store_prompts_in_spend_logs: true` persists request prompts and responses alongside usage and spend in Postgres. Logs therefore contain conversation content. The Admin UI's request log detail view shows stored prompts and responses; list endpoints may omit these heavier fields. Spend writes are asynchronous, so allow time after completion before checking logs. `down` preserves the database; `down -v` deletes its usage history. See [spend tracking](https://docs.litellm.ai/docs/proxy/cost_tracking) and [logging settings](https://docs.litellm.ai/docs/proxy/config_settings).

`hosted_vllm/` selects LiteLLM's vLLM provider adapter, just as `openai/` selects OpenAI. LiteLLM removes that prefix before sending the actual model name to vLLM. `api_base` sets the server address; it does not identify the provider. `drop_params: false` rejects unsupported OpenAI parameters; setting it to `true` silently removes those parameters to improve compatibility across models. It is independent of logging ([parameter handling](https://docs.litellm.ai/docs/completion/drop_params)).

Accounting findings:

- Use **upstream-reported usage**, including the final usage chunk for streams. The pinned proxy automatically requests upstream usage for streamed chat, even when the client omits it. Keep `always_include_stream_usage` unset to retain this behavior. Do not put `stream_options` in model defaults: it also reaches non-streaming requests. Clients should request usage explicitly to see it and consume the stream through completion. Missing usage or interrupted streams cannot guarantee exact accounting; estimated token counts are not billing evidence. See the [stream accounting implementation](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/proxy/common_request_processing.py).
- GPT uses LiteLLM's upstream model cost map, preserving cached-input discounts and model-specific output/reasoning pricing. Reasoning tokens are already part of completion tokens; do not add them again. Keep the model map current and compare against the provider invoice after changing models, prices, or service tiers. See the [cost map](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json).
- Qwen explicitly costs **$0 in provider fees** by default. For internal chargeback, edit the three numeric USD-per-token rates in `model_info`; divide a per-million rate by 1,000,000. Cached prompt tokens use `cache_read_input_token_cost`; other input and output use their respective rates. These are configured allocations, not measured electricity or GPU costs. See [custom pricing](https://docs.litellm.ai/docs/proxy/custom_pricing).
- vLLM's existing `--enable-prompt-tokens-details` exposes `usage.prompt_tokens_details.cached_tokens`. Its reasoning/tool parsers and model tokenizer supply the actual usage; client-facing model names match the upstream models. Compare one streamed and one non-streamed response against their spend rows before relying on reports. No automatic cross-provider fallback is configured; router retries are disabled to avoid repeating billable calls.
