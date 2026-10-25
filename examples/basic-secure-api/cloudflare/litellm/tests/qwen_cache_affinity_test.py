#!/usr/bin/env python3
"""Confirm Qwen session affinity and vLLM prefix-cache reuse through the public proxy.

    python3 tests/qwen_cache_affinity_test.py [env-file] [key-alias]

Loads SERVER_NAME and APP_API_KEYS from .env, selects qwen-only by default,
and sends small Qwen requests with thinking disabled: short requests in several
sessions, then two multi-turn conversations (about 5k-10k prompt tokens per turn), with and without a session
ID. Only the session-ID cases are asserted; the conversation without one shows
the random-routing baseline. If the secondary is offline, every session stays on
the primary and the test still passes.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from virtual_keys import load_keys, select_key

MODEL = "unsloth/Qwen3.8-27B-NVFP4"
TURNS = 6


def passed(message):
    print(f"PASS: {message}", flush=True)


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def load_env(path):
    # Match the registration script's .env handling, including multiline JSON.
    result = subprocess.run(
        ["sh", "-ec", 'set -a; . "$1"; exec "$2" -c '
         "'import json, os; print(json.dumps(dict(os.environ)))'",
         "load-env", str(Path(path).resolve()), sys.executable],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


env_file = sys.argv[1] if len(sys.argv) > 1 else ".env"
key_alias = sys.argv[2] if len(sys.argv) > 2 else "qwen-only"
env = load_env(env_file)
os.environ.update(env)
server_name = env.get("SERVER_NAME")
if not server_name:
    fail(f"set SERVER_NAME in {env_file}")
try:
    app_key = select_key(load_keys(), key_alias)
except ValueError as error:
    fail(str(error))


def chat(messages, session=None):
    headers = {"Authorization": f"Bearer {app_key}", "Content-Type": "application/json",
               # Cloudflare may block Python's default user agent.
               "User-Agent": "qwen-cache-affinity-test"}
    if session:
        headers["x-session-id"] = session
    body = {"model": MODEL, "messages": messages, "max_completion_tokens": 4,
            "chat_template_kwargs": {"enable_thinking": False}}
    request = urllib.request.Request(f"https://{server_name}/v1/chat/completions", json.dumps(body).encode(), headers)
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            data = json.load(response)
            model_id = response.headers.get("x-litellm-model-id")
    except urllib.error.HTTPError as error:
        fail(f"chat request returned HTTP {error.code}")
    details = data["usage"].get("prompt_tokens_details") or {}
    return model_id, data["usage"]["prompt_tokens"], details.get("cached_tokens") or 0, data


def conversation(session):
    """Grow one conversation; return (deployment, prompt tokens, cached tokens) per turn."""
    tag = uuid.uuid4().hex  # A new prefix, so no earlier run can be cached.
    messages = [{"role": "system", "content": f"Conversation {tag}. " +
                 " ".join(f"Rule {i}: answer briefly about topic {i}." for i in range(250))}]
    turns = []
    for turn in range(TURNS):
        messages.append({"role": "user", "content": f"Turn {turn}: " +
                         " ".join(f"note {turn}.{i} says value {i * 3}." for i in range(80)) + " Reply with OK."})
        model_id, prompt, cached, data = chat(messages, session)
        turns.append((model_id, prompt, cached))
        messages.append({"role": "assistant", "content": data["choices"][0]["message"]["content"] or "OK"})
    return turns


def report(label, turns):
    for number, (model_id, prompt, cached) in enumerate(turns, 1):
        print(f"  {label} turn {number}: {model_id:15s} prompt={prompt:6d} cached={cached:6d}")
    later = turns[1:]
    share = sum(c for _, _, c in later) / sum(p for _, p, _ in later)
    print(f"  {label}: turns 2-{TURNS} reused {share:.0%} of prompt tokens")
    return share


pins = Counter()
for _ in range(6):
    session = str(uuid.uuid4())
    served = {chat([{"role": "user", "content": "Reply with OK."}], session)[0] for _ in range(4)}
    if len(served) != 1:
        fail(f"one session was served by {sorted(served)}")
    pins[served.pop()] += 1
passed(f"6 sessions x 4 requests each stayed on one deployment; sessions per deployment {dict(pins)}")
if len(pins) == 1:
    print("NOTE: only one deployment served sessions; the other may be offline.")

pinned = conversation(str(uuid.uuid4()))
pinned_share = report("with session ID", pinned)
if len({model_id for model_id, _, _ in pinned}) != 1:
    fail("the conversation with a session ID changed deployment")
if any(cached == 0 for _, _, cached in pinned[1:]):
    fail("a later turn with a session ID had no cached prompt tokens; check vLLM prefix caching")
passed("conversation with a session ID stayed on one deployment and reused cache on every later turn")

random_share = report("without session ID", conversation(None))
print(f"INFO: prefix reuse {pinned_share:.0%} with a session ID vs {random_share:.0%} without (one sample)")
