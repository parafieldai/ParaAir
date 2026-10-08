"""Run one codesign invocation in a temporary, verified headless launchd job.

Only Apple's interpreter and codesign run in the job. No credential, ACL, or
Keychain configuration is read or changed by this orchestration layer.
"""
import json
import os
from pathlib import Path
import plistlib
import runpy
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts/codesign-in-inherited-session.py"


def parent_identity():
    uid = os.getuid()
    if uid == 0 or uid != os.geteuid():
        raise ValueError("an ordinary user context is required")
    status, session, _ = runpy.run_path(str(GUARD))["session_info"]()
    if status != 0 or not 0 < session < 0xffffffff:
        raise ValueError("cannot inspect the parent Security session")
    return uid, session


def launchctl(arguments):
    return subprocess.run(["/bin/launchctl", *arguments], capture_output=True,
                          text=True, timeout=10)


def wait_result(path, token, timeout=55):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            result = json.loads(path.read_text())
            if not isinstance(result, dict) or result.get("token") != token:
                raise ValueError("unexpected completion evidence")
            code = result.get("exitCode")
            if type(code) is not int or not 0 <= code <= 255:
                raise ValueError("invalid completion exit code")
            return code
        time.sleep(0.05)
    raise TimeoutError("no completion evidence before the deadline")


def supervisor_source(guard, arguments, result_path, token):
    # subprocess inherits the launchd Security session. The child rechecks UID
    # and actual session flags immediately before execv of system codesign.
    # A separate supervisor can persist real exit evidence even after execv.
    return f'''import json,os,subprocess
try:
    child = subprocess.run({["/usr/bin/python3", "-I", "-c", guard, *arguments]!r}, timeout=45)
    code = child.returncode if child.returncode >= 0 else 128 - child.returncode
except subprocess.TimeoutExpired:
    code = 124
except Exception:
    code = 71
result_path = {str(result_path)!r}
temporary = result_path + ".tmp"
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as stream:
    json.dump({{"token": {token!r}, "exitCode": code}}, stream)
    stream.flush()
    os.fsync(stream.fileno())
os.replace(temporary, result_path)
'''


def run(arguments, jobs_root=None):
    if not arguments:
        print("Usage: codesign-without-ui.py --check-session | <codesign arguments>", file=sys.stderr)
        return 64
    try:
        uid, parent_session = parent_identity()
        guard = GUARD.read_text()
    except (OSError, ValueError, AttributeError) as error:
        print("Signing stopped: " + str(error), file=sys.stderr)
        return 77
    token = uuid.uuid4().hex
    directory = (jobs_root or ROOT / ".build/signing/jobs") / token
    directory.mkdir(parents=True, mode=0o700)
    label = "dev.paraair.codesign." + token
    domain, target = "gui/" + str(uid), "gui/" + str(uid) + "/" + label
    result_path = directory / "result.json"
    guard_arguments = ["--expected-uid", str(uid), "--parent-session", str(parent_session)]
    guard_arguments += arguments if arguments == ["--check-session"] else ["--", *arguments]
    job = {"Label": label, "ProgramArguments": ["/usr/bin/python3", "-I", "-c",
            supervisor_source(guard, guard_arguments, result_path, token)],
           "RunAtLoad": True, "SessionCreate": True,
           "StandardOutPath": str(directory / "stdout"), "StandardErrorPath": str(directory / "stderr")}
    plist = directory / "job.plist"
    with plist.open("xb") as stream:
        plistlib.dump(job, stream)
    os.chmod(plist, 0o600)
    code, cleanup = 71, False
    try:
        started = launchctl(["bootstrap", domain, str(plist)])
        if started.returncode != 0:
            raise ValueError("launchd refused the isolated job: " + started.stderr.strip())
        code = wait_result(result_path, token)
    except TimeoutError:
        print("Signing stopped: the isolated job produced no completion evidence before its deadline.", file=sys.stderr)
        code = 124
    except KeyboardInterrupt:
        print("Signing stopped: interrupted.", file=sys.stderr)
        code = 130
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("Signing stopped: " + str(error), file=sys.stderr)
        code = 71
    finally:
        # Attempt removal even if bootstrap timed out after registering the job.
        # The UUID label belongs solely to this invocation; never remove a domain.
        try:
            launchctl(["bootout", target])
            cleanup = launchctl(["print", target]).returncode == 113
        except (OSError, subprocess.TimeoutExpired):
            cleanup = False
        for name, output in [("stdout", sys.stdout), ("stderr", sys.stderr)]:
            path = directory / name
            if path.exists():
                output.write(path.read_text(errors="replace"))
        (directory / "cleanup.json").write_text(json.dumps({"label": label, "removed": cleanup}) + "\n")
    if not cleanup:
        print("Signing stopped: temporary job removal could not be confirmed: " + target, file=sys.stderr)
        return 71
    return code


def main():
    def terminate(_signal, _frame):
        raise KeyboardInterrupt()
    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        return run(sys.argv[1:])
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    raise SystemExit(main())
