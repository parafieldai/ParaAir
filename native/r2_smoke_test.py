"""Local-only checks for the opt-in R2 harness; no credentials or cloud calls."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/r2-smoke.py"


class HarnessSafetyTests(unittest.TestCase):
    def invoke(self, *args):
        self.assertTrue(SCRIPT.is_file(), "R2 harness has not been implemented")
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True,
                              env={"PATH": "/usr/bin:/bin"}, timeout=10)

    def test_default_is_dry_run_and_does_not_load_native_library(self):
        result = self.invoke("--library", "/does/not/exist.dylib")
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["status"], "dry-run")
        self.assertEqual(plan["writeBytes"], 32 * 1024 * 1024)
        self.assertFalse(plan["remoteDeletes"])

    def test_live_run_requires_endpoint_bucket_and_credentials(self):
        for args in [("--run",), ("--run", "--endpoint", "https://example.invalid", "--bucket", "test-bucket")]:
            result = self.invoke(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("Traceback", result.stderr)

    def test_secret_bearing_endpoint_is_rejected_without_echoing(self):
        result = self.invoke("--endpoint", "https://dummy:do-not-echo@example.invalid", "--bucket", "test-bucket")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("do-not-echo", result.stdout + result.stderr)

    def test_payload_size_is_bounded(self):
        result = self.invoke("--size-mib", "65")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
