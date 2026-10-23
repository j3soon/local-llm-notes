# Qwen load-balancing validation

Validated on 2026-10-23 with LiteLLM `1.106.2` from PyPI (the version of the pinned `ghcr.io/berriai/litellm:v1.106.2` image). Docker was not available, so LiteLLM ran directly with the unmodified [litellm-config.yaml](../litellm-config.yaml). Local mock servers replaced both vLLM servers and Azure. Real vLLM, Azure, NGINX, and Cloudflare were not contacted.

Re-run the automated part with [tests/qwen_failover_test.py](../tests/qwen_failover_test.py).

## Results

| Check | Result |
| --- | --- |
| Config | Both deployments resolve to identical `litellm_params` and `model_info` apart from `api_base`, `api_key`, and `id`. Azure entries, `litellm_settings`, and `num_retries: 0` match the previous commit. |
| Startup | Logged `background_health_check_config enabled=True interval_seconds=30 health_check_routing=True model_groups=['unsloth/Qwen3.8-27B-NVFP4']`. |
| Split | 400 requests: 207 primary / 193 secondary. Test runs: 102/98 and 105/95. |
| Probe scope | Probes reached only the Qwen servers, every 30 seconds, each with its own key. Azure received no background requests; a manual Azure request still succeeded. |
| Probe content | `max_tokens: 16` with the deployment's `chat_template_kwargs`. |
| Offline | The next probe marked the secondary unhealthy (27 seconds after shutdown in the test); afterward, all requests went to the primary. Before that probe, requests routed to it returned HTTP 500, as expected with `num_retries: 0`: 6 of about 40 at one request per second. At about 10 requests per second, failures triggered LiteLLM's 5-second cooldown within about 1 second. |
| Hung server | A server that accepted connections but never replied was marked unhealthy after 14 seconds (`health_check_timeout: 15`). |
| Recovery | Restored after the next passing probe (21–29 seconds) with no failed requests. |
| Offline or unset at startup | Secondary marked unhealthy by the first probe; all traffic went to the primary. |
| Mutation | With `enable_health_check_routing: false`, the test failed: 24 of 50 requests returned HTTP 500 after the secondary stopped. |

## Admin UI data

A second run used a temporary Postgres database with `STORE_MODEL_IN_DB=True` and the API endpoints used by the Admin UI. The UI was not opened in a browser.

- `/health/latest` (Health Checks) listed `qwen-primary` and `qwen-secondary` separately with no Azure entries. Each status changed to `unhealthy` after an outage and back to `healthy` after recovery.
- `/spend/logs/v2?model_id=…` (Logs) separated successful and failed requests by deployment ID; failed requests to the stopped server were logged as `qwen-secondary`.
- Each probe adds a spend-log row under `litellm-internal-health-check` with an empty model ID; `exclude_internal_health_checks=true` (UI: **Hide Health Checks**) removes them.
- `/v1/model/info` with a virtual key returned both deployments without API keys. As before, it includes each deployment's `api_base`.
- `/spend/logs/v2` requires `start_date` and `end_date` in 1.106.2.
