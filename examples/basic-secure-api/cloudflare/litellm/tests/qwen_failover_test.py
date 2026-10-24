#!/usr/bin/env python3
"""Validate Qwen load balancing, session affinity, failover, and recovery against mock upstreams.

Runs the real litellm-config.yaml with LiteLLM 1.106.2 and no database:

    python3 -m venv /tmp/litellm-venv
    /tmp/litellm-venv/bin/pip install 'litellm[proxy]==1.106.2'
    PATH="/tmp/litellm-venv/bin:$PATH" python3 tests/qwen_failover_test.py

Local mock servers stand in for both vLLM servers and Azure; no provider is
called. Takes about two minutes because recovery waits for 30-second probes.
"""
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "litellm-config.yaml"
MODEL = "unsloth/Qwen3.8-27B-NVFP4"
EXPECTED_VERSION = "1.106.2"
MASTER_KEY = f"sk-{secrets.token_hex(16)}"
requests_seen = []  # (server, path, authorization, body)


def passed(message):
    print(f"PASS: {message}", flush=True)


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Upstream:
    """OpenAI-compatible mock that can be stopped and restarted on one port."""

    def __init__(self, name):
        self.name, self.port, self.server = name, free_port(), None

    def start(self):
        name = self.name

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                requests_seen.append((name, self.path, self.headers.get("Authorization"), None))
                self._send({"object": "list", "data": []})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                requests_seen.append((name, self.path, self.headers.get("Authorization"), body))
                # Unique IDs: LiteLLM uses the response ID as the spend-log key.
                self._send({"id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion", "created": 1,
                            "model": body.get("model"),
                            "choices": [{"index": 0, "finish_reason": "stop",
                                         "message": {"role": "assistant", "content": "OK"}}],
                            "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}})

            def _send(self, payload):
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        ThreadingHTTPServer.allow_reuse_address = True
        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def call(base, path, body=None, headers=None):
    request = urllib.request.Request(base + path, json.dumps(body).encode() if body else None,
                                     {"Authorization": f"Bearer {MASTER_KEY}", "Content-Type": "application/json",
                                      **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.headers, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, error.headers, None
    except (urllib.error.URLError, ConnectionError):
        return 0, {}, None


def tally(base, count, session=None):
    served = Counter()
    for _ in range(count):
        status, headers, _ = call(base, "/v1/chat/completions",
                                  {"model": MODEL, "messages": [{"role": "user", "content": "hi"}]},
                                  {"x-session-id": session} if session else None)
        served[f"{status}:{headers.get('x-litellm-model-id')}"] += 1
    return served


def health(base):
    status, _, body = call(base, "/health")
    if status != 200 or "healthy_endpoints" not in (body or {}):
        return None
    return ({e.get("model_id") for e in body["healthy_endpoints"]},
            {e.get("model_id") for e in body["unhealthy_endpoints"]})


def check_qwen_metadata(base):
    # Mock /models returns no cards: limits must survive failed discovery.
    status, _, body = call(base, "/v1/model/info")
    if status != 200:
        fail(f"model info returned HTTP {status}")
    infos = {m["model_info"]["id"]: m["model_info"] for m in body["data"]}
    for model_id in ("qwen-primary", "qwen-secondary"):
        if model_id not in infos:
            fail(f"missing deployment metadata: {model_id}")
        info = infos[model_id]
        for field in ("max_tokens", "max_input_tokens", "max_output_tokens"):
            if info.get(field) != 262144:
                fail(f"{model_id} {field}: expected 262144, got {info.get(field)}")
        for field in ("supports_system_messages", "supports_parallel_function_calling", "supports_tool_choice",
                      "supports_prompt_caching", "supports_native_streaming", "supports_response_schema",
                      "supports_native_structured_output"):
            if info.get(field) is not True:
                fail(f"{model_id} {field}: expected true, got {info.get(field)}")
        if set(info.get("supported_endpoints") or []) != {"/v1/chat/completions", "/v1/responses"}:
            fail(f"unexpected {model_id} endpoints: {info.get('supported_endpoints')}")
    status, _, body = call(base, "/v1/models")
    if status != 200:
        fail(f"models returned HTTP {status}")
    model = next(m for m in body["data"] if m["id"] == MODEL)
    if any(model.get(f) != info[f] for f in ("max_input_tokens", "max_output_tokens")):
        fail("model list and deployment model info disagree on token limits")


def wait_for(description, predicate, timeout):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if predicate():
            return time.monotonic() - start
        time.sleep(0.5)
    fail(f"timed out after {timeout}s waiting for {description}")


def main():
    primary, secondary, azure = Upstream("primary"), Upstream("secondary"), Upstream("azure")
    for upstream in (primary, secondary, azure):
        upstream.start()
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    env = {k: v for k, v in os.environ.items() if k not in ("DATABASE_URL", "STORE_MODEL_IN_DB")} | {
        "LITELLM_MASTER_KEY": MASTER_KEY,
        "LITELLM_LOG": "WARNING",
        "AZURE_API_KEY": "azure-test-key",
        "AZURE_API_BASE": f"http://127.0.0.1:{azure.port}",
        "AZURE_API_VERSION": "v1",
        "VLLM_API_BASE": f"http://127.0.0.1:{primary.port}/v1",
        "VLLM_API_KEY": "primary-test-key",
        "VLLM_API_BASE_SECONDARY": f"http://127.0.0.1:{secondary.port}/v1",
        "VLLM_API_KEY_SECONDARY": "secondary-test-key",
    }
    with tempfile.TemporaryFile() as log:
        proxy = subprocess.Popen(["litellm", "--config", str(CONFIG), "--host", "127.0.0.1", "--port", str(port)],
                                 env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            run(base, primary, secondary)
        except SystemExit:
            log.seek(0)
            sys.stderr.write(log.read().decode(errors="replace")[-4000:])
            raise
        finally:
            proxy.terminate()
            proxy.wait(timeout=30)
    probed = {(server, auth) for server, path, auth, body in requests_seen if body and body.get("max_tokens")}
    if probed != {("primary", "Bearer primary-test-key"), ("secondary", "Bearer secondary-test-key")}:
        fail(f"unexpected health probes: {sorted(probed)}")
    if any(server == "azure" for server, *_ in requests_seen):
        fail("Azure received background requests")
    passed("probes used each server's own key and Azure received no requests")


def run(base, primary, secondary):
    def both_healthy():
        state = health(base)
        return state is not None and state == ({"qwen-primary", "qwen-secondary"}, set())

    wait_for("proxy startup", lambda: health(base) is not None, 120)
    wait_for("both deployments healthy", both_healthy, 60)
    check_qwen_metadata(base)
    passed("both deployments advertise shared limits and capabilities without upstream model discovery")
    _, headers, _ = call(base, "/v1/chat/completions", {"model": MODEL, "messages": [{"role": "user", "content": "hi"}]})
    if headers.get("x-litellm-version") != EXPECTED_VERSION:
        fail(f"expected LiteLLM {EXPECTED_VERSION}, got {headers.get('x-litellm-version')}")
    passed(f"LiteLLM {EXPECTED_VERSION} reports both deployments healthy by ID")

    served = tally(base, 200)
    share = served["200:qwen-secondary"] / 200
    if set(served) != {"200:qwen-primary", "200:qwen-secondary"} or not 0.35 <= share <= 0.65:
        fail(f"expected about 50/50 across healthy deployments, got {dict(served)}")
    passed(f"healthy split {dict(served)}")

    pins = {}
    for _ in range(16):
        session = str(uuid.uuid4())
        served = tally(base, 6, session)
        if len(served) != 1 or not next(iter(served)).startswith("200:"):
            fail(f"session {session} was not pinned to one deployment: {dict(served)}")
        pins[session] = next(iter(served)).removeprefix("200:")
    if set(pins.values()) != {"qwen-primary", "qwen-secondary"}:
        fail(f"new sessions did not spread across deployments: {Counter(pins.values())}")
    secondary_session = next(s for s, model_id in pins.items() if model_id == "qwen-secondary")
    passed(f"16 sessions x 6 requests each stayed on one deployment; {dict(Counter(pins.values()))}")

    secondary.stop()
    check_qwen_metadata(base)
    elapsed = wait_for("secondary marked unhealthy", lambda: health(base) == ({"qwen-primary"}, {"qwen-secondary"}),
                       30 + 15 + 15)
    served = tally(base, 50)
    if served != {"200:qwen-primary": 50}:
        fail(f"offline secondary still receives traffic: {dict(served)}")
    passed(f"offline secondary excluded {elapsed:.0f}s after shutdown; {dict(served)}")
    served = tally(base, 6, secondary_session)
    if served != {"200:qwen-primary": 6}:
        fail(f"session pinned to the offline secondary did not fall back: {dict(served)}")
    passed("session pinned to the offline secondary fell back to the primary")

    secondary.start()
    elapsed = wait_for("secondary restored", both_healthy, 30 + 15 + 15)
    served = tally(base, 100)
    if set(served) != {"200:qwen-primary", "200:qwen-secondary"}:
        fail(f"restored secondary receives no traffic: {dict(served)}")
    passed(f"secondary restored {elapsed:.0f}s after restart; {dict(served)}")
    served = tally(base, 6, secondary_session)
    if served != {"200:qwen-secondary": 6}:
        fail(f"session did not return to its restored deployment: {dict(served)}")
    passed("pinned session returned to the restored secondary")

    primary.stop()
    check_qwen_metadata(base)
    passed("shared metadata remains available with either upstream offline")


if __name__ == "__main__":
    main()
