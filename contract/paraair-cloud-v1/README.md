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

The billing endpoints below add no error codes: every billing error is one of the codes in `errors.json`.

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

## Billing

Billing is off unless the service sets `BILLING_PROVIDER` to `stripe` or `paddle`. While it is off (`none`), both endpoints answer 404 `not_found` and every workspace's `billing` object reports `"provider":"none","status":"none"` with `checkoutAvailable: false`. Amounts never travel from the client: it names a plan, an interval and quantities.

### `POST /v1/billing/checkout`

Access token, `Content-Type: application/json`. `Idempotency-Key` is accepted and not required.

```json
{"workspaceId":"ws_…","plan":"team","interval":"year","seats":3,"extraStorageTb":0}
```

- `plan` is `personal` or `team` and must equal the workspace's `kind`; `interval` is `month` or `year`.
- `seats`: Team only, 1 to 1000, at least the workspace's current member count; default the member count. Personal accepts only `1` or no value.
- `extraStorageTb`: 0 to 100 added 1 TB blocks, default 0.
- 200 `{"url":"https://…"}`: open it in the browser. Stripe returns its hosted checkout; Paddle returns the service's payment link page (`<issuer>/billing/pay?_ptxn=txn_…`). The plan changes only when the processor's webhook arrives; refresh `GET /v1/me` afterwards.
- The browser comes back to `<issuer>/billing/success` or `<issuer>/billing/cancel` (plain pages that say to return to ParaAir).

| Status | Code | When |
|---|---|---|
| 400 | `invalid_request` | bad plan, interval, seats or storage; plan does not match the workspace kind; seats below the member count |
| 403 | `forbidden` | the caller is not the workspace owner |
| 403 | `suspended` | the workspace is suspended |
| 404 | `workspace_not_found` | not a member of that workspace (existence never leaks) |
| 404 | `not_found` | billing is off |
| 409 | `busy` | the workspace already has a live subscription (`active` or `past_due`) or is being purged: use the portal |
| 429 | `rate_limited` | more than 20 checkout or portal sessions for the workspace this hour (`retryAfterSeconds`) |
| 503 | `unavailable` | billing misconfigured (prices, keys, links), or the processor could not be reached |

### `POST /v1/billing/portal`

```json
{"workspaceId":"ws_…"}
```

200 `{"url":"https://…"}`: the processor's customer portal (cancel, resume, payment method, invoices). Stripe returns the browser to `<issuer>/billing/return`. Errors as for checkout, plus 404 `not_found` when the workspace has no subscription with the current processor.

### `billing` in `GET /v1/me`

Every entry of `workspaces[]` gains:

```json
"billing":{"provider":"stripe","status":"past_due","plan":"team","interval":"year","seats":3,"extraStorageTb":1,
           "currentPeriodEnd":"2027-10-12T00:00:00.000Z","cancelAtPeriodEnd":false,"graceEndsAt":"2026-10-26T00:00:00.000Z",
           "readOnlyAt":"2026-10-26T00:00:00.000Z","deletionAt":"2026-11-25T00:00:00.000Z","checkoutAvailable":false,"portalAvailable":true}
```

| Field | Meaning |
|---|---|
| `provider` | `none`, `stripe` or `paddle`: the processor of the workspace's subscription, else the configured one |
| `status` | `none` (no paid subscription; admin-set plan), `active`, `past_due` (payment failed; full access until `graceEndsAt`), `read_only` (until `deletionAt`), `pending_deletion` (waiting for an admin to confirm the purge), `deleting`, `deleted` |
| `plan`, `interval` | `personal` or `team`, `month` or `year`; null when `status` is `none` |
| `seats` | seats billed from the next renewal (Team), 1 for Personal, null when `status` is `none`. `plan.seats` stays the seats usable now, which may be higher until the period ends after a member was removed |
| `extraStorageTb` | added 1 TB blocks |
| `currentPeriodEnd` | end of the paid period, ISO 8601, or null |
| `cancelAtPeriodEnd` | a cancellation is scheduled; access lasts until `readOnlyAt` |
| `graceEndsAt` | set only while `past_due` |
| `readOnlyAt` | when the workspace becomes (or became) read-only: the scheduled cancellation, the end of the grace period, or the start of the read-only period; null otherwise |
| `deletionAt` | 30 days after `readOnlyAt`, when known |
| `checkoutAvailable` | the caller is the owner, billing is configured with a price for this workspace's kind, and the workspace has no live subscription |
| `portalAvailable` | the caller is the owner and the workspace has a customer with the configured processor |

While `status` is `read_only` (and later), the workspace's own `status` is `read_only` when billing set it: uploads and commits answer 403 `read_only` (fencing as in `errors.json`), reads keep working.

