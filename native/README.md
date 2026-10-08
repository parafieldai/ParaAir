# Native JuiceFS bridge

Last updated: 2026-10-02

`../scripts/build-juicefs.sh --test` builds an in-process, FUSE-free C ABI and runs local integration tests. It pins JuiceFS revision `adcca1cc61bb4d668a945d64b2e176b44ac8e5b5` and verifies source archive SHA-256 `2d1df6b63c23badd6a31845e2b604fe702f7cc49e1352f2f7204d2ecc48e52d9`. JuiceFS and its pinned `go.mod`/`go.sum` are downloaded under `.build-native`, including the required Go 1.25.10 toolchain. The script checks 100 GiB free space, caps build parallelism at four, and keeps all caches in the project. Nothing is installed globally.

The output is `native/lib/libstreamdrive.dylib` (and a generated C header). `JuiceFSBackend` resolves `sd_call` and `sd_free` dynamically. The JSON ABI owns returned C strings until `sd_free`; it never exposes Go pointers. Native read requests are capped at 8 MiB. Metadata and range calls are serialized per connection; object GET requests within the JuiceFS engine may run concurrently. The Go library remains loaded for the process lifetime because its background runtime threads cannot safely survive unloading.

The engine uses JuiceFS `pkg/fs`, `pkg/meta`, `pkg/chunk` and `pkg/object`. `meta_client.go` is an embedding adapter compiled beside the pinned metadata package. It preserves the upstream registered driver constructors while returning initialization errors; upstream `meta.NewClient` terminates the process on such errors, which is unsuitable inside a Mac extension. SDK logging is suppressed and the Swift boundary exposes fixed operation names and POSIX errors, never raw configuration or provider errors.

Persistent cache and journal ownership stays with the Swift core. Native disk cache, writeback, prefetch and readahead are disabled. A bounded native memory buffer defaults to 64 MiB. Object-layer counters measure bytes actually read from remote/local object storage, separately from application range bytes. JuiceFS block boundaries and compression can amplify a small application range; zero readahead does not imply one object byte per requested file byte.

## Commit and recovery semantics

Every mutation acquires a volume-wide metadata `Flock` on the hidden `/.streamdrive/lock` inode. A file commit checks a version composed from inode, length, nanosecond modification time and change time. New-file commits require the destination to be absent. Existing data is cloned through JuiceFS metadata, so staging does not read the full file. The stage is truncated to the visible base length, extended to final length, updated with ordered local journal extents, fsynced with native writeback disabled, marked with its transaction ID in an xattr, and atomically renamed over the destination.

The operation marker detects replay after the remote rename succeeds but the client dies before recording completion. The same transaction ID must always describe the same sealed transaction. A failed pre-rename attempt leaves the old destination intact; retry discards only that transaction's unreferenced stage and reconstructs it from the durable local journal. A stale base fails with `ESTALE`. Temporary stages left by an abandoned client remain hidden until that transaction is retried; no automatic sweeping of another client's stages occurs.

The lock is cooperative: concurrent StreamDrive clients respect it. A plain JuiceFS mount, SDK writer, or administrator can bypass the lock, so external writes must be quiesced for conflict checks to be reliable. This bridge does not claim compare-and-swap against arbitrary noncooperating writers. The Swift core must seal an attempted transaction before retrying it or accepting further writes.

## Supported volume shape

The build includes SQLite/Redis/PostgreSQL metadata and S3-compatible/local object storage support. Native regression tests use fresh local SQLite metadata and a dedicated local object directory or mocked HTTP transport. They do not format, access or benchmark a cloud/NAS endpoint. The separately authorized live R2 smoke is documented below; other S3-compatible endpoints still require testing the exact service and credentials.

