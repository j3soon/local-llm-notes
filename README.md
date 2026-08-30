# llama.cpp Notes

Minimal steps to run [llama.cpp](https://github.com/ggml-org/llama.cpp) in docker on NVIDIA GPUs.

## Pull the docker image

Follow the [official docker instructions](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md):

```sh
# docker pull ghcr.io/ggml-org/llama.cpp:full-cuda
# docker pull ghcr.io/ggml-org/llama.cpp:light-cuda
docker pull ghcr.io/ggml-org/llama.cpp:server-cuda
```

## Models

### GPT-OSS

Follow the official instructions in the [discussion](https://github.com/ggml-org/llama.cpp/discussions/15396), the models will be downloaded under `./.cache/huggingface`:

```sh
# llama-server -hf ggml-org/gpt-oss-20b-GGUF  --ctx-size 0 --jinja -ub 2048 -b 2048
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf ggml-org/gpt-oss-20b-GGUF \
    --ctx-size 0 --jinja -ub 2048 -b 2048
```

or

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf ggml-org/gpt-oss-120b-GGUF \
    --ctx-size 0 --jinja -ub 2048 -b 2048
```

As mentioned in the discussion, the `gpt‑oss 20B` will take up to 18GB VRAM without offloading, while `gpt‑oss 120B` will take up to 69GB VRAM without offloading.

> Following the [Unsloth docs](https://unsloth.ai/docs/models/gpt-oss-how-to-run-and-fine-tune#run-gpt-oss-120b) will cause the llama.cpp webpage to hang when ran on DGX Spark. I didn't have time to investigate further.

### Nemotron-3

Follow the official instructions in the [DGX Spark guide](https://build.nvidia.com/spark/nemotron/instructions) and [Unsloth docs](https://unsloth.ai/docs/models/tutorials/nemotron-3), the Nemotron-3 Nano model will be downloaded under `./.cache/huggingface`:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Nemotron-3-Nano-30B-A3B-GGUF:UD-Q4_K_XL \
    --host 0.0.0.0 \
    --port 30000 \
    --n-gpu-layers 99 \
    --ctx-size 8192 \
    --threads 8 \
    --jinja
```

As mentioned in the Unsloth docs, the `Nemotron-3-Nano-30B-A3B-GGUF` model will take up to 24GB VRAM without offloading.

Follow the [Unsloth docs](https://unsloth.ai/docs/models/nemotron-3/nemotron-3-super) for the Nemotron 3 Super model:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF:UD-Q4_K_XL \
    --host 0.0.0.0 \
    --port 30000 \
    --ctx-size 16384 \
    --temp 1.0 --top-p 1.0 \
    --jinja
```

As mentioned in the Unsloth docs, the `NVIDIA-Nemotron-3-Super-120B-A12B-GGUF` model will take up to 64GB-72GB VRAM without offloading.

### Nemotron 3 Nano Omni

Follow the [Unsloth docs](https://unsloth.ai/docs/models/nemotron-3-nano-omni) for the Nemotron 3 Nano Omni model:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF:UD-Q4_K_XL \
    --host 0.0.0.0 \
    --port 30000 \
    --prio 3 \
    --temp 1.0 \
    --top-p 1.0 \
    --jinja
```

As mentioned in the Unsloth docs, the `NVIDIA-Nemotron-3-Nano-Omni-30B-A3B-Reasoning-GGUF` model will take up to ~25GB VRAM without offloading.

### Qwen3.5

Follow the [Unsloth docs](https://unsloth.ai/docs/models/qwen3.5#qwen3.5-35b-a3b):

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3.5-35B-A3B-GGUF:MXFP4_MOE \
    --ctx-size 16384 \
    --temp 0.6 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.00 \
    --jinja
```

As mentioned in the Unsloth docs, the `Qwen3.5-35B-A3B-GGUF` model will take up to 24GB VRAM without offloading.

Follow the [Unsloth docs](https://unsloth.ai/docs/models/qwen3.5#qwen3.5-122b-a10b):

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3.5-122B-A10B-GGUF:UD-Q4_K_XL \
    --temp 0.6 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.00 \
    --jinja
```

As mentioned in the Unsloth docs, the `Qwen3.5-122B-A10B-GGUF` model will take up to 70GB VRAM without offloading.

For MTP, follow [Unsloth MTP guide](https://huggingface.co/unsloth/Qwen3.5-122B-A10B-MTP-GGUF):

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3.5-122B-A10B-MTP-GGUF:UD-Q4_K_XL \
    --temp 0.6 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.00 \
    --spec-type draft-mtp --spec-draft-n-max 6 \
    --jinja
```

### Qwen3.8

Follow the [Unsloth docs](https://unsloth.ai/docs/models/qwen3.8#run-qwen3.8-in-llama.cpp) for the Qwen3.8 27B model:

The Q4 and BF16 examples below use the thinking-mode settings with medium reasoning effort and enable MTP as described in the [Unsloth MTP guide](https://unsloth.ai/docs/models/mtp).

#### Q4

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL \
    --ctx-size 16384 \
    --temp 1.0 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.0 \
    --chat-template-kwargs '{"reasoning_effort":"medium"}' \
    --spec-type draft-mtp \
    --spec-draft-n-max 2 \
    --jinja
```

As mentioned in the Unsloth docs, the 4-bit `Qwen3.8-27B-GGUF` model requires 17GB-19GB total RAM and VRAM.

#### BF16

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3.8-27B-GGUF \
    --hf-file BF16/Qwen3.8-27B-BF16-00001-of-00002.gguf \
    --ctx-size 16384 \
    --temp 1.0 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.0 \
    --chat-template-kwargs '{"reasoning_effort":"medium"}' \
    --spec-type draft-mtp \
    --spec-draft-n-max 2 \
    --jinja
```

The BF16 model files are about 55GB, and the Unsloth docs list a 56GB total RAM and VRAM requirement. Leave additional memory available for runtime overhead and the KV cache.

The regular Qwen3.8 GGUF includes MTP support, so a separate MTP model repository is not required. Unsloth recommends starting with `--spec-draft-n-max 2`, then testing values from 1 through 6 to find the fastest setting for the hardware. MTP requires about 2GB of additional RAM or VRAM.

#### NVFP4 (vLLM)

Follow the [Unsloth NVFP4 instructions](https://unsloth.ai/docs/models/qwen3.8#nvfp4). NVFP4 requires an NVIDIA Blackwell GPU.

```sh
docker run --rm -it --gpus all --ipc=host \
  -p 8000:8000 \
  -v ./.cache:/root/.cache \
  vllm/vllm-openai:latest \
    unsloth/Qwen3.8-27B-NVFP4 \
    --speculative-config '{"method":"mtp","num_speculative_tokens":2}'
```

The NVFP4 repository includes the MTP weights, so a separate draft model is not required. Follow the [Open WebUI](#open-webui) section to test the model in a web GUI.

For Jetson devices, refer to [Qwen3.8 27B on Jetson AI Labs](https://www.jetson-ai-lab.com/models/qwen3-8-27b/).

### Qwen3-VL

Follow the [Unsloth docs](https://unsloth.ai/docs/models/qwen3-how-to-run-and-fine-tune/qwen3-vl-how-to-run-and-fine-tune):

Instruct:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3-VL-8B-Instruct-GGUF:UD-Q4_K_XL \
    --n-gpu-layers 99 \
    --jinja \
    --top-p 0.8 \
    --top-k 20 \
    --temp 0.7 \
    --min-p 0.0 \
    --flash-attn on \
    --presence-penalty 1.5 \
    --ctx-size 8192
```

Thinking:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3-VL-8B-Thinking-GGUF:UD-Q4_K_XL \
    --n-gpu-layers 99 \
    --jinja \
    --top-p 0.8 \
    --top-k 20 \
    --temp 0.7 \
    --min-p 0.0 \
    --flash-attn on \
    --presence-penalty 1.5 \
    --ctx-size 8192
```

Above seems to run well on 24GB VRAM.

## Open WebUI

Follow the [Open WebUI quick start](https://docs.openwebui.com/getting-started/quick-start/). This connects to an OpenAI-compatible server listening on host port 8000:

```sh
docker run -d \
  --network=host \
  -e PORT=3000 \
  -e WEBUI_AUTH=False \
  -e OPENAI_API_BASE_URL=http://127.0.0.1:8000/v1 \
  -e OPENAI_API_KEY=none \
  -e DEFAULT_MODEL_METADATA='{"capabilities":{"builtin_tools":false}}' \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

Open <http://localhost:3000>. Authentication is disabled, so only expose the port behind a trusted firewall. Built-in tools are disabled by default because vLLM requires additional tool-calling flags to accept them.

## Live Evals / Benchmarks

Run one backend at a time using the Qwen3.8 commands above. The recorded vLLM runs added the optional `--gpu-memory-utilization 0.55` to leave VRAM for other workloads. For llama.cpp, add `--port 8000 --alias qwen38-q4 --parallel 8 --n-gpu-layers all --flash-attn on --metrics`.

### NVIDIA Dynamo AIPerf

Use the official NVIDIA Dynamo [AIPerf](https://github.com/ai-dynamo/aiperf) container:

```sh
docker run --rm --network=host \
  -v ./.cache:/app/.cache \
  --entrypoint aiperf \
  nvcr.io/nvidia/ai-dynamo/aiperf:0.11.0 \
    profile \
    --model unsloth/Qwen3.8-27B-NVFP4 \
    --tokenizer unsloth/Qwen3.8-27B-NVFP4 \
    --url http://127.0.0.1:8000 \
    --endpoint-type chat \
    --streaming \
    --use-legacy-max-tokens \
    --synthetic-input-tokens-mean 1024 \
    --synthetic-input-tokens-stddev 0 \
    --output-tokens-mean 128 \
    --output-tokens-stddev 0 \
    --extra-inputs '{"min_tokens":128,"ignore_eos":true,"temperature":0,"chat_template_kwargs":{"reasoning_effort":"medium"}}' \
    --concurrency 8 \
    --request-count 32 \
    --warmup-request-count 2 \
    --num-dataset-entries 32 \
    --random-seed 42 \
    --no-server-metrics \
    --no-gpu-telemetry \
    --ui none
```

For llama.cpp, change `--model` to `qwen38-q4`. For concurrency 1, use `--concurrency 1 --request-count 8`.

### vLLM bench serve

Use the vLLM container as the benchmark client:

```sh
docker run --rm --network=host \
  -v ./.cache:/root/.cache \
  --entrypoint vllm \
  vllm/vllm-openai:latest \
    bench serve \
    --backend openai \
    --base-url http://127.0.0.1:8000 \
    --model unsloth/Qwen3.8-27B-NVFP4 \
    --dataset-name random \
    --random-input-len 1024 \
    --random-output-len 128 \
    --random-range-ratio 0 \
    --num-prompts 32 \
    --num-warmups 2 \
    --max-concurrency 8 \
    --request-rate inf \
    --ignore-eos \
    --seed 42
```

For llama.cpp, add `--served-model-name qwen38-q4`. For concurrency 1, use `--num-prompts 8 --max-concurrency 1`. See the [measured results](PERFORMANCE.md).

- [Next.js Evals](https://nextjs.org/evals)
- [OpenHands Index](https://index.openhands.dev/home)
- [Artificial Analysis Coding Agents](https://artificialanalysis.ai/agents/coding-agents)
- [SWE-bench](https://www.swebench.com/)
- [SWE-bench Pro](https://labs.scale.com/leaderboard/swe_bench_pro_public)
- [AI Model Usage Rankings | OpenCode Data](https://opencode.ai/data)
- [InferenceX](https://inferencex.semianalysis.com/inference)

## Appendix

### DGX Spark Support

Build the docker image:

```sh
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
# There is no official pre-built llama.cpp:server-cuda image arm64 yet, so we need to build it ourselves.
# Ref: https://forums.developer.nvidia.com/t/building-llama-cpp-container-images-for-spark-gb10/353664/2
# Ref: https://gist.github.com/stelterlab/33885c600c102792acb1638ca7d2d7e9
wget -O .devops/cuda.Dockerfile https://gist.githubusercontent.com/stelterlab/33885c600c102792acb1638ca7d2d7e9/raw/6bdfd57e27ceb96f8c7c697b202ad5d5e3c32241/spark.Dockerfile
docker build -t j3soon/llama.cpp:server-cuda-spark --target server -f .devops/cuda.Dockerfile .
```

or pull a pre-built image:

```sh
docker pull j3soon/llama.cpp:server-cuda-spark
```

and change the image to `j3soon/llama.cpp:server-cuda-spark` in the above commands.

### API (Insecure)

Local API:

```sh
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

with API key:

Take port `37000` and Nemotron 3 Super on a DGX Spark as an example:

```sh
export API_KEY="sk-$(openssl rand -base64 36 | tr -dc 'a-zA-Z0-9' | head -c 48)"
echo "API_KEY: $API_KEY"
docker run --rm -it --gpus all --network=host \
  -v ./.cache:/root/.cache \
  j3soon/llama.cpp:server-cuda-spark \
    -hf unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF:UD-Q4_K_XL \
    --ctx-size 0 --jinja -ub 2048 -b 2048 \
    --api-key "$API_KEY" \
    --port 30000
```

and then:

```sh
IP=<IP_ADDRESS_OF_DGX_SPARK>
API_KEY="<API_KEY_FROM_ABOVE>"
curl http://$IP:30000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

### API (with Authentication and HTTPS)

See [`examples/basic-secure-api`](./examples/basic-secure-api) for Docker Compose examples with NGINX, HTTPS, API-key enforcement, and Cloudflare Tunnel support for both llama.cpp and vLLM. For llama.cpp, set `LLAMA_CPP_IMAGE` for your platform.
