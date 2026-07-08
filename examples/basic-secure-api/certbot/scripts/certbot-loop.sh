#!/bin/sh
set -eu

if [ -z "${SERVER_NAME:-}" ]; then
    echo "SERVER_NAME is required" >&2
    exit 1
fi

if [ -z "${LETSENCRYPT_EMAIL:-}" ]; then
    echo "LETSENCRYPT_EMAIL is required" >&2
    exit 1
fi

staging_args=""
if [ "${LETSENCRYPT_STAGING:-0}" = "1" ]; then
    staging_args="--staging"
fi

while true; do
    if [ ! -s "/etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem" ]; then
        certbot certonly \
            --webroot \
            --webroot-path /var/www/certbot \
            --non-interactive \
            --agree-tos \
            --email "${LETSENCRYPT_EMAIL}" \
            --domain "${SERVER_NAME}" \
            --keep-until-expiring \
            ${staging_args} || true
    else
        certbot renew \
            --webroot \
            --webroot-path /var/www/certbot \
            --non-interactive \
            ${staging_args} || true
    fi

    sleep 12h
done
