# ParaAir Cloud API v1 contract fixtures

These files are the shared test vectors for the ParaAir Cloud service and the ParaAir Mac client (`apiVersion: 1` in `GET /v1/health`). Both test suites load them and assert exact equality. Neither side keeps its own copy of these tables.

| File | Contents |
|---|---|
| `errors.json` | Every API error code: HTTP status, the Darwin errno the Mac maps it to, and whether it fences the transaction |
| `paths.json` | Drive path canonicalization vectors for the Mac client and the service |
| `manifest-cases.json` | Inputs for the chunk manifest rule |
| `generate-manifests.mjs` | Computes `manifests.json` from `manifest-cases.json` with Node `crypto` |
| `manifests.json` | Generated expected manifests. Do not edit by hand. |

Changing an existing entry is a breaking API change. Update this directory, the service and the client in the same change.

## `errors.json`

```json
{"code":"version_conflict","http":409,"errno":"ESTALE","errnoValue":70,"fences":true}
```

- `errors` lists every `error.code` the service can return inside the error envelope `{"error":{"code","message","requestId"}}`.
- `errno` and `errnoValue` are the Darwin name and value of the `DriveError` code the Mac raises.
- `fences: true` means that when reserve (`POST …/uploads`) or commit (`POST …/uploads/{id}/commit`) returns this code, the transaction id is permanently fenced and the Mac treats the failure as "transaction absent": it may rotate the id and retry. The service records the fence before responding. `transaction_fenced` is `true` because the fence already exists.
- Any other 4xx from reserve or commit means "attempt not dispatched". A 5xx, or a transport failure while a commit is outstanding, means "ambiguous".
- `unknown` maps a response whose code is not listed, by status class. An unknown 4xx is `EPROTO` and deliberately not offline. An unknown 5xx is `EIO`, which the Mac treats as offline.
- `message` is fixed English text per code. It never echoes input, and clients do not display it.

## `paths.json`

Each case has an `input` and an expected result per side. A string is the canonical path; a number is the errno of the rejection.

- `swift` is `canonicalPath` in `Sources/StreamDriveCore/Backend.swift`. It splits by grapheme cluster and does not enforce byte lengths.
- `server` is the service's rule:
  - an absolute path, without NUL, `.` or `..` components, or a top-level `.streamdrive`
  - each component at most 255 UTF-8 bytes (`ENAMETOOLONG`), the whole path at most 1,024 bytes
  - no component that starts with a combining mark (`\p{M}`, `EINVAL`)

Paths are byte-exact and case-sensitive. Siblings must also be unique after NFC normalization, which needs a directory and is not a per-path vector.

## Chunk manifests

A file version is an ordered list of content-addressed chunks of `C` bytes; the vectors use `C = 8`, the service uses 4,194,304.

- `n = ceil(finalSize / C)`; an empty file has no chunks. Chunk `i` covers `[i·C, min((i+1)·C, finalSize))` and its `sha256` is the lowercase hex digest of exactly those bytes.
- `B` is the chunk list of the base version, or null when creating. For chunk `i` with `s = i·C`, `e = min(s+C, finalSize)`, and `X` the extents, in journal order, that overlap `[s, e)`:
  - **reuse** `B[i]` if `B` exists, `e <= baseVisibleSize`, `i < B.length`, `B[i].size == e − s` and `X` is empty;
  - **otherwise build** each byte `k` from the last extent in `X` covering it, else the base byte if `k < baseVisibleSize`, else zero.
- This equals truncating the base to `baseVisibleSize`, extending with zeros to `finalSize`, then applying the extents in order. The generator checks every case against that reference.

In `manifest-cases.json`, `base` and extent `data` are printable ASCII strings standing for their bytes. `base: null` means there is no base version, with `baseVisibleSize: 0`. Extents are non-empty and lie within `finalSize`.

`manifests.json` holds, per case, `baseChunks` (the chunk list of `base`, or null) and `chunks`, each `{index, reuse, sha256, size}`.

```sh
node generate-manifests.mjs           # rewrite manifests.json
node generate-manifests.mjs --check   # exit 1 if manifests.json is stale
```
