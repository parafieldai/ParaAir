#!/usr/bin/env python3
"""Read benchmark for files on already mounted ParaAir, JuiceFS, rclone or local paths.

For each candidate file it times, per round: opening the file and its first range (time to first byte),
a distant range (a seek), optionally a whole sequential read, ffmpeg decoding one frame at a distant
timestamp, and a Quick Look thumbnail. With --evict each round starts from an emptied ParaAir read
cache (and Quick Look thumbnail cache), so every round is a cold read; the ParaAir object counters
(--cli/--profile) show whether a round really fetched from storage. Rounds report the median and the
spread. Reads use F_NOCACHE so the macOS page cache does not answer them; --os-cache turns that off.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time


class OperationFailed(Exception):
    """An operation that ran but did not do its job (a nonzero exit, no thumbnail)."""


def measured(operation):
    """Times one operation. A failure is recorded (error and time to failure), not raised: a drive's
    error rate is part of the result, and summaries leave failed samples out."""
    start = time.perf_counter()
    try:
        result = operation()
    except OperationFailed as error:
        return {"milliseconds": None, "failedAfterMilliseconds": (time.perf_counter() - start) * 1000, "error": str(error)}
    except OSError as error:
        return {"milliseconds": None, "failedAfterMilliseconds": (time.perf_counter() - start) * 1000,
                "error": f"{error.__class__.__name__}: errno {error.errno}"}
    except subprocess.TimeoutExpired as error:
        return {"milliseconds": None, "failedAfterMilliseconds": (time.perf_counter() - start) * 1000,
                "error": f"timed out after {error.timeout:g} s"}
    return {"milliseconds": (time.perf_counter() - start) * 1000, "result": result}


def failures(value):
    """Failed operations anywhere in a round: every record carrying an error, including warm samples."""
    if isinstance(value, dict):
        return (1 if "error" in value else 0) + sum(failures(v) for v in value.values())
    if isinstance(value, list):
        return sum(failures(v) for v in value)
    return 0


def summary(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidate", action="append", required=True, metavar="LABEL=FILE")
    parser.add_argument("--range-bytes", type=int, default=1024 * 1024, help="Size of the first and distant ranges")
    parser.add_argument("--seek-fraction", type=float, default=1.0,
                        help="Where the distant range ends, as a fraction of the file (1.0 = the last range)")
    parser.add_argument("--samples", type=int, default=5, help="Warm repeats of the first range per round")
    parser.add_argument("--rounds", type=int, default=1, help="Repeat the whole measurement; summaries give median and spread")
    parser.add_argument("--evict", action="store_true",
                        help="Before each round, evict the ParaAir read cache (needs --cli/--profile) and reset Quick Look's cache")
    parser.add_argument("--sequential", action="store_true", help="Read the whole file in order, cold then warm")
    parser.add_argument("--read-size", type=int, default=1024 * 1024, help="Read size for --sequential")
    parser.add_argument("--video-seek", type=float, metavar="SECONDS",
                        help="Time ffmpeg decoding one frame at this timestamp (needs ffmpeg)")
    parser.add_argument("--quick-look", action="store_true", help="Generate a native thumbnail for each supplied file")
    parser.add_argument("--os-cache", action="store_true", help="Allow the macOS page cache to answer reads")
    parser.add_argument("--settle", type=float, default=0.0, help="Seconds to wait after evicting, before a round")
    parser.add_argument("--cli", type=Path, help="Optional ParaAir CLI for persistent object-byte counters")
    parser.add_argument("--profile")
    parser.add_argument("--state-dir", type=Path)
    args = parser.parse_args()
    if not 1 <= args.range_bytes <= 64 * 1024 * 1024 or not 1 <= args.samples <= 100:
        parser.error("Range must be 1..64MiB and samples 1..100")
    if not 1 <= args.rounds <= 20 or not 0 < args.seek_fraction <= 1:
        parser.error("Rounds must be 1..20 and --seek-fraction in (0, 1]")
    if not 4096 <= args.read_size <= 64 * 1024 * 1024:
        parser.error("--read-size must be 4KiB..64MiB")
    if bool(args.cli) != bool(args.profile):
        parser.error("--cli and --profile must be supplied together")
    if args.evict and not args.cli:
        parser.error("--evict needs --cli and --profile")
    ffmpeg = shutil.which("ffmpeg") if args.video_seek is not None else None
    if args.video_seek is not None and not ffmpeg:
        parser.error("--video-seek needs ffmpeg on PATH")

    def paraair(*command):
        cmd = [str(args.cli.resolve())]
        if args.state_dir:
            cmd += ["--state-dir", str(args.state_dir.resolve())]
        cmd += list(command)
        return json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120).stdout)

    def status():
        if not args.cli:
            return None
        drive = paraair("status", args.profile, "--json")["drive"]
        return {"objectGetRequests": drive["objectGetRequests"], "objectReadBytes": drive["objectReadBytes"],
                "cacheBytes": drive["cacheBytes"]}

    def delta(before, after):
        if before is None or after is None:
            return None
        return {"objectGetRequests": after["objectGetRequests"] - before["objectGetRequests"],
                "objectReadBytes": after["objectReadBytes"] - before["objectReadBytes"]}

    def counted(operation):
        before = status()
        record = measured(operation)
        record["fetched"] = delta(before, status())
        return record

    def open_file(file):
        fd = os.open(file, os.O_RDONLY)
        if not args.os_cache:
            fcntl.fcntl(fd, fcntl.F_NOCACHE, 1)
        return fd

    def sequential(file, size):
        fd = open_file(file)
        try:
            total, offset = 0, 0
            while offset < size:
                chunk = os.pread(fd, args.read_size, offset)
                if not chunk:
                    break
                total += len(chunk); offset += len(chunk)
            return total
        finally:
            os.close(fd)

    report = {"limitations": "Supplied, already mounted paths only; nothing is mounted or installed. With --evict, the "
                             "ParaAir read cache is emptied before each round; provider-side caches are not controlled. "
                             "File metadata may still be cached by the drive. Without --evict, the first round is only "
                             "the first in this run, not proven cold.",
              "settings": {k: (str(v) if isinstance(v, Path) else v) for k, v in vars(args).items()},
              "candidates": []}
    scratch = Path(__file__).resolve().parent.parent / ".runtime"
    scratch.mkdir(parents=True, exist_ok=True)
    for candidate in args.candidate:
        label, separator, value = candidate.partition("=")
        if not separator or not label:
            parser.error("--candidate must be LABEL=FILE")
        file = Path(value).resolve(strict=True)
        if not file.is_file():
            parser.error("Each candidate must be a regular file")
        size = file.stat().st_size
        seek_offset = max(0, min(size - args.range_bytes, int(size * args.seek_fraction) - args.range_bytes))
        rounds = []
        for number in range(args.rounds):
            entry = {"round": number + 1}
            if args.evict:
                entry["evicted"] = paraair("cache", args.profile, "--evict", "--json").get("evictedBytes")
                if args.quick_look:
                    subprocess.run(["/usr/bin/qlmanage", "-r", "cache"], capture_output=True, timeout=60)
                if args.settle:
                    time.sleep(args.settle)
            entry["listing"] = measured(lambda: len(os.listdir(file.parent)))

            def first_byte():
                start = time.perf_counter()
                fd = open_file(file)
                opened = time.perf_counter()
                try:
                    length = len(os.pread(fd, args.range_bytes, 0))
                finally:
                    os.close(fd)
                return {"openMilliseconds": (opened - start) * 1000, "bytes": length}
            entry["openAndFirstRange"] = counted(first_byte)

            def distant():
                fd = open_file(file)
                try:
                    return len(os.pread(fd, args.range_bytes, seek_offset))
                finally:
                    os.close(fd)
            entry["distantRange"] = counted(distant)
            opened = measured(lambda: open_file(file))
            if "error" in opened:
                entry["warmFirstRange"] = {"open": opened, "samples": []}
            else:
                fd = opened.pop("result")
                try:
                    entry["warmFirstRange"] = {"open": opened, "samples": [measured(lambda: len(os.pread(fd, args.range_bytes, 0)))
                                                                         for _ in range(args.samples)]}
                finally:
                    os.close(fd)
            if args.video_seek is not None:
                def frame():
                    process = subprocess.run([ffmpeg, "-v", "error", "-ss", str(args.video_seek), "-i", str(file),
                                              "-frames:v", "1", "-f", "null", "-"], capture_output=True, text=True, timeout=300)
                    if process.returncode != 0:
                        last = (process.stderr.strip().splitlines() or [""])[-1][:200]
                        raise OperationFailed(f"ffmpeg exited {process.returncode}: {last}")
                    return process.returncode
                entry["videoSeekFrame"] = counted(frame)
            if args.quick_look:
                with tempfile.TemporaryDirectory(prefix="quicklook-", dir=scratch) as directory:
                    def thumbnail():
                        process = subprocess.run(["/usr/bin/qlmanage", "-t", "-s", "256", "-o", directory, str(file)],
                                                 capture_output=True, text=True, timeout=120)
                        thumbnails = len(list(Path(directory).iterdir()))
                        if process.returncode != 0 or thumbnails == 0:
                            raise OperationFailed(f"qlmanage exited {process.returncode} with {thumbnails} thumbnails")
                        return {"exitCode": process.returncode, "thumbnails": thumbnails}
                    entry["quickLook"] = counted(thumbnail)
            if args.sequential:
                if args.evict:
                    # The range reads, thumbnails and seeks above may have cached part or all of the file; untimed.
                    entry["evictedBeforeSequential"] = paraair("cache", args.profile, "--evict", "--json").get("evictedBytes")
                    if args.settle:
                        time.sleep(args.settle)
                cold = counted(lambda: sequential(file, size))
                warm = counted(lambda: sequential(file, size))
                for record in (cold, warm):
                    seconds = (record["milliseconds"] or 0) / 1000
                    record["mebibytesPerSecond"] = record["result"] / (1 << 20) / seconds if seconds > 0 else None
                entry["sequentialCold"] = cold
                entry["sequentialWarm"] = warm
            rounds.append(entry)

        def values(key, field="milliseconds"):
            return [r[key][field] for r in rounds if key in r and r[key].get(field) is not None]
        record = {"label": label, "file": str(file), "logicalBytes": size, "distantOffset": seek_offset, "rounds": rounds,
                  "summary": {
                      "listingMilliseconds": summary(values("listing")),
                      "openAndFirstRangeMilliseconds": summary(values("openAndFirstRange")),
                      "distantRangeMilliseconds": summary(values("distantRange")),
                      "warmFirstRangeMilliseconds": summary([statistics.median(w) for w in
                                                             ([v["milliseconds"] for v in r["warmFirstRange"]["samples"]
                                                               if v["milliseconds"] is not None] for r in rounds) if w]),
                      "videoSeekFrameMilliseconds": summary(values("videoSeekFrame")),
                      "quickLookMilliseconds": summary(values("quickLook")),
                      "sequentialColdMiBPerSecond": summary(values("sequentialCold", "mebibytesPerSecond")),
                      "sequentialWarmMiBPerSecond": summary(values("sequentialWarm", "mebibytesPerSecond")),
                  },
                  "failedOperations": sum(failures(r) for r in rounds)}
        report["candidates"].append(record)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
