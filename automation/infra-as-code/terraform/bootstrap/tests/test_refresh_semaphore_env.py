"""Exercise restart gating using fake kubectl; no cluster or secret access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "refresh-semaphore-env.sh"
FAKE = '''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ["FAKE_ROOT"])
with (root / "calls").open("a") as f:
    f.write(" ".join(args) + "\\n")
mode = os.environ["FAKE_MODE"]
if "annotate" in args:
    (root / "annotated").touch()
elif "get" in args and "externalsecret" in args:
    refreshed = (root / "annotated").exists() and mode != "stale"
    if mode == "api-error" and refreshed:
        sys.exit(1)
    print(json.dumps({"status": {
        "refreshTime": "new" if refreshed else "old",
        "syncedResourceVersion": "new-version" if refreshed else "old-version",
        "conditions": [{"type": "Ready", "status": "False" if mode == "not-ready" else "True"}]
    }}))
elif "get" in args and "secret" in args:
    print(json.dumps({"data": {} if mode == "missing-token" else {"TF_VAR_cloudflare_api_token": "fake-base64"}}))
'''


class RefreshGate(unittest.TestCase):
    def check_mode(self, mode, success):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            kubectl = root / "kubectl"
            kubectl.write_text(FAKE)
            kubectl.chmod(0o755)
            result = subprocess.run(
                ["bash", str(SCRIPT)], capture_output=True, text=True, timeout=8,
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                     "FAKE_ROOT": tmp, "FAKE_MODE": mode, "ESO_SYNC_TIMEOUT_SECONDS": "1"},
            )
            calls = (root / "calls").read_text()
            self.assertEqual(result.returncode == 0, success, result.stderr)
            self.assertEqual("rollout restart" in calls, success)
            self.assertNotIn("fake-base64", result.stdout + result.stderr)
            if success:
                self.assertLess(calls.index("get secret"), calls.index("rollout restart"))
                self.assertIn("rollout status", calls)

    def test_fresh_ready_sync_restarts(self):
        self.check_mode("success", True)

    def test_stale_ready_never_restarts(self):
        self.check_mode("stale", False)

    def test_fresh_not_ready_never_restarts(self):
        self.check_mode("not-ready", False)

    def test_missing_token_never_restarts(self):
        self.check_mode("missing-token", False)

    def test_api_error_never_restarts(self):
        self.check_mode("api-error", False)


if __name__ == "__main__":
    unittest.main()
