# Performance

Qwen3.8-27B serving benchmark measured on 2026-08-25.

- GPU: NVIDIA RTX PRO 6000 Blackwell Max-Q, 96GB
- vLLM: 0.27.1, `unsloth/Qwen3.8-27B-NVFP4`
- llama.cpp: build 10615 (`f280b2698`), `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL`
- Server configuration: MTP 2; vLLM GPU memory utilization 0.55; llama.cpp eight 2,048-token slots
- Workload: 1,024-token input, 128 requested output tokens, two warmups, seed 42

Observed GPU memory usage was about 54GB for vLLM and 23GB for llama.cpp. These are not directly comparable because vLLM reserved a 20GB KV cache.

## NVIDIA Dynamo AIPerf

- Client: [AIPerf 0.11.0](https://github.com/ai-dynamo/aiperf), official `nvcr.io/nvidia/ai-dynamo/aiperf:0.11.0` container
- API: streaming `/v1/chat/completions`, medium reasoning effort
- Output: fixed at 128 tokens with `min_tokens` and `ignore_eos`

| Backend | Concurrency | Requests | Output tok/s | Mean TTFT | Mean ITL |
| --- | ---: | ---: | ---: | ---: | ---: |
| vLLM NVFP4 | 1 | 8 | 100.1 | 144.2 ms | 8.9 ms |
| llama.cpp Q4 | 1 | 8 | 62.8 | 619.4 ms | 11.2 ms |
| vLLM NVFP4 | 8 | 32 | 465.5 | 473.3 ms | 13.4 ms |
| llama.cpp Q4 | 8 | 32 | 142.9 | 1,604.1 ms | 43.1 ms |

Each row is one measured pass. vLLM was 1.59x faster at concurrency 1 and 3.26x faster at concurrency 8. All requests succeeded. MTP was active on both backends; native server metrics reported about 76% acceptance for vLLM and 74% for llama.cpp.

AIPerf counted 4,095 of 4,096 requested output tokens for the vLLM concurrency 8 run; the other runs matched the requested output length exactly.

## vLLM bench serve

- Client: [`vllm bench serve`](https://docs.vllm.ai/en/latest/cli/bench/serve/) from vLLM 0.27.1
- API: streaming `/v1/completions`
- Output: 128 requested tokens with `ignore_eos`

| Backend | Concurrency | Requests | Output tok/s | Mean TTFT | Mean TPOT |
| --- | ---: | ---: | ---: | ---: | ---: |
| vLLM NVFP4 | 1 | 8 | 79.2 | 132.7 ms | 11.7 ms |
| llama.cpp Q4 | 1 | 8 | 53.7 | 515.9 ms | 14.7 ms |
| vLLM NVFP4 | 8 | 32 | 278.0 | 508.6 ms | 23.2 ms |
| llama.cpp Q4 | 8 | 32 | 114.0 | 993.5 ms | 56.4 ms |

Each row is one measured pass. vLLM was 1.48x faster at concurrency 1 and 2.44x faster at concurrency 8. All requests succeeded. MTP acceptance was 42%-49% for vLLM and about 43% for llama.cpp.

llama.cpp generated 1,002 of 1,024 requested tokens at concurrency 1 and 4,062 of 4,096 at concurrency 8 despite `ignore_eos` being requested; throughput uses the actual output token counts. An unrelated idle process retained 33GB of GPU memory during these runs.

The two client result sets should not be compared directly because they use different endpoints and output behavior.
