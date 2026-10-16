# ParaAir CI/CD

Last updated: 2026-10-16

How ParaAir is built, tested, released and deployed on GitHub Actions, for the public app repository [parafieldai/ParaAir](https://github.com/parafieldai/ParaAir). The hosted ParaAir Cloud service lives in a separate private repository with its own pipeline, documented there. This is the canonical document for this repository; [CONTRIBUTING.md](../CONTRIBUTING.md) is the contributor-facing summary.

Status: committed on 2026-10-13. The first pull request is the first real run. See [Known gaps](#known-gaps).

## Pipeline

```text
 PUBLIC parafieldai/ParaAir
 ──────────────────────────
 issue ──> fork PR ──> CI waits ──> maintainer reads the diff ──> approves run
                                                                     │
          .github/workflows/ci.yml  (pull_request, push to main; no secrets, read-only token)
          ├── swift     xcode-27   swift build + swift test + CLI acceptance
          ├── native    xcode-27   build-juicefs.sh --test --race, swift test with the real dylib
          ├── app       xcode-27   ad hoc build-app.sh (+3 harnesses), UI snapshots -> artifact
          ├── contract  ubuntu     generate-manifests.mjs --check, check-contract.mjs
          └── site      ubuntu     check-site.py
                                                                     │ all 5 required
                                                                     v
                                                     squash merge to main (ruleset "main")
                                                                     │
          push to main ──> ci.yml again (saves caches)                │
          push to main touching site/** ──> pages.yml ──[production: reviewer]──> Cloudflare Pages "paraair"
          admin pushes tag v* (ruleset "release tags")
             └──> release.yml ──[release: reviewer]──> sign, notarize, staple ──> DRAFT GitHub Release
                                                                       (operator publishes, then runs
                                                                        scripts/update-site-release.py)
```

## Public repository CI (`.github/workflows/ci.yml`)

Runs on every `pull_request` (including forks) and every push to `main`. Pull request runs of the same PR cancel each other; pushes to `main` never cancel. There are no `paths:` filters: a required check that never starts would block the merge, so every job runs on every pull request.

| Job (required check) | Runner | Runs | Why |
|---|---|---|---|
| `swift` | `xcode-27` | `swift build --build-system native --jobs 4`, `swift test --build-system native --jobs 4`, `scripts/acceptance.sh` on the built CLI | Package and unit tests without the native library (those tests skip themselves), plus the CLI's profile/pin/cache/uploads guards on a disposable local fixture |
| `native` | `xcode-27` | `scripts/build-juicefs.sh --test --race`, then `swift test` with `STREAMDRIVE_NATIVE_LIBRARY` | The pinned, checksum-verified, patched JuiceFS bridge builds; its Go tests pass; the whole bridge package passes under the race detector except `TestMetadataAndObjectBackupRestore`, whose intermittent DATA RACE is inside JuiceFS `pkg/meta.(*dbMeta).dumpDir` (pre-existing upstream, reproduced on the untouched bridge, see `.runtime/cloud-build-20261009/engine.md`); then every Swift test, including the native-backend ones, runs against the real dylib |
| `app` | `xcode-27` | `scripts/build-juicefs.sh`, `brew install xcodegen`, ad hoc `scripts/build-app.sh`, `scripts/render-ui-snapshots.sh` | The app, CLI helper and FSKit extension build and verify; `build-app.sh` itself runs the FSKit callback harness, the native mount lifecycle test and the drive appearance test (no registration, mount or launch); the snapshot harness checks presentation logic and renders the home window, menu panel and Storage Settings in light and dark mode as PNGs, uploaded as the `ui-snapshots` artifact (14 days) |
| `contract` | `ubuntu-24.04` | `node contract/paraair-cloud-v1/generate-manifests.mjs --check`, `node scripts/check-contract.mjs` | `manifests.json` is current; `errors.json` codes are unique snake_case with 4xx/5xx statuses, boolean `fences` and Darwin errno names whose values match Darwin; `paths.json` results are canonical paths or known errnos. The Swift side of the contract (`ParaAirCloudContractTests`) runs in `swift` |
| `site` | `ubuntu-24.04` | `python3 scripts/check-site.py site` | `index.html`, `pricing.html`, `styles.css`, `motion.js`, `_headers` exist; on every `*.html` page, local links and `#fragments` (including cross-page ones) resolve; no em dash in visible copy, `motion.js` or `styles.css`; the word "unlimited" never appears in visible copy; no inline script, `<style>`, `style=` or `on*=` handler that the `_headers` CSP would block |

### Runners

Checked on 2026-10-13 against the live [runner-images README](https://github.com/actions/runner-images/blob/main/README.md), the [xcode-27 image readme](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md), the [macos-26 image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) and [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners):

- `macos-26` exists (arm64, macOS 26.6, Xcode 26.6 default with macOS SDK 26.5). It **cannot build the app**: `NativeMount.swift` and `StreamDriveApp.swift` call `FSClient.mountSingleVolume` and `openFileSystemExtensionsSettings`, which FSKit declares `FSKIT_API_AVAILABILITY_V3`, that is `API_AVAILABLE(macos(27.0))`, present only in the macOS 27 SDK.
- `xcode-27` is a public preview image ([announcement](https://github.com/actions/runner-images/issues/14404)): arm64 M1, 3 cores, 7 GB RAM, 14 GB SSD, macOS 27.0.1, Xcode 27.0 (27A266a, default), 27.1 and 27.2 beta. 27A266a is the same Xcode build used on the development Mac. All three macOS jobs use it for one toolchain, and pin `DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer`.
- Each macOS job starts with a toolchain check that fails with an explicit message if that Xcode or the macOS 27 SDK is missing, so an image change shows up as one clear error rather than compiler noise. A required check is never skipped silently.
- Go is only in the image's tool cache, so `actions/setup-go` selects Go 1.25 (the JuiceFS `go.mod` asks for 1.25.10; `build-juicefs.sh` keeps `GOTOOLCHAIN=auto`).
- `build-juicefs.sh` and `build-app.sh` refuse to start below 100 GiB free (workspace disk policy). Hosted runners have far less, so CI sets `PARAAIR_CI_MIN_FREE_GIB=8`. The scripts honour that variable only when `CI=true` and say so when it is set elsewhere; locally the 100 GiB floor is unchanged.
- actionlint does not know the `xcode-27` label yet; `.github/actionlint.yaml` declares it.

To move to another image: change `runs-on` and `DEVELOPER_DIR` in `ci.yml` and `release.yml` together, from the image readme.

### Caches

`native` and `app` restore `.build-native/juicefs.tar.gz`, `.build-native/gomodcache` and `.build-native/gocache`, keyed on the hash of `scripts/build-juicefs.sh` and `scripts/patch-juicefs.py` (pinned revision, checksum, patch) plus the bridge sources, with a prefix fallback. Only `native` on a push to `main` saves the cache. Caches written by a pull request are scoped to that pull request anyway; saving only from `main` keeps the shared cache built from reviewed code. Release builds use no cache. The tarball is checksum-verified and modules are verified against `go.sum` on every run regardless.

## Outside contributions

Issues and pull requests are open to everyone (`has_issues`, `has_pull_requests`, `pull_request_creation_policy: all`). Blank issues are off; the bug and feature forms collect version, macOS and storage, and the issue chooser links security reports to the private advisory form.

1. **Issue.** The contributor opens or comments on an issue.
2. **Fork pull request.** CI is triggered with the `pull_request` event: the fork's code, read-only `GITHUB_TOKEN`, no secrets.
3. **CI waits.** The repository's fork pull request approval policy is `all_external_contributors`: every run from anyone who is not a member or owner of the repository waits for approval, not only first-time contributors. The stricter setting matters here because the `first_time_contributors` policies stop asking once a person has had one pull request merged, and one merged typo fix would then let later pull requests run modified workflows unreviewed.
4. **Maintainer reviews the diff before approving.** Read every change under `.github/`, `scripts/`, `Package.swift`, `macOS/project.yml`, `native/` and anything a job executes. Approve only if the change does nothing but build and test. Each new push needs approval again. Pending approvals expire after 30 days.
5. **Checks.** All five required checks must pass. Review threads must be resolved.
6. **Squash merge.** The only allowed merge method; the head branch is deleted afterwards.

Dependabot's pull requests come from branches in this repository, not forks, so they run without approval, also with a read-only token and no secrets.

## Security model

- **No secrets in pull request CI.** `ci.yml` references none. Secrets live only in the `release` and `production` environments and are read only by jobs that passed the environment's required reviewer.
- **Never `pull_request_target`.** Workflows triggered by `pull_request_target` run in the base repository's context with secrets and bypass the approval policy ([GitHub docs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)). No workflow here uses it, nor `workflow_run`.
- **Read-only token.** The repository default is `read`, every workflow sets `permissions: contents: read`, and only the release job raises it to `contents: write` to create the draft release. Actions may not approve pull requests.
- **Pinned actions.** Every `uses:` is a full commit SHA with the tag in a comment, resolved from the GitHub API on 2026-10-13. The repository requires SHA pinning (`sha_pinning_required`) and allows only GitHub-owned actions plus the explicit list the workflows use. Dependabot proposes updates weekly with a 7-day cooldown. All checkouts use `persist-credentials: false`.
- **Pinned deploy tooling.** `pages.yml` installs Wrangler from `.github/deploy-tools/package-lock.json` with `npm ci --ignore-scripts`, so no unpinned package runs next to the Cloudflare token. The private repository deploys with its own locked `wrangler` devDependency.
- **Environments.** `release` (tags `v*` only) and `production` (branch `main` only) require the operator's approval; self-review stays allowed because there is one maintainer. Deployment refs are custom policies naming `main` and `v*`, both protected by rulesets, rather than "protected branches only", which does not cover tags.
- **Refs.** `main` needs a pull request, the five checks and linear history; no force push or deletion. `v*` tags can be created, moved or deleted only by repository admins, so only the operator can start a release.
- **Repository security.** Secret scanning and push protection on; private vulnerability reporting on ([SECURITY.md](../SECURITY.md)).
- **Release signing.** The Developer ID identity is imported into a temporary keychain with a random password, given a partition list so `codesign` needs no prompt, and deleted at the end of the job, with the `.p12`, profiles and notary key files.

## Continuous delivery

### Mac app release (`.github/workflows/release.yml`)

Trigger: pushing a `v*` tag, or **Run workflow** with **Use workflow from: Tags > vX.Y.Z** to rebuild an existing tag. The job waits for approval on the `release` environment.

Steps on `xcode-27`: tag format check (`vMAJOR.MINOR.PATCH[-PRERELEASE]`, prerelease tags make a prerelease), configuration check (fails listing every missing secret or variable), `build-juicefs.sh --test` from an empty cache, XcodeGen, temporary keychain, `build-app.sh` with the signing variables it already supports, a check that the app's `CFBundleShortVersionString` equals the tag's version, then:

1. zip the app, `notarytool submit --wait`, print the notary log on rejection, `stapler staple`, `stapler validate`, `spctl --assess`
2. `ParaAir-<version>.zip` of the stapled app
3. `ParaAir-<version>.dmg` (app plus an Applications link, UDZO), signed with the same identity, notarized, stapled, assessed
4. `.sha256` for both, then a **draft** GitHub Release with all four files and the checksums in its notes. An existing draft gets its assets replaced; a published release is never touched.

This is the artifact layout of the hand-made `v0.1.0-alpha.1` release. After publishing the draft, run `python3 scripts/update-site-release.py --tag vX.Y.Z --asset dist/ParaAir-X.Y.Z.dmg` (with the downloaded DMG; it updates the download on `index.html` and `pricing.html`) and merge that change to deploy the site.

Signing variables passed to `build-app.sh`: `STREAMDRIVE_SIGN_IDENTITY` (SHA-1 of the imported identity), `STREAMDRIVE_TEAM_ID`, `STREAMDRIVE_APP_PROVISIONING_PROFILE`, `STREAMDRIVE_EXTENSION_PROVISIONING_PROFILE`, `STREAMDRIVE_CLI_PROVISIONING_PROFILE` (decoded to the runner's temp directory), `STREAMDRIVE_SIGNING_MODE=interactive`, `STREAMDRIVE_CLOUDFLARE_CLIENT_ID`, and `PARAAIR_CLOUD_BASE_URL` when set. `interactive` makes the script call `/usr/bin/codesign` directly; the default `noninteractive` mode re-launches each `codesign` in a new launchd Security session in the `gui/<uid>` domain, which has only been validated on the operator's Mac. The temporary keychain's partition list already prevents any prompt.

The disk image is built by `scripts/make-dmg.sh` for both hand-made and CI releases: [dmgbuild](https://github.com/dmgbuild/dmgbuild) 1.6.7 lays out the app, an Applications link and the background from `scripts/dmg-background.swift` (a sage mid tone on which Finder's black or white icon labels both read at about 4.5:1; everything sits in the top 300 points because Finder on macOS 27 adds a toolbar band and a bottom bar).

### In-app updates (Sparkle)

From v0.1.0-alpha.2 the app updates itself with [Sparkle](https://sparkle-project.org) 2.10.0. `scripts/fetch-sparkle.sh` downloads that exact release and checks its SHA-256. `build-app.sh` links it, embeds it without its XPC services (they exist for sandboxed apps; ParaAir isn't sandboxed) and signs its `Autoupdate` tool, `Updater.app` and the framework with the app's identity before the app itself. Builds without `PARAAIR_RELEASE_TAG` never start the updater.

- **Feed.** `https://paraair.pages.dev/appcast.xml`, the file `site/appcast.xml`, deployed with the site. Archives are the release zips on GitHub.
- **Signatures.** Every archive and the feed itself are signed with one EdDSA key (`SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`). The public key is `SUPublicEDKey` in `macOS/App/Info.plist`. The private key lives only in the release Mac's login Keychain under the Sparkle account `paraair`. Back it up with `generate_keys --account paraair -x <file>` into the password manager and delete the file. Losing it means no installed copy can ever accept another update.
- **Publishing an update.** After the zip is notarized and stapled, run `python3 -I scripts/make-appcast.py --app <stapled app> --archive dist/ParaAir-<version>.zip --tag vX.Y.Z[-stage.N] --notes <notes.html>`. It reads the version and build from the app, signs the archive, puts the entry first, re-signs the feed and verifies it; `--check` validates a feed. Publish the GitHub Release first, then deploy the site with the new feed, so the feed never points at a missing archive. CI does not sign the feed yet: that needs the private key as a `release` secret (`sign_update --ed-key-file`).
- **Drives during an update.** The file system extension serving every mounted drive runs from the bundle an update replaces. So ParaAir ejects all its drives before installing: when Sparkle relaunches the app, and on any quit while an update is waiting to install on quit (`applicationShouldTerminate`). A newer copy opened from the disk image ejects them too, before it replaces the installed one. A drive with open files keeps the update waiting and says so (`UpdateGate`). Files waiting to upload stay on the Mac and upload once the drive reconnects.
- **Reminders.** ParaAir is a menu bar app. When a scheduled check finds an update while ParaAir isn't in front, it shows a row in the menu bar panel and home window ("… is ready to install", **Install Update…**) instead of an alert behind other apps. This is Sparkle's gentle reminders (`SPUStandardUserDriverDelegate`). Sparkle still shows its own window when the check is user-initiated or ParaAir is in focus. Tested 2026-10-16 on build 21: a scheduled check (`SULastCheckTime` set to fall due 90 seconds after launch) found a newer test entry while ParaAir was in the background and showed the row, with no Sparkle window.
- **Development identity.** Unsigned builds use `dev.streamdrive.app.dev`, with extension `.dev.filesystem`, CLI `.dev.cli` and volume type `streamdrive-dev`. Signed builds keep the release identifiers. See `ParaAirBundle.swift`, `build-app.sh` and `prepare-signing.py configure --development`. A development copy can no longer be taken for the installed app.
- **Disk-image installs** unregister the copy they launched from (`lsregister -u`, `pluginkit -r`) right after copying into Applications, so macOS keeps no record of a copy that has gone away.
- **FSKit approval across updates (tested 2026-10-16, macOS 27.2).** On a clean Mac (restarted, one registered ParaAir copy, alpha.2 installed from the quarantined DMG) both update paths kept the file system extension enabled with no restart and no switch:
  - Install on quit, 16 to 17.
  - Install and Relaunch, 17 to 18.
  - Install on quit, 18 to 21 (the signed, notarized alpha.3 zip, from a local signed test feed).

  ParaAir never left FSKit's enabled list. A once-a-second watch saw 0 samples off. The drive was ejected before each install and remounted about 1 second after relaunch, and a 3 MB marker file kept its SHA-256. The failure seen on 2026-10-15 came from development debris: identical build copies in `.build`/`.runtime`, a mounted-then-ejected DMG, a 17-to-16 rollback and forced re-registrations. That left LaunchServices with stale data, which Apple DTS calls a LaunchServices bug that is much rarer on end-user Macs. Clearing it took a restart, because `fskitd` is protected by System Integrity Protection.
  - **Where FSKit enablement lives.** `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist` (bundle IDs). On macOS 27.2 the per-app sheet in System Settings (ⓘ next to "ParaAir Extensions" → FSKit Modules) records an election but never writes this list, so its switch flips back. **General → Login Items & Extensions → By Category → File System Extensions** does write it; `FSClient.openFileSystemExtensionsSettings()` opens that view. Point users there, never at the per-app sheet.
  - **Keep this Mac clean.** Never leave unzipped ParaAir copies where macOS can register them (`.build` and `.runtime` carry `.metadata_never_index`), never install an older build over a newer one, and give development builds their own bundle ID.
  - **A drive lost on relaunch (seen once, 2026-10-16).** Just after `lsregister -u` removed other ParaAir copies, quitting and reopening the installed app while a drive was mounted: PlugInKit stopped the running extension, and the drive unmounted 5 seconds later. The new app had already seen the drive as mounted and didn't mount it again. A plain quit, or a relaunch with the drive mounted, kept it mounted. Follow-up: notice a drive that unmounts on its own and mount it again.
  - **Local fixture profiles** (`connect --fixture-root`) bind the folder's device number, which changes after a restart, so they refuse to attach afterwards with EXDEV. That affects tests only; make a new fixture profile.

### Site (`.github/workflows/pages.yml`)

Trigger: a push to `main` that changes `site/**`, `scripts/check-site.py`, `.github/deploy-tools/**` or the workflow, or **Run workflow** on `main`. Runs `check-site.py`, then waits for approval on `production`, installs the pinned Wrangler and runs `wrangler pages deploy site --project-name=paraair --branch=main` with the commit hash and subject.

### Secrets and variables

Set secrets with `gh`, reading from a file or pipe so values never appear in shell history, for example `base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release -R parafieldai/ParaAir`. Never commit any of them; `.gitignore` already excludes `*.p12` and provisioning profiles.

**parafieldai/ParaAir, environment `release`** (secrets)

| Name | Source |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate and private key exported as `.p12` from Keychain Access, base64 |
| `DEVELOPER_ID_P12_PASSWORD` | the export password chosen for that `.p12` |
| `APP_PROVISIONING_PROFILE_BASE64` | Developer ID provisioning profile for `dev.streamdrive.app` (FSKit Mounter, shared Keychain group), base64 |
| `EXTENSION_PROVISIONING_PROFILE_BASE64` | Developer ID profile for `dev.streamdrive.app.filesystem` (FSKit Module), base64 |
| `CLI_PROVISIONING_PROFILE_BASE64` | Developer ID profile for `dev.streamdrive.app.cli`, base64 |
| `NOTARY_API_KEY_P8_BASE64` | App Store Connect > Users and Access > Integrations > Team Keys: a key with Developer access, the `.p8` (downloadable once), base64 |
| `NOTARY_API_KEY_ID` | that key's Key ID |
| `NOTARY_API_ISSUER_ID` | the Issuer ID shown on the same page |

The three profiles are the ones `scripts/prepare-signing.py validate` already accepts locally: macOS, ProvisionsAllDevices, the signing certificate included, the `<team>.dev.streamdrive.credentials` Keychain group.

**parafieldai/ParaAir, repository variables**

| Name | Value |
|---|---|
| `STREAMDRIVE_TEAM_ID` | Apple team ID; the published v0.1.0-alpha.1 is signed by team `3LHSL95J9H` |
| `STREAMDRIVE_CLOUDFLARE_CLIENT_ID` | the public Cloudflare OAuth client ID (from `cloudflare-oauth-client.json`); required for signed builds so R2 sign-in can renew |
| `PARAAIR_CLOUD_BASE_URL` | optional; the `https://` origin of ParaAir Cloud once it is live. Leave unset until then |

**parafieldai/ParaAir, environment `production`** (secrets)

| Name | Source |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare > My Profile > API Tokens > custom token, permission Account > Cloudflare Pages > Edit, limited to the account that owns the `paraair` project |
| `CLOUDFLARE_ACCOUNT_ID` | that account's ID (dashboard sidebar) |

## Repository settings

`scripts/github-settings.sh` applies the settings as code. Without arguments it is a dry run: read-only GET requests, then every write it would make with its JSON body. `--apply` performs them. It is idempotent: rulesets are updated in place by name, deployment policies are added only when missing.

Public repository:

| Setting | Value |
|---|---|
| Issues, pull requests | on; anyone may open pull requests; discussions untouched |
| Merging | squash only, title from the PR title, body from the PR body; auto-merge off; head branches deleted on merge; "Update branch" offered |
| Actions | enabled; selected actions only: GitHub-owned plus `actions/cache`, `actions/checkout`, `actions/setup-go`, `actions/setup-node`, `actions/upload-artifact`; full-SHA pinning required |
| Workflow token | read-only by default; Actions cannot approve pull requests |
| Fork PR approval | `PUT /repos/{owner}/{repo}/actions/permissions/fork-pr-contributor-approval` with `approval_policy: all_external_contributors` (enum verified against GitHub's REST OpenAPI description on 2026-10-13: `first_time_contributors_new_to_github`, `first_time_contributors`, `all_external_contributors`) |
| Security | private vulnerability reporting, secret scanning, push protection |
| Ruleset `main` | default branch; pull request required (0 approvals, threads resolved, squash only); required checks `swift`, `native`, `app`, `contract`, `site` from the GitHub Actions app (id 15368); linear history; no force push or deletion; repository admin bypass |
| Ruleset `release tags` | `refs/tags/v*`: creation, update and deletion restricted; repository admin bypass |
| Environment `release` | required reviewer parafieldai; deployments from tags `v*` |
| Environment `production` | required reviewer parafieldai; deployments from branch `main` |

Why squash only: an outside contributor's branch history (fixups, merges from `main`) never lands on `main`; every change is one reviewed commit that `git revert` undoes; it satisfies the linear-history rule without asking contributors to rebase. Why zero required approvals: the only maintainer cannot approve their own pull requests, and merging an outside pull request is the review. Why admin bypass: a solo maintainer must not be locked out when, for example, the preview runner image is unavailable; GitHub records each bypass. `strict` up-to-date checks are off to avoid an extra approval round for every outside pull request when `main` moves; `main` is re-tested on every push.

## Runner cost

- Public repository: standard GitHub-hosted runners, macOS included, are free and unlimited ([billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)). Estimated wall time per pull request: `swift` 10 to 15 minutes, `native` 20 to 30 cold or 10 to 15 with a warm cache, `app` 15 to 25, `contract` and `site` under a minute. A free account runs up to 5 macOS jobs at once. Release runs take 30 to 60 minutes, mostly notarization. All estimates until the first runs are measured.
## Known gaps

- **First runs.** The first pull request will show runner-specific problems: tests that touch the login Keychain, offscreen AppKit rendering and the FSKit harnesses on a hosted VM, real wall times, and whether `PARAAIR_CI_MIN_FREE_GIB=8` leaves enough room.
- **Preview image.** `xcode-27` is a public preview and may queue or change. The `app` check is required; the admin bypass is the escape hatch.
- **Release signing in CI is unproven.** `build-app.sh` and `prepare-signing.py` are reused unchanged, but the temporary-keychain route with `STREAMDRIVE_SIGNING_MODE=interactive`, the notarization, the DMG and stapling are this workflow's own steps; `build-app.sh` does not notarize or package. The v0.1.0-alpha.1 release was produced by hand on the operator's Mac.
- **Versioning.** Tags drive the version: `release.yml` passes `PARAAIR_VERSION` (the tag's numbers), `PARAAIR_RELEASE_TAG` and `PARAAIR_BUILD` (the commit count, so it only increases) to `build-app.sh`, which defaults to 0.1.0 (1) for local builds.
- **Architecture.** Release builds are arm64 only, matching the native library built on the runner and the stated Apple Silicon requirement.
- **`swift build --build-system native`** prints a deprecation warning on Swift 6.4. CI uses it because the project's tests and notes do.
- **Snapshots are not compared.** The `ui-snapshots` artifact is for human review; there is no golden-image diff.
- **Static analysis of workflows** is actionlint (with shellcheck) only; zizmor was not run.
