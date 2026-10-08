#!/usr/bin/env python3
"""Read-only range benchmark for already mounted StreamDrive/JuiceFS/rclone paths."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


def measured(operation):
    start = time.perf_counter()
    result = operation()
    return {"milliseconds": (time.perf_counter() - start) * 1000, "result": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", action="append", required=True, metavar="LABEL=FILE")
    parser.add_argument("--range-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--quick-look", action="store_true", help="Generate a native thumbnail for each supplied file")
    parser.add_argument("--cli", type=Path, help="Optional StreamDrive CLI for persistent object-byte counters")
    parser.add_argument("--profile")
    parser.add_argument("--state-dir", type=Path)
    args = parser.parse_args()
    if not 1 <= args.range_bytes <= 64 * 1024 * 1024 or not 1 <= args.samples <= 100:
        parser.error("Range must be 1..64MiB and samples 1..100")
    if bool(args.cli) != bool(args.profile):
        parser.error("--cli and --profile must be supplied together")

    def status():
        if not args.cli:
            return None
        cmd = [str(args.cli.resolve()), "status", args.profile, "--json"]
        if args.state_dir:
            cmd += ["--state-dir", str(args.state_dir.resolve())]
        return json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=30).stdout)

    report = {"limitations": "Read-only supplied paths. First sample means first in this run, not proven cold storage. OS/provider caches are not purged. No mount or installation occurs.", "candidates": []}
    for candidate in args.candidate:
        label, separator, value = candidate.partition("=")
        if not separator or not label:
            parser.error("--candidate must be LABEL=FILE")
        file = Path(value).resolve(strict=True)
        if not file.is_file():
            parser.error("Each candidate must be a regular file")
        before = status()
        listing = measured(lambda: len(os.listdir(file.parent)))
        size = file.stat().st_size
        fd = os.open(file, os.O_RDONLY)
        try:
            first = measured(lambda: len(os.pread(fd, args.range_bytes, 0)))
            seek = measured(lambda: len(os.pread(fd, args.range_bytes, max(0, size - args.range_bytes))))
            warm = [measured(lambda: len(os.pread(fd, args.range_bytes, 0)))["milliseconds"] for _ in range(args.samples)]
        finally:
            os.close(fd)
        record = {"label": label, "file": str(file), "logicalBytes": size, "listing": listing,
                  "firstRange": first, "distantSeek": seek, "warmMedianMilliseconds": statistics.median(warm),
                  "warmSamplesMilliseconds": warm, "streamdriveBefore": before, "streamdriveAfter": status()}
        if args.quick_look:
            before_ql = status()
            scratch = Path(__file__).resolve().parent.parent / ".runtime"
            scratch.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="quicklook-", dir=scratch) as directory:
                start = time.perf_counter()
                process = subprocess.run(["/usr/bin/qlmanage", "-t", "-s", "256", "-o", directory, str(file)],
                                         capture_output=True, text=True, timeout=120)
                record["quickLook"] = {"milliseconds": (time.perf_counter() - start) * 1000,
                    "exitCode": process.returncode, "thumbnails": len(list(Path(directory).iterdir())),
                    "streamdriveBefore": before_ql, "streamdriveAfter": status()}
        report["candidates"].append(record)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
