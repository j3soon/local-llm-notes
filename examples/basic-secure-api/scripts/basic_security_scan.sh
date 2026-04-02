#!/bin/sh
set -eu

host="${1:-}"
api_key="${2:-}"

if [ -z "$host" ] || [ -z "$api_key" ]; then
    echo "usage: $0 <server_name> <api_key>" >&2
    exit 1
fi

pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

http_status() {
    url="$1"
    shift
    curl -sS -o /dev/null -w '%{http_code}' "$@" "$url"
}

check_no_api_key() {
    code="$(http_status "https://$host:37000/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"Hello"}]}')"
    [ "$code" = "401" ] || fail "missing API key should return 401, got $code"
    pass "missing API key is rejected"
}

check_wrong_api_key() {
    code="$(http_status "https://$host:37000/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -H 'Authorization: Bearer sk-wrong-key' \
        -d '{"messages":[{"role":"user","content":"Hello"}]}')"
    [ "$code" = "401" ] || fail "wrong API key should return 401, got $code"
    pass "wrong API key is rejected"
}

check_http_redirect() {
    code="$(http_status "http://$host/v1/chat/completions")"
    [ "$code" = "301" ] || fail "plain HTTP should redirect, got $code"
    pass "plain HTTP is not serving the API directly"
}

check_tls_protocol() {
    if echo | openssl s_client -connect "$host:37000" -tls1 >/dev/null 2>&1; then
        fail "TLS 1.0 is enabled"
    fi
    if echo | openssl s_client -connect "$host:37000" -tls1_1 >/dev/null 2>&1; then
        fail "TLS 1.1 is enabled"
    fi
    pass "TLS 1.0/1.1 are disabled"
}

check_cert_valid() {
    cert_text="$(echo | openssl s_client -connect "$host:37000" -servername "$host" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null)" || \
        fail "unable to read certificate"
    echo "$cert_text" | grep -q "notAfter=" || fail "certificate missing expiry"
    echo "$cert_text" | grep -q "notBefore=" || fail "certificate missing validity start"
    if ! echo | openssl s_client -connect "$host:37000" -servername "$host" -verify_hostname "$host" >/dev/null 2>&1; then
        fail "certificate hostname validation failed"
    fi
    pass "certificate is present and valid for hostname"
}

check_internal_urls_blocked() {
    code_root="$(http_status "https://$host:37000/")"
    [ "$code_root" = "403" ] || fail "remote / should be blocked with 403, got $code_root"

    code_models="$(http_status "https://$host:37000/v1/models")"
    [ "$code_models" = "403" ] || fail "remote /v1/models should be blocked with 403, got $code_models"

    code_api="$(http_status "https://$host:37000/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $api_key" \
        -d '{"messages":[{"role":"user","content":"Hello"}]}')"
    [ "$code_api" != "403" ] || fail "/v1/chat/completions should not be blocked"
    [ "$code_api" != "401" ] || fail "/v1/chat/completions rejected the provided API key"
    pass "internal URLs are blocked while chat completions remains reachable"
}

check_sensitive_response_data() {
    headers_file="$(mktemp)"
    body_file="$(mktemp)"
    trap 'rm -f "$headers_file" "$body_file"' EXIT INT TERM

    curl -sS -D "$headers_file" -o "$body_file" \
        "https://$host:37000/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"Hello"}]}' >/dev/null

    server_line="$(grep -Ei '^Server: .*nginx/[0-9]' "$headers_file" || true)"
    if [ -n "$server_line" ]; then
        fail "response exposes nginx version: $server_line"
    fi

    sensitive_line="$(grep -Ein '(llm:37000|/etc/letsencrypt|/var/www/certbot|local-llm-|docker|nginx/[0-9])' "$headers_file" "$body_file" | head -n 1 || true)"
    if [ -n "$sensitive_line" ]; then
        fail "response exposes internal detail: $sensitive_line"
    fi

    rm -f "$headers_file" "$body_file"
    trap - EXIT INT TERM
    pass "responses do not expose obvious internal details"
}

check_no_api_key
check_wrong_api_key
check_http_redirect
check_tls_protocol
check_cert_valid
check_internal_urls_blocked
check_sensitive_response_data
