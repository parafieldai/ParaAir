# ParaAir drive speed

Last updated: 2026-11-26

How fast ParaAir drives are, measured through the mounted Finder volume on one Mac, and what limits them. This is the canonical record for speed; the README's [acceptance matrix](../README.md#acceptance-matrix-and-remaining-gates) links here. **No speed claim against Space, Helumi or LucidLink is supported yet**: their drives weren't measured (each needs an account, see [Competitors](#competitors)), and ParaAir's own numbers on this Mac are limited by the network route and, for reads and uploads alike, by the service's per-request CPU limit.

## Summary (2026-11-26)

- **No speed claim can be made yet, for or against.** On the production service as it runs today, ParaAir Cloud's Cloudflare Worker spends 16–80 ms of CPU on every 4 MiB chunk it moves, on a Cloudflare plan that allows 10 ms per request. Cloudflare let the first minute of traffic through, then cut off most chunk requests. After that, a 120 MiB upload took 20 minutes (0.1 MiB/s), and every cold read of a 29 MiB file failed with a connection reset. Requests for small files (ParaOS's shared records) kept returning 200 in a sample taken while the large reads failed.
- **The one healthy reading:** before the cut-offs started, uploads ran at 2.3 MiB/s, about half of what this Mac's route allows.
- **This Mac's route caps any drive** at about 8 MiB/s down and 4.7 MiB/s up (a tunnel to a US West exit). The same Mac on its direct Hong Kong line gets 57 MiB/s down and 53 MiB/s up, so a direct-route run is needed before quoting absolute numbers.
- **Not measured:** bring-your-own R2 (its sign-in has ended) and the competitors (each needs an account). See [Not measured](#not-measured) and [Competitors](#competitors).
- **Next:** fix the per-chunk CPU (a Workers Paid plan or cheaper chunk handling, see [Bottlenecks](#bottlenecks)), then rerun this method on a direct route with the competitors side by side.

## Setup

| | |
|---|---|
| Mac | Apple M2 Max, 96 GB, macOS 27.3 (26C5035r), internal SSD; ParaAir 0.1.0 build 65 from `/Applications`, FSKit native mount |
| ParaAir Cloud | Production service, a test drive made for this run, mounted at `/Volumes/SpeedTest` with the default cloud profile (4 MiB blocks, readahead up to 8 blocks with 2 in flight, up to 4 chunk uploads at once). Chunks are stored in Backblaze B2 `us-west-004`, read and written through the Cloudflare Worker |
| Bring-your-own R2 | Not measured: the existing R2 connection's Cloudflare sign-in has ended, so the drive doesn't mount (see [Not measured](#not-measured)) |
| Network | This Mac reaches the internet through a proxy tunnel to a US West exit; Cloudflare served it from its Seattle location. The same Mac on its direct Hong Kong line reaches Cloudflare Hong Kong. ParaAir's traffic took the tunnel; the route was not changed for the test |
| Test files | Generated: `video.mp4` 716 MiB (750,789,122 bytes), 143 s of 1080p30 H.264 at 42 Mbit/s with the `moov` atom at the end, as cameras write it; `photo.jpg` 8000×6000, 29 MiB; `doc.pdf` that JPEG as one page, 29 MiB; after the first video stalled, `video-90s.mp4` 120 MiB (90 s at 11 Mbit/s) |

### What the network allows

`scripts/measure-path.py`, curl over the same route as ParaAir, 7 samples for first-byte times and 3 transfers of 64 MiB for bulk rates (median, then min–max):

| Route | Cloudflare location | First byte, new connection: ParaAir Cloud / Cloudflare API / B2 | Download | Upload |
|---|---|---|---|---|
| Tunnel (ParaAir's route) | Seattle | 389 / 417 / 510 ms | 8.0 MiB/s (2.9–13.1) | 4.7 MiB/s (3.6–5.2) |
| Direct, Hong Kong | Hong Kong | 80 / 55 / 612 ms | 57.1 MiB/s (53.5–57.5) | 53.1 MiB/s (50.3–53.6) |

A recheck at 20:27 that also required HTTP 200 and the full size for every bulk sample (none failed) gave the same picture: tunnel 12.5 MiB/s down (5.4–14.0) and 3.9 up (3.7–4.0); direct 55.2 down and 41.9 up.

ParaAir can't be faster than the route it takes: on this Mac, every ParaAir number below sits under the tunnel row. Read the results as a share of that ceiling, not as what a direct connection would give.

### Local floors

The same files on the internal SSD, 5 rounds: decoding one frame at 120 s with ffmpeg takes 166 ms; Quick Look 256-pixel thumbnails take 190 ms (JPEG), 197 ms (video) and 441 ms (PDF). Time above these on a drive is the drive's.

## ParaAir Cloud results

Cold reads, 5 rounds, each after emptying ParaAir's read cache, on the 29 MiB JPEG stored in the drive (18:49–18:51, after a 13-minute pause in the test):

| Measure | Result |
|---|---|
| Folder listing | 748 ms when the drive asked the service (round 1), 2.1–2.5 ms from its 2-minute metadata cache |
| Open + first 64 KiB (time to first byte) | **Failed 5 of 5**: `ECONNRESET` after 3.2–4.5 s |
| 64 KiB at 85% of the file (distant seek) | **Failed 5 of 5**: `ECONNRESET` after 3.3–4.0 s |
| Whole-file sequential read | Failed with `ECONNRESET` (one try, 18:27) |
| Quick Look thumbnail | No thumbnail within 120 s (one try, 18:33) |
| Video seek, video thumbnail, sequential read of a large video | Not run: neither video could be stored (see [Uploads](#uploads)) |
| Warm reads | Not run: nothing could be cached |

On the Worker side, 210 chunk reads were logged during the read tests. Six returned their chunk, using 16–80 ms of CPU and taking 225–976 ms; 204 were cut off for CPU (most at 9–10 ms). Each cold 64 KiB read became three attempts at the same chunk, all cut off, and the app saw a connection reset after about 4 s. The two earlier tries (18:27 and 18:33) got past the first-byte and seek reads but failed at the sequential read and the thumbnail, and the harness stopped without writing their timings; it now records a failed operation and carries on.

These are failures, not speeds. They show what a user of the production service would hit with large files today, not what the design can do.

### Uploads

Uploads ran first (17:38), so their run also stored the files the reads used.

Copying into the drive is local and quick: 716 MiB in 10.4 s and 120 MiB in 3.9 s (the journal on the internal SSD; this is what Finder's progress bar shows). Getting it to storage is the problem:

| Run | File | Stored | Time | Effective rate |
|---|---|---|---|---|
| 1, first 54 s | 716 MiB video (plus the JPEG and PDF) | 31 chunks, 124 MiB | 17:39:10–17:40:04 | **2.3 MiB/s**, half the route's 4.7 MiB/s upload ceiling |
| 1, after that | same | 76 chunks in all (304 MiB, the JPEG and PDF included) by 18:11; the video was then deleted unfinished | 31 min | 0.1 MiB/s |
| 2, fresh file after a quiet pause | 120 MiB video | all 31 chunks | 20 min (18:12:49–18:32:52) | **0.1 MiB/s** |

Worker logs (`wrangler tail`, read-only) for the same PUTs:

- Chunk PUTs that stored a 4 MiB chunk used **38–80 ms of CPU, median 62 ms** (31 samples). The service runs on Cloudflare Workers Free, whose limit is **10 ms of CPU per request** ([limits](https://developers.cloudflare.com/workers/platform/limits/)). Cloudflare let the first PUTs through and then cut more and more off with error 1102 (outcome `exceededCpu`): in run 2, 27 PUTs were cut off for 31 stored.
- A PUT that is cut off never releases its chunk's lease, so for up to 120 s every retry of that chunk gets `503 chunk_busy`; run 2 logged 268 of them. The Mac retries a busy chunk three times, 5 s apart, then fails the whole file's pass and starts it again later.
- Each rejected PUT still carries its full 4 MiB body, because the Mac sends the body before it sees the answer. Through this Mac's tunnel, which accepts bytes faster than it delivers them, the rejected bodies queue up: the extension pushed 3.5 GiB into the tunnel for 304 MiB stored in run 1, later requests waited behind them past the Mac's 30 s request timeout, and the retries made the queue longer.

## Bottlenecks

In order of impact:

1. **Per-request CPU on the service (decisive today).** The Worker runs on Cloudflare Workers Free, which allows 10 ms of CPU per request ([limits](https://developers.cloudflare.com/workers/platform/limits/)). A stored 4 MiB chunk PUT measured 38–80 ms (median 62 ms, 31 samples), and a chunk GET 16–80 ms. Uploads hash each chunk while streaming it to storage, and reads pass every downloaded byte through a JavaScript metering loop. Cloudflare tolerated this for about a minute, then cut off nearly every chunk request (`exceededCpu`, error 1102). The service had no errors that day until the test began. Fixes, one or both: the Workers Paid plan (30 s of CPU by default), or less CPU per chunk (stream the stored object straight through and meter by length; let storage check the upload's checksum). Either way, measure again afterwards.
2. **The Mac's upload retries turn a failure into a storm** (this repository):
   - One busy chunk fails the whole file's pass: `putChunks` in [`ParaAirCloudBackend.swift`](../Sources/StreamDriveCore/Cloud/ParaAirCloudBackend.swift) stops at the first error, and `perform` in [`ParaAirCloudAPI.swift`](../Sources/StreamDriveCore/Cloud/ParaAirCloudAPI.swift) waits at most 3 × 5 s on `chunk_busy`, while a chunk whose PUT was cut off stays leased for 120 s.
   - The full 4 MiB body goes out even when the answer will be an immediate 503. The Mac's 30 s request timeout ([`ParaAirCloudHTTP.swift`](../Sources/StreamDriveCore/Cloud/ParaAirCloudHTTP.swift)) is shorter than the service's 60 s idle cut-off, so on a slow or buffered uplink the Mac retries while its first PUT still holds the lease.
   - macOS's periodic volume syncs start immediate passes that skip the retry backoff.
   - A file whose upload keeps failing can't be deleted while a pass runs (`rm` returns `EAGAIN`). Unmounting doesn't stop the pass: the extension kept uploading after unmount and ignored SIGTERM.
3. **This Mac's route.** The tunnel allows 8 MiB/s down and 4.7 MiB/s up. It accepts bytes faster than it delivers them, so rejected bodies queue: 3.5 GiB went into the tunnel for 304 MiB stored in run 1.
4. **Distance to storage (expected, not yet measurable).** Chunks live in Backblaze B2 `us-west-004` and the Worker reads them uncached. A reader served by Cloudflare's Hong Kong location pays a trans-Pacific fetch for each chunk; B2's first byte from the direct Hong Kong line was 612 ms. Readahead (8 blocks, 2 in flight) hides this for sequential reads but not for a first open or a seek.
5. **Bring-your-own R2 with Cloudflare sign-in.** Objects go through the Cloudflare API: 1,200 requests per 5 minutes per user, about 16 MiB/s of 4 MiB objects at most, and the JuiceFS engine reads one object at a time with readahead off. An R2 API-token connection avoids the first limit; turning readahead on for connected drives would address the second.

## Not measured

- **Bring-your-own R2.** The R2 connection on this Mac (Cloudflare sign-in) has ended: the app logs `outcome=authorizationEnded` and won't mount the drive. Its owner has to sign in again in ParaAir → Connections. Two limits apply to that route whatever the network: the Cloudflare API allows 1,200 requests per 5 minutes per user ([limits](https://developers.cloudflare.com/fundamentals/api/reference/limits/)), which with 4 MiB objects caps a drive at about 16 MiB/s of reads and writes together and, once exceeded, blocks every API call of that user for 5 minutes; and the JuiceFS engine reads one 4 MiB object at a time with readahead off, so sequential reads pay a full round trip per object. An R2 API-token (S3) connection avoids the first limit.
- **Multi-GB uploads on ParaAir Cloud.** Planned as three 2 GiB files. Not run after the 716 MiB upload showed the CPU limit above: each 2 GiB file would take an hour or more and thousands of requests to measure the same failure.

## Competitors

None can be used without an account, so none was measured. What the owner would provide (checked 2026-11-26):

| Product | Needs | Notes |
|---|---|---|
| LucidLink | An account at app.lucidlink.com/register and the desktop client | 30-day trial, no card. Starter $7 per member a month |
| Helumi | An account and a plan (1 TB $10 a month; refund within 3 days) | Needs macOS 26.2. Publishes "0.8 s to start playing" |
| Space | An account at app.spacefs.com and the desktop app | 7-day trial without a card (recorded 2026-10-13; its pricing page now returns 404). Defaults to a loopback SMB mount, FSKit optional |

For a fair run, measure all drives from the same Mac, the same route and the same generated files, in one session, with `scripts/compare-mounts.py` pointing at each mounted copy (it reads any mounted path). Upload with each app's own copy path (Finder or `cp`).

## Method

```sh
# Network ceiling (add --proxy URL to compare another route)
python3 scripts/measure-path.py > path.json

# Reads: 5 cold rounds; each starts by evicting ParaAir's read cache and Quick Look's thumbnail cache
CLI=/Applications/ParaAir.app/Contents/Helpers/ParaAirCLI.app/Contents/MacOS/paraair
python3 scripts/compare-mounts.py --rounds 5 --evict --sequential --video-seek 120 --quick-look \
  --range-bytes 65536 --seek-fraction 0.85 --cli "$CLI" --profile SpeedTest --state-dir "$STATE" \
  --candidate cloud-video=/Volumes/SpeedTest/bench/video.mp4 > reads.json

# Uploads: fresh random bytes each round, then wait until the drive has nothing pending
python3 scripts/measure-upload.py --target-dir /Volumes/SpeedTest/bench --scratch-dir /tmp/up \
  --size-mib 2048 --rounds 3 --cli "$CLI" --profile SpeedTest --state-dir "$STATE" > uploads.json
```

- **Time to first byte** is `open()` plus the first 64 KiB read of a file whose blocks aren't cached. File details may already be cached (the cloud drive keeps them up to 2 minutes), so this is the data path, not a first-ever lookup.
- **Distant seek** is one 64 KiB read at 85% of the video. **Video seek** is ffmpeg opening the file and decoding the frame at 120 s, which reads the `moov` index at the end and the keyframe region, like a player jumping ahead.
- **Sequential** reads the whole file in 1 MiB reads, cold (the read cache is emptied again just before, since the earlier operations may have filled it), then again warm. Reads use `F_NOCACHE`, so macOS's page cache doesn't answer them; warm means ParaAir's own cache.
- Each operation records the drive's `objectGetRequests` and `objectReadBytes` before and after, which shows whether a cold round really went to storage and how much it fetched. A failed operation is recorded with its error and time to failure, and left out of the medians: an I/O error, a timeout, ffmpeg exiting nonzero, or Quick Look making no thumbnail.
- **Uploads** are timed end to end, from the start of the copy until the drive reports nothing pending. The drive's pending-byte figure is journal space, not transfer progress, so no upload-only rate is derived from it. A round that doesn't finish stops the run.
- **Medians and spread** are over rounds; min–max is shown, not a percentile, because 5 rounds can't support one.

## Caveats

- One Mac, one afternoon (UTC+8), one route. The tunnel's bandwidth moved between 2.9 and 13 MiB/s within minutes.
- Provider caches (Cloudflare, B2) aren't controlled; the Worker reads chunks from B2 uncached.
- The service had other drives' traffic at the same time (light). The test's own chunk traffic is what pushed the service into CPU enforcement; whether large files fail at lower, everyday rates wasn't tested.
- The test drive is new and almost empty; listing times for large folders aren't covered.
- Synthetic media: real camera files with different GOP lengths or `moov` placement read differently.
