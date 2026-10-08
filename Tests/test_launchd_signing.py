"""No-key launchd orchestration tests with synthetic launchctl boundaries."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/codesign-without-ui.py"


class LaunchdSigningTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file(), "A temporary launchd signing orchestrator is required")
        spec = importlib.util.spec_from_file_location("launchd_signing", SOURCE)
        self.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runner)

    def exercise(self, code=0, wait_error=None, bootstrap_code=0, cleanup_code=113):
        commands = []
        def control(arguments):
            commands.append(arguments)
            rc = bootstrap_code if arguments[0] == "bootstrap" else cleanup_code if arguments[0] == "print" else 0
            return subprocess.CompletedProcess(arguments, rc, "", "")
        with tempfile.TemporaryDirectory(dir=ROOT / ".runtime") as directory, \
             patch.object(self.runner, "launchctl", side_effect=control), \
             patch.object(self.runner, "parent_identity", return_value=(501, 42)), \
             patch.object(self.runner, "wait_result", return_value=code, side_effect=wait_error) as waited, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = self.runner.run(["--check-session"], jobs_root=Path(directory))
            manifests = list(Path(directory).glob("*/job.plist"))
            import plistlib
            manifest = plistlib.loads(manifests[0].read_bytes())
        return result, commands, waited, manifest

    def test_preserves_actual_codesign_exit_and_removes_unique_job(self):
        for expected in [0, 1, 77, 124, 137]:
            with self.subTest(expected=expected):
                result, commands, _, manifest = self.exercise(code=expected)
                self.assertEqual(result, expected)
                self.assertEqual([c[0] for c in commands], ["bootstrap", "bootout", "print"])
                self.assertTrue(manifest["SessionCreate"])
                self.assertTrue(manifest["RunAtLoad"])
                self.assertNotIn("KeepAlive", manifest)
                self.assertEqual(manifest["ProgramArguments"][:3], ["/usr/bin/python3", "-I", "-c"])
                self.assertTrue(commands[1][1].endswith(manifest["Label"]))

    def test_missing_or_invalid_completion_evidence_is_failure_with_cleanup(self):
        for failure in [TimeoutError(), ValueError("invalid completion"), KeyboardInterrupt()]:
            with self.subTest(failure=failure):
                result, commands, _, _ = self.exercise(wait_error=failure)
                self.assertNotEqual(result, 0)
                self.assertEqual(commands[-2][0], "bootout")
                self.assertEqual(commands[-1][0], "print")

    def test_bootstrap_failure_never_waits_and_still_cleans_exact_target(self):
        result, commands, waited, _ = self.exercise(bootstrap_code=5)
        self.assertNotEqual(result, 0)
        waited.assert_not_called()
        self.assertEqual(commands[-2][0], "bootout")

    def test_unconfirmed_cleanup_overrides_success(self):
        result, _, _, _ = self.exercise(cleanup_code=0)
        self.assertNotEqual(result, 0)

    def test_result_requires_matching_token_and_valid_exit_code(self):
        with tempfile.TemporaryDirectory(dir=ROOT / ".runtime") as directory:
            path = Path(directory) / "result.json"
            for data in [{}, {"token": "wrong", "exitCode": 0}, {"token": "expected", "exitCode": True},
                         {"token": "expected", "exitCode": -1}, {"token": "expected", "exitCode": 256}]:
                with self.subTest(data=data):
                    path.write_text(json.dumps(data))
                    with self.assertRaises(ValueError):
                        self.runner.wait_result(path, "expected", timeout=0.1)
            path.write_text(json.dumps({"token": "expected", "exitCode": 77}))
            self.assertEqual(self.runner.wait_result(path, "expected", timeout=0.1), 77)
            path.unlink()
            with self.assertRaises(TimeoutError):
                self.runner.wait_result(path, "expected", timeout=0.01)

    def test_distribution_signing_defaults_to_guard_with_explicit_interactive_choice(self):
        build = (ROOT / "scripts/build-app.sh").read_text()
        self.assertIn('signing_mode="${STREAMDRIVE_SIGNING_MODE:-noninteractive}"', build)
        self.assertIn('if [[ "$signing_mode" == noninteractive ]]; then', build)
        self.assertIn('sign_command=(/usr/bin/python3 -I "$root/scripts/codesign-without-ui.py")', build)
        self.assertNotIn('"$signing/codesign-without-ui"', build)


if __name__ == "__main__":
    unittest.main()
