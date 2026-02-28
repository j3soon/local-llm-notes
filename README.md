# llama.cpp Notes

Minimal steps to run [llama.cpp](https://github.com/ggml-org/llama.cpp) in docker on NVIDIA GPUs.

## Pull the docker image

Follow the [official docker instructions](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md):

```sh
# docker pull ghcr.io/ggml-org/llama.cpp:full-cuda
# docker pull ghcr.io/ggml-org/llama.cpp:light-cuda
docker pull ghcr.io/ggml-org/llama.cpp:server-cuda
```

## GPT-OSS

Follow the official instructions in the [discussion](https://github.com/ggml-org/llama.cpp/discussions/15396), the models will be downloaded to the `./models` directory:

```sh
# llama-server -hf ggml-org/gpt-oss-20b-GGUF  --ctx-size 0 --jinja -ub 2048 -b 2048
docker run --rm -it --gpus all --network=host \
  -v ./models:/root/.cache/llama.cpp \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf ggml-org/gpt-oss-20b-GGUF \
    --ctx-size 0 --jinja -ub 2048 -b 2048
```

As mentioned in the discussion, the `gpt‑oss 20B` will take up to 18GB VRAM without offloading, while `gpt‑oss 120B` will take up to 69GB VRAM without offloading.

## Nemotron-3

Follow the official instructions in the [DGX Spark guide](https://build.nvidia.com/spark/nemotron/instructions) and [Unsloth docs](https://unsloth.ai/docs/models/tutorials/nemotron-3), the models will be downloaded to the `./models` directory:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./models:/root/.cache/llama.cpp \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Nemotron-3-Nano-30B-A3B-GGUF:UD-Q4_K_XL \
    --host 0.0.0.0 \
    --port 30000 \
    --n-gpu-layers 99 \
    --ctx-size 8192 \
    --threads 8
```

As mentioned in the Unsloth docs, the `Nemotron-3-Nano-30B-A3B-GGUF` model will take up to 24GB VRAM without offloading.

## Qwen3.5

Follow the [Unsloth docs](https://unsloth.ai/docs/models/qwen3.5#qwen3.5-35b-a3b):

```sh
docker run --rm -it --gpus all --network=host \
  -v ./models:/root/.cache/llama.cpp \
  ghcr.io/ggml-org/llama.cpp:server-cuda \
    -hf unsloth/Qwen3.5-35B-A3B-GGUF:MXFP4_MOE \
    --ctx-size 16384 \
    --temp 0.6 \
    --top-p 0.95 \
    --top-k 20 \
    --min-p 0.00
```

As mentioned in the Unsloth docs, the `Qwen3.5-35B-A3B-GGUF` model will take up to 24GB VRAM without offloading.

## Qwen3-VL

Follow the [Unsloth docs](https://unsloth.ai/docs/models/qwen3-how-to-run-and-fine-tune/qwen3-vl-how-to-run-and-fine-tune):

Instruct:

```sh
docker run --rm -it --gpus all --network=host \
  -v ./models:/root/.cache/llama.cpp \
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
  -v ./models:/root/.cache/llama.cpp \
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