This first adapter supports regular files and directories on unsharded, single-tier JuiceFS volumes. JuiceFS RSA data encryption, Kerberos and multi-tier/sharded volume configurations return an error. Symbolic links are unsupported at the Swift interface. Metadata credentials come from the caller; `META_PASSWORD` environment overrides are deliberately excluded inside the multi-profile host process. S3 keys must be explicit or already present in the selected volume format; the bridge rejects missing keys instead of falling back to a process-global AWS profile. New cloud initialization reserves a brand-new local SQLite file with O_EXCL, rejects existing sidecars, uses a random managed prefix, and never formats an existing database. Connections check the exact bucket URL against the metadata format before passing credentials to its adapter. `scripts/patch-juicefs.py` applies a checked, idempotent patch to the pinned source so each S3 connection uses its own signing region instead of process-global AWS region settings.

## Verification

The Go tests cover a 64 MiB logical file with a distant 4 KiB range read, metadata-only stat, replay/reopen, stale/create-existing conflicts, shrink-then-extend zeroing, failed-stage recovery, simultaneous cooperative writers, clipped local extents, reserved paths, symlink alias rejection, invalid configuration without process exit, and metadata-plus-object backup restoration into a separate local store. Swift integration tests exercise the real dylib when `STREAMDRIVE_NATIVE_LIBRARY` points to its absolute path:

```sh
STREAMDRIVE_NATIVE_LIBRARY="$PWD/native/lib/libstreamdrive.dylib" swift test --filter NativeBackendTests
```

No native mount, Finder preview, production NAS/AWS throughput, signing or notarization claim follows from these local tests. JuiceFS source is Apache-2.0 licensed; its source archive retains `LICENSE` and dependency notices. A distributor must include the applicable upstream/dependency notices with the packaged binary.

## OAuth R2 adapter

`cloudflare.go` implements GET, PUT and DELETE against Cloudflare's authenticated REST object endpoint. It accepts only `api.cloudflare.com` and a validated account/bucket path, rejects redirects, caps each object at 8 MiB, and counts whole downloaded chunk bodies even when the caller asks for a smaller range. It never assumes REST supports HTTP Range. HTTP errors and invalid mutation acknowledgments fail closed without provider body text. Normal new volumes use 4 MiB JuiceFS chunks. Stock JuiceFS tools cannot open the custom `cloudflare-oauth` format without this bridge. Listing/copy/multipart maintenance operations remain unsupported; provider-level object backup plus metadata backup is required. On October 2, 2026, a bounded live R2 test passed eight PUTs totaling 32 MiB, ten GETs totaling 40 MiB of file chunks, partial-read/seek/cache checks and full integrity verification. Live DELETE and maintenance/backup operations remain untested. See the root README for measured timings and the retained report.

Opt-in live smoke runs pass an `objectBudget` in the native connect configuration:

```json
{"objectBudget":{"id":"b26d904c-599d-4ac7-9e91-e8615a379b40","maxUploadBytes":67108864,"maxDownloadBytes":134217728,"maxRequests":200}}
```

Generate a new UUID for each run and reuse it with identical limits across every handle and reopen in that process. Counters survive handle closure; changing limits for an existing ID fails. The process keeps at most 128 budget IDs and has no reset API. All three limits must be positive; attaching this budget to another storage adapter fails instead of bypassing it. `metrics.objectBudget` returns `requests`, `uploadBytes`, `downloadBytes` and `downloadReservedBytes` immediately after connection, including initial zeros, so a runner can reject an outdated dylib before uploading.

Each HTTP attempt reserves one request, its entire upload payload, and the maximum response body before dispatch. GET reserves 8 MiB plus one overflow-detection byte; PUT and DELETE reserve 65,537 bytes for bounded acknowledgments/errors. Reservations are never refunded, including failures and short responses, so concurrent in-flight requests and retries cannot reuse reserved download capacity. Each reader is additionally capped at its own reservation. `downloadBytes` counts actual response payload consumed; `downloadReservedBytes` counts the conservative reserved total. Exhaustion returns `EDQUOT`. Budgeted runs disable connection reuse, automatic compression and HTTP/2 so the HTTP transport cannot transparently retry below request accounting. Their timings include this conservative connection overhead. Normal connections are unchanged. These counters bound application HTTP payload reads and reserve maximum known chunk responses per dispatch, excluding protocol overhead and socket buffering; they do not establish a provider account's remaining free allowance. Counters are process-local, so restarting a smoke runner starts a new run rather than continuing the previous limit.
