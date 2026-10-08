#!/usr/bin/env python3
"""Opt-in native R2 smoke test; credentials arrive only on an inherited pipe."""
import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import threading
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parents[1]
SEED = b"streamdrive-r2-smoke-v1"
MIB = 1024 * 1024


class SafeError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "Invalid arguments; use --help for nonsecret options.\n")


class Native:
    def __init__(self, library):
        self.lib = ctypes.CDLL(str(library))
        self.lib.sd_call.argtypes = [ctypes.c_char_p]
        self.lib.sd_call.restype = ctypes.c_void_p
        self.lib.sd_free.argtypes = [ctypes.c_void_p]
        self.lib.sd_free.restype = None

    def call(self, op, **fields):
        pointer = self.lib.sd_call(json.dumps(dict(op=op, **fields)).encode())
        if not pointer:
            raise SafeError("Native bridge returned no response.")
        try:
            result = json.loads(ctypes.string_at(pointer))
        finally:
            self.lib.sd_free(pointer)
        if not result.get("ok"):
            # Never propagate provider error text or native request/configuration.
            raise SafeError(f"Native {op} failed (errno {int(result.get('errno', 5))}).")
        return result


def credentials_from_pipe(fd):
    if os.isatty(fd):
        raise SafeError("Provide credential JSON through an anonymous pipe, not terminal input.")
    with os.fdopen(os.dup(fd), "rb") as stream:
        raw = stream.read(16 * 1024 + 1)
    if len(raw) > 16 * 1024:
        raise SafeError("Credential input exceeds the size limit.")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError):
        raise SafeError("Credential pipe must contain one JSON object.") from None
    if not isinstance(value, dict) or set(value) - {"accessKey", "secretKey", "sessionToken"}:
        raise SafeError("Invalid credential fields.")
    for key in ("accessKey", "secretKey"):
        if not isinstance(value.get(key), str) or not value[key].strip():
            raise SafeError("Access key and secret key are required.")
    if "sessionToken" in value and not isinstance(value["sessionToken"], str):
        raise SafeError("Invalid session token.")
    return value


