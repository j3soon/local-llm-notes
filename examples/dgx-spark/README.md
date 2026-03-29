# DGX Spark Local llama.cpp

Runs `llama.cpp` behind NGINX with a static Bearer token and a Let's Encrypt certificate.

## Setup

```sh
cd examples/dgx-spark
mkdir -p ../../models state/letsencrypt state/www
./scripts/gen_env.sh
cat .env
docker compose up -d
```

Requirements:

- `SERVER_NAME` in `.env` must resolve to this host.
- Port `80` and `37000` must be reachable from the public internet for the ACME challenge and API access.
- After Certbot gets the first certificate, run `docker compose restart nginx` once so NGINX switches from HTTP bootstrap mode to HTTPS mode.

## Test

```sh
LLM_API_KEY='<value from .env>'
curl https://$SERVER_NAME:37000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{
    "messages": [
      {"role": "user", "content": "Hello"}
    ]
  }'
```

## Security Scan

```sh
SERVER_NAME='<value from .env>'
LLM_API_KEY='<value from .env>'
./scripts/security_scan.sh "$SERVER_NAME" "$LLM_API_KEY"
```

`llm` is private on the Compose network. NGINX is the only published port.

Remote clients can access only `/v1/chat/completions`. Full access remains available from localhost.

Edit [`compose.yaml`](./compose.yaml) if you want a different model or API port. Edit [`nginx-http01.conf`](./nginx-http01.conf) and [`nginx-tls.conf`](./nginx-tls.conf) if you want to change the proxy behavior.
