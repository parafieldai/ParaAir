"""Fail closed unless launchd supplied a new, headless, unprivileged session.

Run through codesign-without-ui.py. The source is supplied to Apple's Python
interpreter in memory, avoiding a custom executable load from Documents.
This module never creates sessions, unlocks Keychain, or changes access rules.
"""
import argparse
import ctypes
import json
import os
import sys


def session_info():
    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    get_info = security.SessionGetInfo
    get_info.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32),
                        ctypes.POINTER(ctypes.c_uint32)]
    get_info.restype = ctypes.c_int32
    session, flags = ctypes.c_uint32(0), ctypes.c_uint32(0)
    status = get_info(0xffffffff, ctypes.byref(session), ctypes.byref(flags))
    return status, session.value, flags.value


def positive_id(value):
    number = int(value)
    if not 0 < number < 0xffffffff:
        raise argparse.ArgumentTypeError("must be a positive, nonreserved identifier")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-uid", required=True, type=positive_id)
    parser.add_argument("--parent-session", required=True, type=positive_id)
    parser.add_argument("--check-session", action="store_true")
    parser.add_argument("codesign_args", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    forwarded = args.codesign_args
    if forwarded and forwarded[0] == "--":
        forwarded = forwarded[1:]
    if args.check_session == bool(forwarded):
        parser.error("provide either --check-session or -- followed by codesign arguments")
    uid, euid = os.getuid(), os.geteuid()
    if uid != args.expected_uid or euid != args.expected_uid:
        print("Signing stopped: the expected unprivileged user is not running this job.", file=sys.stderr)
        return 77
    try:
        status, session, flags = session_info()
    except (OSError, AttributeError):
        print("Signing stopped: cannot inspect the inherited Security session.", file=sys.stderr)
        return 77
    # The verified launchd route yields flags == 0. Reject all other attributes,
    # including root, remote, graphics, TTY, and any future unknown flags.
    if status != 0 or not 0 < session < 0xffffffff or session == args.parent_session or flags != 0:
        print("Signing stopped: a new headless Security session could not be confirmed.", file=sys.stderr)
        return 77
    if args.check_session:
        print(json.dumps({"isolated": True, "uid": uid, "euid": euid,
                          "sessionId": session, "flags": flags,
                          "graphicAccess": False, "ttyAccess": False}))
        return 0
    try:
        os.execv("/usr/bin/codesign", ["/usr/bin/codesign", *forwarded])
    except OSError:
        print("Signing stopped: could not execute system codesign.", file=sys.stderr)
        return 71
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
