#!/bin/sh
set -eu

if [ -z "${LLM_API_KEY:-}" ]; then
    echo "LLM_API_KEY is required" >&2
    exit 1
fi

envsubst '${LLM_API_KEY}' < /opt/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec nginx -g 'daemon off;'
