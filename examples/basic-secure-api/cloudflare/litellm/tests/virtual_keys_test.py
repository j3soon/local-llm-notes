#!/usr/bin/env python3
"""Local key registration checks: python3 tests/virtual_keys_test.py (needs PyYAML)."""
from contextlib import redirect_stdout
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import virtual_keys

QWEN = "unsloth/Qwen3.8-27B-NVFP4"


def read_generated_keys(env_file):
    loaded = subprocess.run(["sh", "-ec", 'set -a; . "$1"; exec "$2" -c '
                             "'import os; print(os.environ[\"APP_API_KEYS\"])'",
                             "load", str(env_file), sys.executable], capture_output=True, text=True, check=True)
    return json.loads(loaded.stdout)


class KeyAPI(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        self.server.paths.append(self.path)
        self.assert_auth()
        if self.server.fail_lookup:
            self.respond(500, {"error": "sk-secret-from-error-body"})
            return
        token_hash = parse_qs(urlsplit(self.path).query)["key"][0]
        info = self.server.keys.get(token_hash)
        self.respond(404 if info is None else 200, {} if info is None else {"info": info})

    def assert_auth(self):
        if self.headers.get("Authorization") != "Bearer sk-master":
            raise AssertionError("Management request must use master key")

    def do_POST(self):
        self.assert_auth()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.writes.append((self.path, body))
        token_hash = hashlib.sha256(body["key"].encode()).hexdigest()
        if self.path == "/key/generate":
            info = {**body, "models": body.get("models") or [QWEN], "spend": 3}
            self.server.keys[token_hash] = info
        elif self.path == "/key/update":
            self.server.keys[token_hash].update(body)
        else:
            raise AssertionError(f"Unexpected endpoint {self.path}")
        self.respond(200, self.server.keys[token_hash])


class VirtualKeysTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), KeyAPI)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        self.server.keys = {}
        self.server.writes = []
        self.server.paths = []
        self.server.fail_lookup = False
        self.entries = [
            {"key_alias": "full-access", "key": "sk-full", "models": ["all-proxy-models"],
             "rpm_limit": 17, "metadata": {"owner": "Alice"}},
            {"key_alias": "qwen-only", "key": "sk-qwen"},
        ]
        self.env = {"LITELLM_MASTER_KEY": "sk-master", "LITELLM_PORT": str(self.server.server_port),
                    "APP_API_KEYS": json.dumps(self.entries)}
        self.env_patch = patch.dict(os.environ, self.env)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def run_registration(self, interactive=False, answer="n"):
        output = io.StringIO()
        with redirect_stdout(output), patch("sys.stdin.isatty", return_value=interactive), \
                patch("builtins.input", return_value=answer) as prompt:
            virtual_keys.register(virtual_keys.load_keys())
        return output.getvalue(), prompt

    def seed(self, models):
        token_hash = hashlib.sha256(b"sk-qwen").hexdigest()
        self.server.keys[token_hash] = {"key_alias": "qwen-only", "models": models,
                                        "spend": 7, "max_budget": 50, "rpm_limit": 21}
        os.environ["APP_API_KEYS"] = json.dumps([self.entries[1]])
        return token_hash

    def test_create_raw_requests_and_rerun(self):
        output, _ = self.run_registration()
        full, qwen = [body for _, body in self.server.writes]
        self.assertEqual(full, {"allowed_routes": virtual_keys.DEFAULT_ROUTES, **self.entries[0]})
        self.assertNotIn("models", qwen)  # Server applies generation defaults.
        self.assertEqual(virtual_keys.default_models(), [QWEN])
        self.assertEqual(virtual_keys.select_key(virtual_keys.load_keys(), "qwen-only"), "sk-qwen")
        self.server.writes.clear()
        self.run_registration()
        self.assertEqual(self.server.writes, [])
        self.assertNotIn("sk-full", output)
        self.assertNotIn("sk-qwen", " ".join(self.server.paths))

    def test_confirmed_update_only_changes_models(self):
        token_hash = self.seed(["azure/gpt-6-luna", QWEN])
        _, prompt = self.run_registration(interactive=True, answer="yes")
        prompt.assert_called_once_with("Update model access? [y/N]: ")
        self.assertEqual(self.server.writes, [("/key/update", {"key": "sk-qwen", "models": [QWEN]})])
        info = self.server.keys[token_hash]
        self.assertEqual((info["spend"], info["max_budget"], info["rpm_limit"]), (7, 50, 21))

    def test_declined_and_noninteractive_updates_are_skipped(self):
        self.seed(["azure/gpt-6-luna"])
        output, prompt = self.run_registration()
        prompt.assert_not_called()
        self.assertIn("Skipped model update", output)
        self.run_registration(interactive=True, answer="")
        self.assertEqual(self.server.writes, [])

    def test_model_order_and_unrestricted_rules_compare_equally(self):
        self.seed(["azure/gpt-6-luna", QWEN])
        entry = {**self.entries[1], "models": [QWEN, "azure/gpt-6-luna", QWEN]}
        os.environ["APP_API_KEYS"] = json.dumps([entry])
        _, prompt = self.run_registration(interactive=True)
        prompt.assert_not_called()
        for stored in ([], ["*"], ["all-proxy-models"]):
            self.seed(stored)
            os.environ["APP_API_KEYS"] = json.dumps([{**entry, "models": ["all-proxy-models"]}])
            self.run_registration(interactive=True)
        self.assertEqual(self.server.writes, [])

    def test_empty_models_use_default_when_comparing(self):
        self.seed([QWEN])
        os.environ["APP_API_KEYS"] = json.dumps([{**self.entries[1], "models": []}])
        self.run_registration(interactive=True)
        self.assertEqual(self.server.writes, [])

    def test_invalid_lists_fail_before_api_requests(self):
        invalid = [[], {}, [self.entries[0], self.entries[0]],
                   [self.entries[0], {**self.entries[1], "key": "sk-full"}],
                   [{**self.entries[1], "key": "sk-master"}],
                   [{**self.entries[1], "models": "*"}],
                   [{"key_alias": "missing-token"}]]
        for entries in invalid:
            with self.subTest(entries=entries):
                os.environ["APP_API_KEYS"] = json.dumps(entries)
                with self.assertRaises(ValueError):
                    virtual_keys.load_keys()
        self.assertEqual(self.server.paths, [])

    def test_api_failure_does_not_attempt_creation_or_echo_error_body(self):
        self.server.fail_lookup = True
        with self.assertRaisesRegex(ValueError, r"/key/info returned HTTP 500") as error:
            self.run_registration()
        self.assertNotIn("sk-secret", str(error.exception))
        self.assertEqual(self.server.writes, [])

    def test_shell_wrapper_reads_multiline_json(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text(f"LITELLM_MASTER_KEY=sk-master\nLITELLM_PORT={self.server.server_port}\n"
                                f"APP_API_KEYS='{json.dumps(self.entries, indent=2)}'\n")
            result = subprocess.run([str(ROOT / "scripts/create_virtual_key.sh"), str(env_file)],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.server.writes), 2)

    def test_client_checks_load_multiline_json_and_reject_missing_alias_before_network(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text((ROOT / ".env.example").read_text())
            commands = [
                [str(ROOT / "scripts/basic_security_scan.sh"), str(env_file), QWEN, "missing"],
                [sys.executable, str(ROOT / "tests/qwen_cache_affinity_test.py"), str(env_file), "missing"],
            ]
            for command in commands:
                with self.subTest(command=command[0]):
                    result = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("No APP_API_KEYS entry has key_alias 'missing'", result.stderr)

    def test_generator_preserves_json_and_legacy_token(self):
        template = (ROOT / ".env.example").read_text()
        start, end = template.index("APP_API_KEYS='"), template.index("\n# Use a hex password")
        for existing_list in (True, False):
            with self.subTest(existing_list=existing_list), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                entry = {**self.entries[1], "metadata": {"note": "Alice's $value\nsecond line"}}
                serialized = json.dumps([entry]).replace("'", r"\u0027")
                setting = f"APP_API_KEYS='{serialized}'" if existing_list else "APP_API_KEY=sk-legacy"
                env_file.write_text(template[:start] + setting + template[end:])
                result = subprocess.run([str(ROOT / "scripts/gen_env.sh"), str(env_file)], input="n\ny\n",
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Append a new client key? [y/N]", result.stderr)
                keys = read_generated_keys(env_file)
                if existing_list:
                    self.assertEqual(keys, [entry])
                else:
                    self.assertEqual(keys[1]["key"], "sk-legacy")
                    self.assertNotEqual(keys[0]["key"], keys[1]["key"])
                self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
                block = re.search(r"^APP_API_KEYS='\[\n(.*?)\n\]'$", env_file.read_text(), re.M | re.S)
                self.assertIsNotNone(block)
                lines = block.group(1).splitlines()
                self.assertEqual(len(lines), len(keys))
                for index, (line, key) in enumerate(zip(lines, keys)):
                    self.assertTrue(line.startswith("  {"))
                    self.assertEqual(line.endswith(","), index < len(keys) - 1)
                    self.assertEqual(json.loads(line.rstrip(",")), key)

    def test_generator_appends_multiple_keys_with_native_model_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            original = (ROOT / ".env.example").read_text()
            env_file.write_text(original)
            existing_keys = read_generated_keys(env_file)
            answers = ("y\nqwen-only\nnew-default\n\n"
                       "y\nnew-all\ninvalid\n[\"\"]\n[\"all-proxy-models\"]\n"
                       "y\nnew-custom\n[\"azure/gpt-6-astra\"]\n"
                       "n\ny\n")
            result = subprocess.run([str(ROOT / "scripts/gen_env.sh"), str(env_file)], input=answers,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("key_alias already exists", result.stderr)
            self.assertIn("models must be a JSON array", result.stderr)
            keys = read_generated_keys(env_file)
            self.assertEqual(keys[:2], existing_keys)
            self.assertEqual([entry["key_alias"] for entry in keys[2:]], ["new-default", "new-all", "new-custom"])
            self.assertNotIn("models", keys[2])
            self.assertEqual(keys[3]["models"], ["all-proxy-models"])
            self.assertEqual(keys[4]["models"], ["azure/gpt-6-astra"])
            for entry in keys[2:]:
                self.assertRegex(entry["key"], r"^sk-[0-9a-f]{64}$")
                self.assertNotIn(entry["key"], result.stdout + result.stderr)
            self.assertEqual(len({entry["key"] for entry in keys}), len(keys))
            backups = list(Path(directory).glob(".env_*.bak"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), original)
            self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
            self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
            self.assertIn("Register client keys with", result.stdout)

    def test_generator_cancel_and_incomplete_append_leave_file_unchanged(self):
        for answers in ("y\nnew-client\n\nn\nn\n", "y\n", "y\nnew-client\n"):
            with self.subTest(answers=answers), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                original = (ROOT / ".env.example").read_text()
                env_file.write_text(original)
                result = subprocess.run([str(ROOT / "scripts/gen_env.sh"), str(env_file)], input=answers,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0 if answers.endswith("n\nn\n") else 1)
                self.assertEqual(env_file.read_text(), original)
                self.assertEqual(list(Path(directory).glob(".env_*.bak")), [])

    def test_generator_first_run_offers_append(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            # Host, tunnel, two provider keys, primary endpoint/key, secondary endpoint/key.
            answers = "\ntest-tunnel\n\n\n\n\n\n\ny\nfirst-client\n[]\nn\n"
            result = subprocess.run([str(ROOT / "scripts/gen_env.sh"), str(env_file)], input=answers,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            keys = read_generated_keys(env_file)
            self.assertEqual([entry["key_alias"] for entry in keys], ["full-access", "qwen-only", "first-client"])
            self.assertEqual(keys[2]["models"], [])

    def test_generator_distinguishes_invalid_json_from_invalid_array(self):
        template = (ROOT / ".env.example").read_text()
        start, end = template.index("APP_API_KEYS='"), template.index("\n# Use a hex password")
        cases = [
            ('[\n{"key_alias":"test","key":"sk-private-test"},\n]', "contains invalid JSON"),
            ('[]', "must be a single nonempty JSON array"),
            ('{}', "must be a single nonempty JSON array"),
            ('[] []', "must be a single nonempty JSON array"),
        ]
        for value, expected in cases:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                env_file = Path(directory) / ".env"
                original = template[:start] + f"APP_API_KEYS='{value}'" + template[end:]
                env_file.write_text(original)
                result = subprocess.run([str(ROOT / "scripts/gen_env.sh"), str(env_file)],
                                        input="", capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("sk-private-test", result.stdout + result.stderr)
                self.assertNotIn("Append a new client key?", result.stderr)
                self.assertEqual(env_file.read_text(), original)
                self.assertEqual(list(Path(directory).glob(".env_*.bak")), [])

    def test_generator_uses_template_comments_spacing_and_setting_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "litellm/scripts/gen_env.sh"
            script.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "scripts/gen_env.sh", script)
            template = (ROOT / ".env.example").read_text()
            # Future comment and layout changes must carry through without script edits.
            template = "# Added template guidance\n\n" + template
            template = template.replace("LITELLM_LOG=INFO\n", "")
            template = template.replace("LITELLM_MASTER_KEY=", "# Logging\nLITELLM_LOG=INFO\n\nLITELLM_MASTER_KEY=")
            (root / "litellm/.env.example").write_text(template)
            env_file = root / "generated settings.env"
            original = (ROOT / ".env.example").read_text()
            env_file.write_text(original)
            original_keys = read_generated_keys(env_file)
            result = subprocess.run([str(script), str(env_file)], input="n\ny\n",
                                    cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            generated = env_file.read_text()
            layout = lambda text: [line for line in text.splitlines() if not line or line.startswith("#")]
            self.assertEqual(layout(generated), layout(template))
            self.assertEqual(re.findall(r"^([A-Z_][A-Z0-9_]*)=", generated, re.M),
                             re.findall(r"^([A-Z_][A-Z0-9_]*)=", template, re.M))
            self.assertEqual(read_generated_keys(env_file), original_keys)
            self.assertNotIn("sk-change-me-qwen", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
