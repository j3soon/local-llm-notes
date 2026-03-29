# DGX Spark Local llama.cpp

Runs `llama.cpp` only, bound to `127.0.0.1` for local access.

## Setup

```sh
cd examples/dgx-spark
mkdir -p ../../models
docker compose up -d
```

## Test

```sh
curl http://127.0.0.1:37000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

Edit [`compose.yaml`](/workspace/examples/dgx-spark/compose.yaml) directly if you want a different model, port, or llama.cpp flags.
