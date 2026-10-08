"""Guard regression tests; all Security and exec boundaries are synthetic."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/codesign-in-inherited-session.py"


class InheritedSigningSessionTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SOURCE.is_file(), "An inherited-session guard is required")
        spec = importlib.util.spec_from_file_location("signing_guard", SOURCE)
        self.guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guard)

    def run_guard(self, *, status=0, session=43, flags=0, uid=501, euid=501,
                  check=False, error=None, exec_error=None):
        args = ["--expected-uid", "501", "--parent-session", "42"]
        args += ["--check-session"] if check else ["--", "--verify", "fixture.app"]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(self.guard, "session_info", return_value=(status, session, flags),
                          side_effect=error) as inspect, \
             patch.object(self.guard.os, "getuid", return_value=uid), \
             patch.object(self.guard.os, "geteuid", return_value=euid), \
             patch.object(self.guard.os, "execv", side_effect=exec_error) as execute, \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = self.guard.main(args)
        return result, stdout.getvalue(), stderr.getvalue(), inspect, execute

    def test_verified_session_check_never_executes(self):
        result, output, _, _, execute = self.run_guard(check=True)
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output), {"isolated": True, "uid": 501, "euid": 501,
                         "sessionId": 43, "flags": 0, "graphicAccess": False, "ttyAccess": False})
        execute.assert_not_called()

    def test_verified_session_only_forwards_to_system_codesign(self):
        result, _, _, _, execute = self.run_guard()
        self.assertEqual(result, 0)
        execute.assert_called_once_with("/usr/bin/codesign", ["/usr/bin/codesign", "--verify", "fixture.app"])

    def test_wrong_or_root_user_stops_before_session_or_exec(self):
        for uid, euid in [(0, 0), (501, 0), (0, 501), (502, 501), (501, 502)]:
            with self.subTest(uid=uid, euid=euid):
                result, _, _, inspect, execute = self.run_guard(uid=uid, euid=euid)
                self.assertEqual(result, 77)
                inspect.assert_not_called()
                execute.assert_not_called()

    def test_unavailable_session_never_executes(self):
        for status, error in [(-60500, None), (0, OSError("framework unavailable"))]:
            with self.subTest(status=status, error=error):
                result, _, _, _, execute = self.run_guard(status=status, error=error)
                self.assertEqual(result, 77)
                execute.assert_not_called()

    def test_invalid_or_parent_session_never_executes(self):
        for session in [0, 42, 0xffffffff, -1]:
            with self.subTest(session=session):
                result, _, _, _, execute = self.run_guard(session=session)
                self.assertEqual(result, 77)
                execute.assert_not_called()

    def test_any_session_attributes_fail_closed(self):
        for flags in [1, 0x10, 0x20, 0x1000, 0x6030, 0x80000000]:
            with self.subTest(flags=flags):
                result, _, _, _, execute = self.run_guard(flags=flags)
                self.assertEqual(result, 77)
                execute.assert_not_called()

    def test_exec_failure_has_no_retry(self):
        result, _, _, _, execute = self.run_guard(exec_error=OSError("exec denied"))
        self.assertEqual(result, 71)
        self.assertEqual(execute.call_count, 1)

    def test_invalid_expected_identity_cannot_execute(self):
        for args in [[], ["--expected-uid", "0", "--parent-session", "42", "--check-session"],
                     ["--expected-uid", "501", "--parent-session", "0", "--check-session"],
                     ["--expected-uid", "501", "--parent-session", "42"],
                     ["--expected-uid", "501", "--parent-session", "42", "--check-session", "--", "--verify"]]:
            with self.subTest(args=args), patch.object(self.guard.os, "execv") as execute, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    self.guard.main(args)
                self.assertEqual(raised.exception.code, 2)
                execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
