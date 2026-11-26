"""scripts/build-app.sh input checks that stop before anything is built."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build-app.sh"


def build(**environment):
    # CI=true with a zero floor skips the free-space check; a missing native library stops the script right after its
    # version checks, so nothing is compiled.
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp"), "CI": "true", "PARAAIR_CI_MIN_FREE_GIB": "0",
           "STREAMDRIVE_NATIVE_LIBRARY": "/nonexistent/libstreamdrive.dylib", **environment}
    return subprocess.run(["/bin/bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30)


class BuildNumberTests(unittest.TestCase):
    def test_build_number_fits_the_client_version_header(self):
        # The app sends mac/<major>.<minor>.<build>, and the service reads at most 6 digits a number.
        for build_number in ["1234567", "999999999", "0", "12a"]:
            with self.subTest(build=build_number):
                result = build(PARAAIR_BUILD=build_number)
                self.assertEqual(result.returncode, 1)
                self.assertIn("PARAAIR_BUILD must be a positive whole number of at most 6 digits", result.stderr)
        for build_number in ["1", "72", "999999"]:
            with self.subTest(build=build_number):
                result = build(PARAAIR_BUILD=build_number)
                self.assertNotIn("PARAAIR_BUILD", result.stderr)
                self.assertIn("Build the native engine", result.stderr)


if __name__ == "__main__":
    unittest.main()
