#!/usr/bin/env python3
"""Upload benchmark for a mounted ParaAir drive.

Each round writes a freshly generated random file into a local scratch folder (new bytes every round, so
ParaAir Cloud's content-addressed chunks can't be skipped as duplicates), copies it into --target-dir on the
mounted drive with /bin/cp, then polls `paraair status --json` until the drive has nothing left to upload.
It reports the copy time (what Finder's progress bar shows), the time until the upload finished, and the
end-to-end rate. The copy on the drive and the local file are deleted after each round unless --keep is given
(a copy the drive won't delete yet is reported, not raised). A round that doesn't finish stops the run, so its
pending upload can't slow the next one. Rounds report the median and the spread.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time


def summary(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target-dir", type=Path, required=True, help="Existing folder on the mounted drive")
    parser.add_argument("--scratch-dir", type=Path, required=True, help="Local folder for the generated files")
    parser.add_argument("--size-mib", type=int, required=True)
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--gap-seconds", type=float, default=0, help="Pause between rounds (provider rate limits)")
    parser.add_argument("--poll-seconds", type=float, default=2.0)
    parser.add_argument("--timeout-seconds", type=float, default=3600)
    parser.add_argument("--keep", action="store_true", help="Keep the uploaded copies on the drive")
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--state-dir", type=Path)
    args = parser.parse_args()
    if not 1 <= args.size_mib <= 8192 or not 1 <= args.rounds <= 10:
        parser.error("--size-mib must be 1..8192 and --rounds 1..10")
    target = args.target_dir.resolve(strict=True)
    scratch = args.scratch_dir.resolve(strict=True)
    if not target.is_dir() or not scratch.is_dir():
        parser.error("--target-dir and --scratch-dir must be existing folders")
    size = args.size_mib << 20

    def status():
        cmd = [str(args.cli.resolve())]
        if args.state_dir:
            cmd += ["--state-dir", str(args.state_dir.resolve())]
        cmd += ["status", args.profile, "--json"]
        drive = json.loads(subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120).stdout)["drive"]
        return {"pendingUploads": drive["pendingUploads"], "pendingWriteBytes": drive["pendingWriteBytes"]}

    before = status()
    if before["pendingUploads"]:
        parser.error(f"The drive already has {before['pendingUploads']} pending uploads; wait for them first")
    rounds, stopped = [], None
    for number in range(args.rounds):
        if number and args.gap_seconds:
            time.sleep(args.gap_seconds)
        name = f"upload-{os.getpid()}-{number + 1}-{os.urandom(4).hex()}.bin"
        source, copy = scratch / name, target / name
        with open(source, "wb") as out:
            for _ in range(args.size_mib):
                out.write(os.urandom(1 << 20))
        record = {"round": number + 1, "file": name, "bytes": size}
        rounds.append(record)
        try:
            start = time.perf_counter()
            subprocess.run(["/bin/cp", str(source), str(copy)], check=True, timeout=args.timeout_seconds)
            record["copySeconds"] = time.perf_counter() - start
            timeline, done = [], None
            record["timeline"] = timeline
            while time.perf_counter() - start < args.timeout_seconds:
                now = status()
                elapsed = time.perf_counter() - start
                timeline.append({"seconds": round(elapsed, 2), **now})
                if now["pendingUploads"] == 0:
                    done = elapsed
                    break
                time.sleep(args.poll_seconds)
            record["uploadedSeconds"] = done
            if done is not None:
                record["endToEndMiBPerSecond"] = size / (1 << 20) / done
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
            record["error"] = f"{error.__class__.__name__}: {error}"[:300]
        finally:
            source.unlink(missing_ok=True)
            if not args.keep:
                try:
                    copy.unlink(missing_ok=True)
                except OSError as error:
                    # A file whose upload is still running can refuse deletion (EAGAIN); keep the measurements.
                    record["cleanupError"] = f"{error.__class__.__name__}: errno {error.errno}"
        if record.get("uploadedSeconds") is None:
            stopped = (f"Round {number + 1} did not finish uploading; later rounds were skipped so its pending work "
                       "doesn't slow them. Check `paraair uploads` before deleting its copy by hand.")
            break

    print(json.dumps({
        "limitations": "Upload completion is the drive's own pending-upload count reaching zero, polled every "
                       f"{args.poll_seconds} s, so times are rounded up to the poll. The rate is end to end, from the "
                       "start of the copy: pendingWriteBytes is journal space, not transfer progress, and uploads can "
                       "start while the copy is still running, so no separate upload-only rate is derived.",
        "stopped": stopped,
        "settings": {k: (str(v) if isinstance(v, Path) else v) for k, v in vars(args).items()},
        "rounds": rounds,
        "summary": {
            "copySeconds": summary([r.get("copySeconds") for r in rounds]),
            "uploadedSeconds": summary([r.get("uploadedSeconds") for r in rounds]),
            "endToEndMiBPerSecond": summary([r.get("endToEndMiBPerSecond") for r in rounds]),
        },
    }, indent=2))


if __name__ == "__main__":
    main()
