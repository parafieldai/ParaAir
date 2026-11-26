#!/usr/bin/env python3
"""Network-path baseline for drive benchmarks: what the connection itself allows, with no ParaAir code involved.

Times HTTPS requests with curl: time to first byte for small requests to the ParaAir Cloud service, the
Cloudflare API (which bring-your-own R2 drives signed in with Cloudflare use) and Backblaze B2's S3 endpoint,
and bulk download and upload rates against Cloudflare's public speed test. curl takes whatever route the
system gives a command-line tool; pass --proxy to take another one. Reports the median and the spread.
"""
import argparse
import json
import os
import statistics
import subprocess
import tempfile

TTFB_TARGETS = {
    "paraair-cloud-health": "https://cloud.parafield.ai/v1/health",
    "cloudflare-api": "https://api.cloudflare.com/client/v4/ips",
    "b2-us-west-004": "https://s3.us-west-004.backblazeb2.com/",
}
FORMAT = '{"connect": %{time_connect}, "tls": %{time_appconnect}, "ttfb": %{time_starttransfer}, "total": %{time_total}, ' \
         '"code": %{http_code}, "down": %{size_download}, "up": %{size_upload}}'


def summary(values):
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values)} if values else None


def curl(url, proxy, *extra):
    cmd = ["curl", "-sS", "-o", "/dev/null", "-w", FORMAT, "--max-time", "120", *extra, url]
    if proxy:
        cmd[1:1] = ["--proxy", proxy]
    process = subprocess.run(cmd, capture_output=True, text=True, timeout=150)
    return json.loads(process.stdout) if process.returncode == 0 else {"error": process.stderr.strip()[:200]}


def bulk_ok(result, field, size):
    """A bulk sample counts only with HTTP 200 and the whole requested size moved; a 429 or 5xx is an error."""
    if "error" in result:
        return result
    if result["code"] != 200 or result[field] != size:
        return {"error": f"HTTP {result['code']}, {result[field]} of {size} bytes"}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxy", help="curl --proxy value, for a route other than the default")
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--bulk-mib", type=int, default=64)
    parser.add_argument("--bulk-samples", type=int, default=3)
    args = parser.parse_args()
    report = {"proxy": args.proxy, "ttfbMilliseconds": {}, "bulk": {}}
    trace = subprocess.run(["curl", "-sS", "--max-time", "20"] + (["--proxy", args.proxy] if args.proxy else []) +
                           ["https://cloud.parafield.ai/cdn-cgi/trace"], capture_output=True, text=True)
    report["cloudflareTrace"] = {k: v for k, v in (line.split("=", 1) for line in trace.stdout.splitlines() if "=" in line)
                                 if k in ("colo", "loc", "http", "tls")}
    for name, url in TTFB_TARGETS.items():
        curl(url, args.proxy)  # warm DNS and the route; not counted
        runs = [curl(url, args.proxy) for _ in range(args.samples)]
        good = [r for r in runs if "error" not in r]
        report["ttfbMilliseconds"][name] = {
            "newConnectionTTFB": summary([r["ttfb"] * 1000 for r in good]),
            "tcpConnect": summary([r["connect"] * 1000 for r in good]),
            "errors": len(runs) - len(good)}
    size = args.bulk_mib << 20
    down = [bulk_ok(curl(f"https://speed.cloudflare.com/__down?bytes={size}", args.proxy), "down", size)
            for _ in range(args.bulk_samples)]
    report["bulk"]["downloadMiBPerSecond"] = summary([r["down"] / (1 << 20) / r["total"] for r in down if "error" not in r])
    with tempfile.NamedTemporaryFile(prefix="path-up-") as payload:
        for _ in range(args.bulk_mib):
            payload.write(os.urandom(1 << 20))
        payload.flush()
        up = [bulk_ok(curl("https://speed.cloudflare.com/__up", args.proxy, "-X", "POST", "-H", "Content-Type: application/octet-stream",
                           "--data-binary", "@" + payload.name), "up", size) for _ in range(args.bulk_samples)]
    report["bulk"]["uploadMiBPerSecond"] = summary([r["up"] / (1 << 20) / r["total"] for r in up if "error" not in r])
    report["bulk"]["errors"] = [r["error"] for r in down + up if "error" in r]
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
