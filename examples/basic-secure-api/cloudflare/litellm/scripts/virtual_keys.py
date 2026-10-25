"""Register raw LiteLLM /key/generate objects, or select a client token by alias."""
import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

CONFIG = Path(__file__).resolve().parent.parent / "litellm-config.yaml"
DEFAULT_ROUTES = ["llm_api_routes", "/health/latest"]


def load_keys():
    try:
        keys = json.loads(os.environ.get("APP_API_KEYS", ""))
    except ValueError:
        raise ValueError("APP_API_KEYS must be a JSON array of /key/generate objects") from None
    if not isinstance(keys, list) or not keys:
        raise ValueError("APP_API_KEYS must be a nonempty JSON array")
    aliases, tokens = set(), set()
    for entry in keys:
        if not isinstance(entry, dict):
            raise ValueError("Each APP_API_KEYS entry must be an object")
        alias, token = entry.get("key_alias"), entry.get("key")
        if not isinstance(alias, str) or not alias.strip() or any(ord(c) < 32 for c in alias):
            raise ValueError("Each entry needs a nonempty key_alias without control characters")
        if not isinstance(token, str) or not token.strip():
            raise ValueError(f"Key {alias!r} needs a nonempty key")
        if token == os.environ.get("LITELLM_MASTER_KEY"):
            raise ValueError(f"Key {alias!r} must differ from LITELLM_MASTER_KEY")
        if alias in aliases or token in tokens:
            raise ValueError("APP_API_KEYS contains duplicate aliases or tokens")
        aliases.add(alias)
        tokens.add(token)
        if "models" in entry:
            validate_models(entry["models"])
    return keys


def validate_models(models):
    if not isinstance(models, list) or any(not isinstance(m, str) or not m.strip() for m in models):
        raise ValueError("models must be a list of nonempty model names")
    return models


def select_key(keys, alias):
    for entry in keys:
        if entry["key_alias"] == alias:
            return entry["key"]
    raise ValueError(f"No APP_API_KEYS entry has key_alias {alias!r}")


def default_models():
    try:
        import yaml
    except ImportError:
        raise ValueError("Registration requires PyYAML: python3 -m pip install PyYAML") from None
    with CONFIG.open() as stream:
        config = yaml.safe_load(stream)
    return validate_models(config.get("litellm_settings", {}).get("default_key_generate_params", {}).get("models", []))


def model_rules(models):
    # These all grant unrestricted model access in LiteLLM 1.106.2.
    # https://github.com/BerriAI/litellm/blob/v1.106.2/litellm/proxy/auth/auth_checks.py
    if not models or "*" in models or "all-proxy-models" in models:
        return frozenset({"all-proxy-models"})
    return frozenset(models)


def request_api(opener, base_url, master_key, path, body=None):
    request = urllib.request.Request(
        base_url + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {master_key}", "Content-Type": "application/json"},
    )
    try:
        with opener.open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404 and path.startswith("/key/info?"):
            return None
        # API error bodies can echo credentials; report only the route and status.
        raise ValueError(f"{path.split('?')[0]} returned HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError):
        raise ValueError("Cannot reach the local LiteLLM management API") from None


def register(keys):
    master_key = os.environ.get("LITELLM_MASTER_KEY")
    if not master_key:
        raise ValueError("Set LITELLM_MASTER_KEY in the environment file")
    models = default_models()
    port = int(os.environ.get("LITELLM_PORT", "14000"))
    base_url = f"http://127.0.0.1:{port}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for entry in keys:
        alias, token = entry["key_alias"], entry["key"]
        # /key/generate applies default models to both omitted models and [].
        desired = entry.get("models") or models
        # Look up the hash so the raw client token stays out of access logs.
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        existing = request_api(opener, base_url, master_key, f"/key/info?key={token_hash}")
        if existing is None:
            body = {"allowed_routes": DEFAULT_ROUTES, **entry}
            result = request_api(opener, base_url, master_key, "/key/generate", body)
            if result.get("key_alias") != alias:
                raise ValueError(f"Registration did not confirm key_alias {alias!r}")
            print(f"Registered {alias!r}.", flush=True)
            continue
        info = existing["info"]
        if info.get("status") == "deleted":
            raise ValueError(f"Key {alias!r} was deleted; configure a new token")
        if info.get("key_alias") != alias:
            print(f"Key {alias!r} already exists with alias {info.get('key_alias')!r}; keeping that alias.")
        current = validate_models(info["models"])
        if model_rules(current) == model_rules(desired):
            print(f"Key {alias!r}: model access unchanged.", flush=True)
            continue
        print(f"Key {alias!r} has different model permissions.", flush=True)
        print(f"  Current: {json.dumps(current)}\n  Desired: {json.dumps(desired)}", flush=True)
        if not sys.stdin.isatty():
            print("Skipped model update: rerun in an interactive terminal to confirm.", flush=True)
            continue
        try:
            answer = input("Update model access? [y/N]: ")
        except EOFError:
            answer = ""
        if answer.strip().lower() not in {"y", "yes"}:
            print("Left model access unchanged.", flush=True)
            continue
        request_api(opener, base_url, master_key, "/key/update", {"key": token, "models": desired})
        print(f"Updated model access for {alias!r}.", flush=True)


def main():
    try:
        keys = load_keys()
        if sys.argv[1:] == ["register"]:
            register(keys)
        elif len(sys.argv) == 3 and sys.argv[1] == "select":
            print(select_key(keys, sys.argv[2]))
        else:
            raise ValueError("Usage: virtual_keys.py register | select KEY_ALIAS")
    except (ValueError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
