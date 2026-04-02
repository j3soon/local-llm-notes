#!/bin/sh
set -eu

if [ -z "${SERVER_NAME:-}" ]; then
    echo "SERVER_NAME is required" >&2
    exit 1
fi

if [ -z "${LLM_API_KEY:-}" ]; then
    echo "LLM_API_KEY is required" >&2
    exit 1
fi

cert_dir="/etc/letsencrypt/live/${SERVER_NAME}"

if [ -s "${cert_dir}/fullchain.pem" ] && [ -s "${cert_dir}/privkey.pem" ]; then
    template="/opt/nginx/nginx-tls.conf.template"
else
    template="/opt/nginx/nginx-http01.conf.template"
fi

envsubst '${SERVER_NAME} ${LLM_API_KEY}' < "$template" > /etc/nginx/nginx.conf
exec nginx -g 'daemon off;'
