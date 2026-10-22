#!/bin/sh
set -eu
umask 077

# Same PASS/FAIL convention as ../../scripts/basic_security_scan.sh.
# Run from the Cloudflare vLLM directory; four small inference requests use the GPU.
env_file="${1:-.env}"
model="${2:-unsloth/Qwen3.8-27B-NVFP4}"
case "$env_file" in
    /*) ;;
    *) env_file="./$env_file" ;;
esac
. "$env_file"
: "${SERVER_NAME:?Set SERVER_NAME in the environment file}"
: "${LLM_API_KEY:?Set LLM_API_KEY in the environment file}"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for dependency in curl jq openssl timeout; do
    command -v "$dependency" >/dev/null 2>&1 || fail "$dependency is required"
done
case "$SERVER_NAME" in
    *[!a-zA-Z0-9.-]*|'') fail "SERVER_NAME must be a hostname without a scheme, port, or path" ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
trap 'exit 1' HUP INT TERM
# Keep the API key out of curl's command-line arguments and test output.
printf 'Authorization: Bearer %s\n' "$LLM_API_KEY" > "$tmp_dir/auth"
for secret in "$LLM_API_KEY" "${CLOUDFLARE_TUNNEL_TOKEN:-}"; do
    [ -z "$secret" ] || printf '%s\n' "$secret" >> "$tmp_dir/secrets"
done

check_response() {
    if grep -Fq -f "$tmp_dir/secrets" "$tmp_dir/headers" "$tmp_dir/body"; then
        fail "response contains a configured API key"
    fi
    if grep -Eiq 'nginx/[0-9]|http://(vllm|nginx)(:|/)|Traceback \(most recent call last\)' \
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
    request GET /v1/models "$auth"
    [ "$code" = 401 ] || fail "$auth key on models: expected 401, got $code"
    request POST /v1/chat/completions "$auth" -H 'Content-Type: application/json' -d "$chat"
    [ "$code" = 401 ] || fail "$auth key on chat: expected 401, got $code"
    request POST /v1/responses "$auth" -H 'Content-Type: application/json' -d "$responses"
    [ "$code" = 401 ] || fail "$auth key on responses: expected 401, got $code"
done
pass "model discovery, chat, and responses reject missing and invalid keys"

for path in / /ui /docs /openapi.json /metrics /health /version /v1/model/info /v1/embeddings /v1/responses/security-scan-invalid-id; do
    request GET "$path" valid
    [ "$code" = 403 ] || fail "$path must be blocked even with a valid key, got $code"
done
# Invalid JSON prevents a state-changing operation if a route is accidentally forwarded.
request POST /v1/responses/security-scan-invalid-id/cancel valid -H 'Content-Type: application/json' -d '{'
[ "$code" = 403 ] || fail "response cancellation must be blocked, got $code"
pass "public UI, docs, metrics, health, and unapproved routes are blocked"

request POST /v1/models valid -H 'Content-Type: application/json' -d '{}'
[ "$code" = 403 ] || fail "POST /v1/models must be blocked, got $code"
for path in /v1/chat/completions /v1/responses; do
    request GET "$path" valid
    [ "$code" = 403 ] || fail "GET $path must be blocked, got $code"
done
pass "unapproved HTTP methods are blocked"

request GET /v1/models valid
[ "$code" = 200 ] || fail "authenticated model discovery: expected 200, got $code"
jq -e --arg model "$model" '.object == "list" and any(.data[]; .id == $model)' "$tmp_dir/body" >/dev/null || \
    fail "selected model is absent from authenticated discovery: $model"
pass "API key can discover the selected model"

request POST /v1/chat/completions valid -H 'Content-Type: application/json' -d "$chat"
[ "$code" = 200 ] || fail "authenticated inference: expected 200, got $code (check local vLLM logs)"
jq -e '.object == "chat.completion" and (.choices | length > 0) and
    any([.choices[0].message.content, .choices[0].message.reasoning_content][]; type == "string" and length > 0) and
    .usage.prompt_tokens > 0 and .usage.completion_tokens > 0 and
    .usage.total_tokens == (.usage.prompt_tokens + .usage.completion_tokens)' "$tmp_dir/body" >/dev/null || \
    fail "inference must return generated content and consistent nonzero token usage"
pass "authenticated inference returns content and token usage"

stream="$(printf '%s' "$chat" | jq -c '. + {stream:true,stream_options:{include_usage:true}}')"
request POST /v1/chat/completions valid -H 'Content-Type: application/json' -d "$stream"
[ "$code" = 200 ] || fail "streaming inference: expected 200, got $code (check local vLLM logs)"
grep -Eiq '^content-type: text/event-stream' "$tmp_dir/headers" || fail "stream is not text/event-stream"
tr -d '\r' < "$tmp_dir/body" > "$tmp_dir/stream"
grep -qx 'data: \[DONE\]' "$tmp_dir/stream" || fail "stream did not finish with [DONE]"
sed -n 's/^data: //p' "$tmp_dir/stream" | sed '/^\[DONE\]$/d' > "$tmp_dir/chunks"
jq -se 'any(.[]; .object == "chat.completion.chunk" and
    any(.choices[]?; any([.delta.content, .delta.reasoning_content][]; type == "string" and length > 0))) and
    any(.[]; .usage.prompt_tokens > 0 and .usage.completion_tokens > 0 and
        .usage.total_tokens == (.usage.prompt_tokens + .usage.completion_tokens))' "$tmp_dir/chunks" >/dev/null || \
    fail "stream must contain generated content and consistent nonzero token usage"
pass "authenticated streaming returns content, final usage, and [DONE]"

request POST /v1/responses valid -H 'Content-Type: application/json' -d "$responses"
[ "$code" = 200 ] || fail "Responses inference: expected 200, got $code (check local vLLM logs)"
jq -e '.object == "response" and .status == "completed" and
    any(.output[]?.content[]?; .type == "output_text" and (.text | type == "string" and length > 0)) and
    .usage.input_tokens > 0 and .usage.output_tokens > 0 and
    .usage.total_tokens == (.usage.input_tokens + .usage.output_tokens)' "$tmp_dir/body" >/dev/null || \
    fail "Responses inference must return generated text and consistent nonzero token usage"
pass "authenticated Responses inference returns text and token usage"

stream="$(printf '%s' "$responses" | jq -c '. + {stream:true}')"
request POST /v1/responses valid -H 'Content-Type: application/json' -d "$stream"
[ "$code" = 200 ] || fail "Responses streaming: expected 200, got $code (check local vLLM logs)"
grep -Eiq '^content-type: text/event-stream' "$tmp_dir/headers" || fail "Responses stream is not text/event-stream"
tr -d '\r' < "$tmp_dir/body" > "$tmp_dir/stream"
sed -n 's/^data: //p' "$tmp_dir/stream" | sed '/^\[DONE\]$/d' > "$tmp_dir/chunks"
jq -se 'any(.[]; .type == "response.output_text.delta" and (.delta | type == "string" and length > 0)) and
    any(.[]; .type == "response.completed" and .response.status == "completed" and
        .response.usage.input_tokens > 0 and .response.usage.output_tokens > 0 and
        .response.usage.total_tokens == (.response.usage.input_tokens + .response.usage.output_tokens))' "$tmp_dir/chunks" >/dev/null || \
    fail "Responses stream must contain generated text and a completed event with consistent token usage"
pass "authenticated Responses streaming returns text and final token usage"
pass "basic vLLM public security scan completed (host firewall requires separate checks)"
