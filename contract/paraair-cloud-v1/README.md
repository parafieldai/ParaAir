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

The billing endpoints below use two codes only they return: `disclosure_outdated` (409) and `billing_unavailable` (503). Clients that predate them map them by status class (`unknown` in `errors.json`).

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

Free trials and self-serve accounts (added 2026-10-27):

- With Stripe, a workspace's first subscription starts with a free trial (`BILLING_TRIAL_DAYS`, 7 by default; 0 turns trials off). The card is collected at checkout and charged when the trial ends. If that first charge fails, the plan ends at once: no grace period, the workspace becomes `read_only` for 30 days, then it is deleted. Later renewals keep the usual grace period.
- A user gets one trial, and a workspace that has had a subscription gets none. Paddle sells without trials.
- With self-serve sign-up (`SELF_SIGNUP=1`), any address can sign in. A new account gets a Personal workspace with no storage, transfer or retained space (`plan.storageLimitBytes` 0, `billing.status` `none`, `checkoutAvailable` true and `trialDays` set) until its trial or a plan starts. Uploads answer 507 `quota_exceeded` until then.
- With Stripe Managed Payments (`STRIPE_MANAGED_PAYMENTS`, on by default), Link is the merchant of record. Stripe's checkout page then shows Stripe's standard terms, not the disclosure, so the app's plan sheet is where the buyer reads it.

### `POST /v1/billing/checkout`

Access token, `Content-Type: application/json`. `Idempotency-Key` is accepted and not required.

```json
{"workspaceId":"ws_…","plan":"personal","interval":"month","extraStorageTb":0,
 "disclosureVersion":"A-draft-2026-10-27b","consent":{"autoRenew":true,"terms":true},"trialDays":7}
```

- `plan` is `personal` or `team` and must equal the workspace's `kind`; `interval` is `month` or `year`.
- `seats`: Team only, 1 to 1000, at least the workspace's current member count; default the member count. Personal accepts only `1` or no value.
- `extraStorageTb`: 0 to 100 added 1 TB blocks, default 0.
- `disclosureVersion` and `consent` (added 2026-10-13): the version of the disclosure text the app showed (`disclosureVersion` of `GET /v1/billing/offer`) and the two unticked boxes the buyer ticked (subscription policy 7.1: automatic renewal, and the Terms and the policy). Both are required (since 2026-10-23): `consent.autoRenew` and `consent.terms` must be `true` and the version must be the server's current one; the server stores them with the checkout record, with the time and the `X-ParaAir-Client` version, and the confirmation email cites that record. No released app sent checkout without them.
- `trialDays` (added 2026-10-27): the free trial the quote for this workspace showed (`quote.trialDays` of `GET /v1/billing/offer?workspaceId=`); absent or 0 for none. A different value answers 409 `disclosure_outdated`, because the buyer agreed to other terms.
- Each workspace keeps one processor customer, so every checkout and the portal use the same one. A new checkout makes the workspace's earlier unpaid checkouts unpayable (Stripe expires the session, Paddle cancels the transaction); a subscription paid for one of them anyway is cancelled and refunded in full.
- 200 `{"url":"https://…"}`: open it in the browser. Stripe returns its hosted checkout; Paddle returns the service's payment link page (`<issuer>/billing/pay?_ptxn=txn_…`). The plan changes only when the processor's webhook arrives; refresh `GET /v1/me` afterwards. A subscription whose plan, interval, seats or storage differ from what this request asked for is not applied: it is cancelled and refunded.
- The browser comes back to `<issuer>/billing/success` or `<issuer>/billing/cancel` (plain pages that say to return to ParaAir).

| Status | Code | When |
|---|---|---|
| 400 | `invalid_request` | bad plan, interval, seats or storage; plan does not match the workspace kind; seats below the member count; `disclosureVersion` or `consent` missing, or a box not ticked |
| 403 | `forbidden` | the caller is not the workspace owner |
| 403 | `suspended` | the workspace is suspended |
| 404 | `workspace_not_found` | not a member of that workspace (existence never leaks) |
| 404 | `not_found` | billing is off |
| 409 | `disclosure_outdated` | `disclosureVersion` is not the server's current version, or `trialDays` is not the trial this checkout starts: fetch `GET /v1/billing/offer`, show the new text and ask for consent again |
| 409 | `busy` | the workspace already has a live subscription (`active` or `past_due`) or is being purged: use the portal; or an earlier checkout was paid and its subscription has not arrived yet: wait and refresh `GET /v1/me` |
| 429 | `rate_limited` | more than 20 checkout or portal sessions for the workspace this hour (`retryAfterSeconds`) |
| 503 | `billing_unavailable` | billing is not set up on the server (prices, keys, links, or the email and notice settings its notices need): show "plans cannot be bought right now" |
| 503 | `unavailable` | the processor could not be reached |

### `GET /v1/billing/offer`

