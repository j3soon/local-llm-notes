#!/bin/sh
set -eu
umask 077

# Same PASS/FAIL convention as ../../../scripts/basic_security_scan.sh.
# Run from the LiteLLM directory; two small inference requests may incur charges.
env_file="${1:-.env}"
model="${2:-azure/gpt-6-luna}"
case "$env_file" in
    /*) ;;
    *) env_file="./$env_file" ;;
esac
. "$env_file"
: "${SERVER_NAME:?Set SERVER_NAME in the environment file}"
: "${APP_API_KEY:?Set and register APP_API_KEY first}"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for dependency in curl jq openssl timeout; do
    command -v "$dependency" >/dev/null 2>&1 || fail "$dependency is required"
done
case "$SERVER_NAME" in
    *[!a-zA-Z0-9.-]*|'') fail "SERVER_NAME must be a hostname without a scheme, port, or path" ;;
esac
[ "$APP_API_KEY" != "${LITELLM_MASTER_KEY:-}" ] || fail "use an application key, not the master key"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
trap 'exit 1' HUP INT TERM
# Keep the application key out of curl's command-line arguments and test output.
printf 'Authorization: Bearer %s\n' "$APP_API_KEY" > "$tmp_dir/auth"
for secret in "$APP_API_KEY" "${LITELLM_MASTER_KEY:-}" "${OPENAI_API_KEY:-}" "${AZURE_API_KEY:-}" "${VLLM_API_KEY:-}" \
    "${VLLM_API_KEY_SECONDARY:-}"; do
    [ -z "$secret" ] || printf '%s\n' "$secret" >> "$tmp_dir/secrets"
done

check_response() {
    if grep -Fq -f "$tmp_dir/secrets" "$tmp_dir/headers" "$tmp_dir/body"; then
        fail "response contains a configured API key"
    fi
    if grep -Eiq 'nginx/[0-9]|postgresql://|http://(litellm|db|nginx)(:|/)|Traceback \(most recent call last\)' \
        "$tmp_dir/headers" "$tmp_dir/body"; then
        fail "response exposes obvious internal details"
    fi
}

request() {
    method="$1" path="$2" auth="$3"
    shift 3
    set -- --request "$method" "$@"
    case "$auth" in
        valid) set -- "$@" -H "@$tmp_dir/auth" ;;
        invalid) set -- "$@" -H 'Authorization: Bearer sk-invalid-security-scan-key' ;;
    esac
    code="$(curl -sS -N --connect-timeout 10 --max-time 180 \
        -D "$tmp_dir/headers" -o "$tmp_dir/body" -w '%{http_code}' \
        "$@" "https://$SERVER_NAME$path")" || fail "request failed: $method $path"
    check_response
}

check_http_denied() {
    # Never send credentials over HTTP, and never follow redirects with them.
    result="$(curl -sS --connect-timeout 10 --max-time 20 -o /dev/null \
        -w '%{http_code} %{redirect_url}' "http://$SERVER_NAME/v1/models")" || fail "HTTP probe failed"
    case "$result" in
        '403 '*) pass "plain HTTP is denied" ;;
        301\ https://"$SERVER_NAME"/*|302\ https://"$SERVER_NAME"/*|307\ https://"$SERVER_NAME"/*|308\ https://"$SERVER_NAME"/*)
            pass "plain HTTP redirects to HTTPS on the same host" ;;
        *) fail "plain HTTP must be denied or redirected to HTTPS; enable Cloudflare Always Use HTTPS" ;;
    esac
}

check_tls() {
    timeout 20 openssl s_client -connect "$SERVER_NAME:443" -servername "$SERVER_NAME" \
        -verify_hostname "$SERVER_NAME" -verify_return_error -brief </dev/null > "$tmp_dir/tls" 2>&1 || \
        fail "TLS certificate or hostname verification failed"
    for protocol in tls1 tls1_1; do
        if timeout 20 openssl s_client -connect "$SERVER_NAME:443" -servername "$SERVER_NAME" \
            -"$protocol" -cipher 'DEFAULT:@SECLEVEL=0' -brief </dev/null > "$tmp_dir/tls" 2>&1; then
            fail "$protocol is enabled; set Cloudflare Minimum TLS Version to TLS 1.2"
        else
            status="$?"
            [ "$status" != 124 ] || fail "$protocol probe timed out; cannot verify rejection"
            if grep -Eiq 'no protocols available|no ciphers available|unknown option|unrecognized option|Connection refused|Name or service not known' "$tmp_dir/tls"; then
                fail "$protocol probe could not test the server"
            fi
        fi
    done
    pass "trusted hostname certificate and TLS 1.0/1.1 rejection"
}

chat="$(jq -nc --arg model "$model" '{model:$model,messages:[{role:"user",content:"Reply with OK."}],max_completion_tokens:128}')"
responses="$(jq -nc --arg model "$model" '{model:$model,input:"Reply with OK.",max_output_tokens:128}')"

check_http_denied
check_tls

for auth in missing invalid; do
    for path in /v1/models /v1/model/info; do
        request GET "$path" "$auth"
        [ "$code" = 401 ] || fail "$auth key on $path: expected 401, got $code"
    done
    request POST /v1/chat/completions "$auth" -H 'Content-Type: application/json' -d "$chat"
    [ "$code" = 401 ] || fail "$auth key on chat: expected 401, got $code"
    request POST /v1/responses "$auth" -H 'Content-Type: application/json' -d "$responses"
    [ "$code" = 401 ] || fail "$auth key on responses: expected 401, got $code"
done
pass "model discovery, metadata, chat, and responses reject missing and invalid keys"

for path in / /ui /ui/ /login /docs /openapi.json /model/info /v2/model/info /key/list /spend/logs/v2 /health/readiness /v1/embeddings; do
    request GET "$path" valid
    [ "$code" = 403 ] || fail "$path must be blocked even with a valid key, got $code"
done
for path in /key/generate /key/update; do
    # Invalid JSON prevents key creation/updates if the gateway forwards this.
    request POST "$path" valid -H 'Content-Type: application/json' -d '{'
    [ "$code" = 403 ] || fail "$path must be blocked, got $code"
done
pass "public UI, docs, management, spend logs, and unapproved routes are blocked"

for path in /v1/models /v1/model/info; do
    request POST "$path" valid -H 'Content-Type: application/json' -d '{}'
    [ "$code" = 403 ] || fail "POST $path must be blocked, got $code"
done
for path in /v1/chat/completions /v1/responses; do
    request GET "$path" valid
    [ "$code" = 403 ] || fail "GET $path must be blocked, got $code"
done
pass "unapproved HTTP methods are blocked"

request GET /v1/models valid
[ "$code" = 200 ] || fail "authenticated model discovery: expected 200, got $code"
jq -e --arg model "$model" '.object == "list" and any(.data[]; .id == $model)' "$tmp_dir/body" >/dev/null || \
    fail "selected model is absent from authenticated discovery: $model"
pass "application key can discover the selected model"

request GET /v1/model/info valid
[ "$code" = 200 ] || fail "authenticated model metadata: expected 200, got $code"
jq -e --arg model "$model" 'any(.data[]; .model_name == $model and (.model_info | type == "object"))' "$tmp_dir/body" >/dev/null || \
    fail "selected model is absent from authenticated metadata: $model"
pass "application key can read model metadata without exposed API keys"

request POST /v1/chat/completions valid -H 'Content-Type: application/json' -d "$chat"
[ "$code" = 200 ] || fail "authenticated inference: expected 200, got $code (check local proxy logs)"
jq -e '.object == "chat.completion" and (.choices | length > 0) and
    any([.choices[0].message.content, .choices[0].message.reasoning_content][]; type == "string" and length > 0) and
    .usage.prompt_tokens > 0 and .usage.completion_tokens > 0 and
    .usage.total_tokens == (.usage.prompt_tokens + .usage.completion_tokens)' "$tmp_dir/body" >/dev/null || \
    fail "inference must return generated content and consistent nonzero token usage"
pass "authenticated inference returns content and token usage"

stream="$(printf '%s' "$chat" | jq -c '. + {stream:true,stream_options:{include_usage:true}}')"
request POST /v1/chat/completions valid -H 'Content-Type: application/json' -d "$stream"
[ "$code" = 200 ] || fail "streaming inference: expected 200, got $code (check local proxy logs)"
grep -Eiq '^content-type: text/event-stream' "$tmp_dir/headers" || fail "stream is not text/event-stream"
tr -d '\r' < "$tmp_dir/body" > "$tmp_dir/stream"
grep -qx 'data: \[DONE\]' "$tmp_dir/stream" || fail "stream did not finish with [DONE]"
sed -n 's/^data: //p' "$tmp_dir/stream" | sed '/^\[DONE\]$/d' > "$tmp_dir/chunks"
jq -se 'any(.[]; .object == "chat.completion.chunk" and
    any(.choices[]?; any([.delta.content, .delta.reasoning_content][]; type == "string" and length > 0))) and
    any(.[]; .usage.prompt_tokens > 0 and .usage.completion_tokens > 0 and
        .usage.total_tokens == (.usage.prompt_tokens + .usage.completion_tokens) and
        (.usage.cost | type == "number" and . >= 0))' "$tmp_dir/chunks" >/dev/null || \
    fail "stream must contain generated content, consistent nonzero token usage, and numeric cost (zero is valid)"
pass "authenticated streaming returns content, final usage with cost, and [DONE]"
pass "basic public security scan completed (database cost persistence and host firewall require separate checks)"