def main():
    parser = Parser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Actually run the bounded test; default is dry-run")
    parser.add_argument("--endpoint", help="HTTPS S3 service endpoint, without bucket or credentials")
    parser.add_argument("--bucket", help="Existing dedicated test bucket")
    parser.add_argument("--credentials-fd", type=int, default=0, help="Inherited pipe with credential JSON (default stdin)")
    parser.add_argument("--local-fixture", action="store_true", help="Use project-local SQLite/local objects without a network")
    parser.add_argument("--size-mib", type=int, choices=(8, 16, 32), default=32)
    parser.add_argument("--timeout-seconds", type=int, default=300)
    parser.add_argument("--library", type=Path, default=ROOT / "native/lib/libstreamdrive.dylib")
    args = parser.parse_args()
    if not 30 <= args.timeout_seconds <= 900:
        raise SafeError("Timeout must be between 30 and 900 seconds.")
    if args.endpoint:
        endpoint = urllib.parse.urlsplit(args.endpoint)
        if (endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.password
                or endpoint.path not in ("", "/") or endpoint.query or endpoint.fragment):
            raise SafeError("Endpoint must be an HTTPS service origin without credentials, path or query.")
    if args.bucket and not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", args.bucket):
        raise SafeError("Invalid test bucket name.")
    if args.local_fixture and (args.endpoint or args.bucket):
        raise SafeError("Local fixture and remote target options cannot be combined.")
    plan = {"status": "dry-run", "writeBytes": args.size_mib * MIB, "remoteDeletes": False,
            "metadata": "fresh local SQLite", "objectPrefix": "new random streamdrive-smoke prefix",
            "nativeDiskCache": False, "credentialInput": "anonymous pipe JSON", "fullIntegrityRead": True}
    if not args.run:
        print(json.dumps(plan, indent=2))
        return
    if not args.local_fixture and (not args.endpoint or not args.bucket):
        raise SafeError("Live test requires an explicit endpoint and dedicated existing bucket.")
    credentials = None if args.local_fixture else credentials_from_pipe(args.credentials_fd)
    if shutil.disk_usage(ROOT).free < 100 * 1024 ** 3:
        raise SafeError("Refusing test with less than 100 GiB free disk space.")
    native = Native(args.library)
    # Bound even a native call that blocks past its provider request timeout.
    def timeout():
        os.write(2, b"Smoke test timed out; retain its unique metadata/prefix for inspection.\n")
        os._exit(124)
    watchdog = threading.Timer(args.timeout_seconds, timeout)
    watchdog.daemon = True
    watchdog.start()
    run = ROOT / ".runtime/r2-smoke" / uuid.uuid4().hex
    run.mkdir(mode=0o700, parents=True, exist_ok=False)
    metadata = "sqlite3://" + str(run / "metadata.sqlite3")
    report = dict(plan, status="running", runDirectory=str(run), metadataURL=metadata, filePath="/r2-smoke.bin", samples=[])
    def save():
        (run / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        os.chmod(run / "result.json", 0o600)
    save()
    handle = None
    try:
        config = {"metadataURL": metadata, "memoryMiB": 64}
        if args.local_fixture:
            config.update(createLocal=True, localObjectDirectory=str(run / "objects"))
        else:
            config.update(createS3Test=True, s3BucketURL=args.endpoint.rstrip("/") + "/" + args.bucket,
                          objectCredentials=credentials)
        started = time.monotonic()
        connected = native.call("connect", config=config)
        handle = connected["handle"]
        report.update(objectPrefix=connected["objectPrefix"], volumeIdentity=connected["volumeIdentity"],
                      initializeSeconds=time.monotonic() - started)
        save()
        payload = hashlib.shake_256(SEED).digest(args.size_mib * MIB)
        blob = run / "payload.bin"
        with blob.open("xb") as output:
            os.chmod(blob, 0o600)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        started = time.monotonic()
        native.call("commit", handle=handle, path=report["filePath"], operationID=uuid.uuid4().hex,
                    size=len(payload), baseVisibleSize=0, mode=0o600,
                    patches=[{"offset": 0, "length": len(payload), "localFile": str(blob)}])
        report["writeAndFsyncSeconds"] = time.monotonic() - started
        native.call("close", handle=handle)
        handle = None
        config.pop("createLocal", None)
        config.pop("createS3Test", None)
        config.pop("s3BucketURL", None)
        handle = native.call("connect", config=config)["handle"]
        native.call("list", handle=handle, path="/")
        if native.call("metrics", handle=handle)["metrics"]["objectReadBytes"] != 0:
            raise SafeError("Metadata listing unexpectedly fetched object contents.")
        for label, offset in (("cold-head", 0), ("cold-distant", len(payload) - 65536), ("native-repeat", len(payload) - 65536)):
            before = native.call("metrics", handle=handle)["metrics"]
            started = time.monotonic()
            data = base64.b64decode(native.call("read", handle=handle, path=report["filePath"], offset=offset, length=65536)["data"])
            elapsed = time.monotonic() - started
            after = native.call("metrics", handle=handle)["metrics"]
            if data != payload[offset:offset + 65536]:
                raise SafeError("Range integrity verification failed.")
            transferred = after["objectReadBytes"] - before["objectReadBytes"]
            if label == "cold-head" and not 0 < transferred < len(payload):
                raise SafeError("Cold range failed the partial-download acceptance check.")
            report["samples"].append({"label": label, "offset": offset, "requestedBytes": 65536,
                                      "seconds": elapsed, "objectReadBytes": transferred,
                                      "objectGetRequests": after["objectGetRequests"] - before["objectGetRequests"]})
        digest = hashlib.sha256()
        started = time.monotonic()
        for offset in range(0, len(payload), 4 * MIB):
            data = base64.b64decode(native.call("read", handle=handle, path=report["filePath"], offset=offset, length=4 * MIB)["data"])
            digest.update(data)
        if digest.digest() != hashlib.sha256(payload).digest():
            raise SafeError("Full file integrity verification failed.")
        report.update(status="passed", sha256=digest.hexdigest(), fullIntegrityReadSeconds=time.monotonic() - started,
                      metrics=native.call("metrics", handle=handle)["metrics"])
        blob.unlink()  # Only the payload generated by this invocation.
        save()
        print(json.dumps(report, indent=2))
    except BaseException:
        report["status"] = "failed"
        save()
        raise
    finally:
        if handle is not None:
            try:
                native.call("close", handle=handle)
            except SafeError:
                pass
        watchdog.cancel()


if __name__ == "__main__":
    try:
        main()
    except SafeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError):
        print("Smoke test failed; no provider details were logged.", file=sys.stderr)
        sys.exit(1)