Access token. Added 2026-10-13. What the server sells and how, so the plan sheet shows exactly what checkout records and charges. Optional query: `plan`, `interval`, `seats`, `extraStorageTb` (the same rules as checkout; `seats` defaults to 1), and `workspaceId` (added 2026-10-27: a workspace the caller belongs to, so the quote includes the free trial its checkout starts; 404 `workspace_not_found` otherwise). Without `workspaceId` the quote assumes a workspace that has never had a subscription.

```json
{"provider":"stripe","merchantOfRecord":{"name":"Link","reseller":true},"disclosureVersion":"A-draft-2026-10-27b","currency":"USD",
 "prices":[{"item":"personal_month","kind":"plan","plan":"personal","interval":"month","unitAmountCents":1000,"perMember":false},
           {"item":"team_year","kind":"plan","plan":"team","interval":"year","unitAmountCents":16000,"perMember":true},
           {"item":"storage_month","kind":"storage","plan":null,"interval":"month","unitAmountCents":1000,"perMember":false}],
 "quote":{"plan":"personal","interval":"month","seats":1,"extraStorageTb":0,"amountCents":1000,"currency":"USD",
          "trialDays":7,"firstChargeAt":"2026-11-03T14:02:11.000Z",
          "summary":["Free for 7 days, then $10.00 per month plus tax, renewing automatically every month until you cancel.","…"],
          "terms":["ParaAir Cloud Personal, billed monthly","$10.00 per month plus tax after a 7-day free trial. Renews automatically every month until you cancel.",
                   "- Today you pay nothing. Your free trial ends on November 3, 2026.","- …"],
          "consent":"I agree that my ParaAir Cloud Personal plan renews automatically after the 7-day free trial at … I agree to the Terms of Service and the …"}}
```

| Field | Meaning |
|---|---|
| `provider` | `stripe` or `paddle` |
| `merchantOfRecord` | who charges the buyer: a reseller and seller of record (policy 2.2), `{"name":"Link","reseller":true}` (Stripe Managed Payments) or `{"name":"Paddle","reseller":true}`, or `{"name":"Parafield Inc.","reseller":false}` (Stripe direct) |
| `disclosureVersion` | the current disclosure version; send it back as checkout's `disclosureVersion` |
| `currency` | the catalog currency (prices are before tax; the processor may charge local currency, shown at its checkout) |
| `prices` | the catalog items this server sells (those in its price map): `unitAmountCents` per unit per interval, `perMember` for Team |
| `quote` | with `plan` and `interval`: the amount of the first charge before tax, `trialDays` (the free trial before it, null for none) and `firstChargeAt` (when it falls: now, or when the trial ends), and the disclosure (Appendix A): `summary` (added 2026-10-27: three or four sentences the app's checkout screen leads with, namely the price and automatic renewal, how to cancel, the refund, and with a trial what a failed first payment does), `terms` (a heading, the price line, then bullets prefixed `- `; the app shows them behind "Show full terms") and the `consent` sentences (one box in the app covers both), exactly what the checkout records under `disclosureVersion`; null without them or when that plan is not sold. Links in `consent` are Markdown `[label](url)` |

Errors: 401 `unauthorized`; 404 `not_found` when billing is off; 400 `invalid_request` for bad query values; 503 `billing_unavailable` as for checkout.

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
           "readOnlyAt":"2026-10-26T00:00:00.000Z","deletionAt":"2026-11-25T00:00:00.000Z","checkoutAvailable":false,"portalAvailable":true,
           "trialDays":null,"trialEndsAt":null}
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
| `deletionAt` | 30 days after `readOnlyAt`, when known. With the server's admin-confirmed purge (the default) deletion can come later; never earlier |
| `checkoutAvailable` | the caller is the owner, billing is configured with a price for this workspace's kind, and the workspace has no live subscription |
| `portalAvailable` | the caller is the owner and the workspace has a customer with the configured processor |
| `trialDays` | added 2026-10-27: the free trial this workspace's next checkout starts with; null when there is none or `checkoutAvailable` is false |
| `trialEndsAt` | added 2026-10-27: while the subscription is in its free trial (`status` `active`), when the trial ends and the first charge falls; null otherwise |

While `status` is `read_only` (and later), the workspace's own `status` is `read_only` when billing set it: uploads, commits and mkdir answer 403 `read_only` (fencing as in `errors.json`); reads, deletes (`POST …/remove`), moves (`POST …/move`) and restores from the trash keep working (subscription policy 16.1). A full refund ends the plan the same way (`read_only`). An open dispute or chargeback makes the workspace's own `status` `read_only` while `billing.status` can stay `active`, until an operator reviews it.

`usage.periodStart` and `usage.periodEnd` of a workspace with a live subscription (`billing.status` `active` or `past_due`) follow its billing date (the allowance period of the Cloud Terms): a monthly plan's current billing period, or for yearly plans monthly periods starting on the billing day at 00:00 UTC (the last day of shorter months). Other workspaces keep the UTC calendar month. `transferBytes` and `throttled` count within that period.

