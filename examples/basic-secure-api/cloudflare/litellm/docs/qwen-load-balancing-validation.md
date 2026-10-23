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
| Session affinity | 16 sessions x 6 requests with `x-session-id` each stayed on one deployment (5 primary, 11 secondary). A session pinned to the secondary fell back to the primary while the secondary was offline and returned after recovery. `x-litellm-session-id`, `x-session-id`, `x-claude-code-session-id`, and `metadata.session_id` pinned 8 of 8 sessions; `litellm_session_id` in the body and no session ID pinned none. |
| Mutation | With `enable_health_check_routing: false`, the test failed: 24 of 50 requests returned HTTP 500 after the secondary stopped. Without `session_affinity`, it failed when one session was served by both deployments. |

## Admin UI data

A second run used a temporary Postgres database with `STORE_MODEL_IN_DB=True` and the API endpoints used by the Admin UI. The UI was not opened in a browser.

- `/health/latest` (Health Checks) listed `qwen-primary` and `qwen-secondary` separately with no Azure entries. Each status changed to `unhealthy` after an outage and back to `healthy` after recovery.
- `/spend/logs/v2?model_id=…` (Logs) separated successful and failed requests by deployment ID; failed requests to the stopped server were logged as `qwen-secondary`.
- Each probe adds a spend-log row under `litellm-internal-health-check` with an empty model ID; `exclude_internal_health_checks=true` (UI: **Hide Health Checks**) removes them.
- `/v1/model/info` with a virtual key returned both deployments without API keys. As before, it includes each deployment's `api_base`.
- `/spend/logs/v2` requires `start_date` and `end_date` in 1.106.2.

## Live prefix-cache reuse

Measured on 2026-10-23 through `litellm.j3soon.com` with 8-turn conversations of 4.6k to 11.7k prompt tokens and thinking disabled. Both vLLM servers run `--enable-prefix-caching` and report `cached_tokens`.

| Routing | Cached share of prompt tokens, turns 2–8 |
| --- | --- |
| Random through LiteLLM, before session affinity (2 runs) | 48%, 48% |
| Always the primary, called directly (2 runs) | 61%, 61% |

Turns served by the other server reused only what that server had cached for the conversation. Hits arrived in 1,600-token steps, so even fully sticky turns reuse less than the whole previous prompt. Before session affinity was deployed, [tests/qwen_cache_affinity_test.py](../tests/qwen_cache_affinity_test.py) failed because one session was served by both deployments. After deployment, with both servers healthy, it passed:

- 6 sessions × 4 requests each stayed on one deployment (4 sessions on the primary, 2 on the secondary).
- A 6-turn conversation with `x-session-id` stayed on `qwen-secondary` and reused cache on every later turn: 55% of prompt tokens on turns 2–6.
- The same conversation without a session ID switched deployments: turn 2 reused nothing and turns 2–6 reused 46%.

