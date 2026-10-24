# Qwen metadata validation

Checked on 2026-10-24. Credentials were loaded from local `.env` files and are omitted here.

## Live baseline

Both models returned HTTP 200 and `OK` for short Chat Completions through the public LiteLLM proxy.

| Field | Azure Luna | Qwen primary |
| --- | --- | --- |
| `/v1/models` max input | 922,000 | 262,144 |
| `/v1/models` max output | 128,000 | 262,144 |
| `/v1/model/info` token limits | Present | Initially null; populated on repeat |
| Tools, reasoning, vision | true | true |
| System messages, parallel tools, tool choice, prefix caching, native streaming, response schema, native structured output | Advertised where applicable | null |
| Supported endpoints | Chat Completions, Responses | null |

The primary's upstream `/v1/models` returned `max_model_len: 262144`. The secondary returned HTTP 530 during these probes. The user confirmed that it runs the same model and configuration as the primary, so both deployments share the metadata validated on the primary.

Direct primary probes confirmed:

- Chat Completions streaming: HTTP 200, four chunks, final `[DONE]`.
- Responses streaming: HTTP 200, text deltas and `response.completed`. Responses uses typed events rather than a Chat Completions `[DONE]` sentinel.
- Named tool choice: returned `get_weather` with the requested city.
- Parallel tool calls: one response contained calls for Paris and Tokyo.
- JSON schema: a constrained enum forced `SCHEMA_ENFORCED` despite the prompt asking for `WRONG`.
- Prefix caching: the second identical 13,925-token prompt reported 11,200 cached tokens. A shorter 2,624-token prompt reported no cache hits; a zero count on a small prompt alone does not show caching is disabled.
- Context enforcement: requesting 262,145 output tokens with a short prompt returned HTTP 400, identifying `max_model_len=max_total_tokens=262144`.

These are short functional probes and one repeated cache prompt, not a full-context generation or load test.

## Native structured output verification

Follow-up live checks confirmed `supports_native_structured_output: true` for the primary's vLLM service, directly and through the public LiteLLM proxy. On each path:

- Without a schema, the control prompt returned exactly `WRONG` as plain text.
- With a strict JSON schema, the same prompt produced valid JSON containing a random marker known only through the schema, an integer constrained to 7, and an array constrained to two enum-valued items, with required fields and no extra properties. Outputs were validated with `jsonschema`.
- Chat Completions passed with thinking disabled, with xhigh thinking enabled, and with streaming. Responses passed using `text.format`.
- An invalid schema type returned HTTP 400 with a grammar error.

All eight valid-schema responses passed validation; both controls and both invalid-schema requests behaved as expected. Proxy responses identified `qwen-primary`. This follow-up did not independently test the secondary.

Here, native means enforcement by the serving backend. vLLM [implements structured outputs with constrained decoding backends](https://docs.vllm.ai/en/latest/features/structured_outputs/); it does not require the model weights alone to guarantee JSON. These tests do not claim support for every JSON Schema keyword or strict function-tool arguments. An unspecified flag on Luna is not evidence that Luna lacks structured outputs.

## Configuration and fallback

`compose.vllm.yaml` explicitly sets `--max-model-len 262144`. The model's [generation config](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4/blob/main/generation_config.json) has no `max_new_tokens` cap. Input and output therefore have individual 262,144-token ceilings constrained by a single shared budget. This does not reserve a fixed amount for output; prompt/template/image tokens consume that budget too.

Stock vLLM's [model listing](https://github.com/vllm-project/vllm/blob/main/vllm/entrypoints/openai/models/serving.py) supplies `max_model_len`, with no feature flags or separate input/output limits. LiteLLM 1.106.2's [discovery parser](https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/llms/openai_like/model_info.py) imports token limits only, uses a 300-second success cache and a 60-second failure cache, and derives both input/output ceilings from `max_model_len` when no separate limits exist. Adding arbitrary feature fields to a vLLM response would not fix LiteLLM's capability metadata.

The shared `&qwen_info` anchor declares those limits and features for both deployments; the secondary overrides only its deployment ID. Unknown capabilities remain unspecified. `/v1/model/info` is the publicly allowed metadata route; the unprefixed management route stays blocked.

## Local verification and deployment

The existing `tests/qwen_failover_test.py` now checks both deployments' metadata against a real LiteLLM 1.106.2 proxy with mock upstreams returning no model cards. It compares `/v1/models` with `/v1/model/info` and repeats the check with either upstream offline, alongside routing, affinity, failover, and recovery checks.

The metadata checks verify equal limits and capabilities for both deployment IDs, agreement with `/v1/models`, and availability without successful upstream discovery. The vLLM context argument and shared metadata both specify 262,144 tokens.

All local metadata, routing, session affinity, failover, and recovery checks passed with the shared configuration.

The workspace has no Docker executable or SSH access to the serving host. Repository changes must be applied on that host before the live metadata changes:

```sh
# From examples/basic-secure-api/cloudflare, on the primary host:
docker compose -f compose.vllm.yaml config --quiet
docker compose -f compose.vllm.yaml up -d vllm

# On the LiteLLM host, from its litellm directory:
docker compose config --quiet
docker compose restart litellm
```

After deployment, inspect `/v1/models` and `/v1/model/info` with the application key and confirm matching limits and capabilities for `qwen-primary` and `qwen-secondary`, including immediately after proxy startup. Do not infer deployment completion from the pre-deployment live probes above.
