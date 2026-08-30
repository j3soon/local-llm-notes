#!/bin/sh
set -eu

: "${LLM_API_KEY:?LLM_API_KEY is required}"
: "${LLM_UPSTREAM:?LLM_UPSTREAM is required}"

envsubst '${LLM_API_KEY} ${LLM_UPSTREAM}' < /opt/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec nginx -g 'daemon off;'
