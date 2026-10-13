# Contributing to ParaAir

Last updated: 2026-10-13

Issues and pull requests are welcome from anyone. This page covers building and testing locally, what CI checks on a pull request, and how outside contributions are reviewed. The full pipeline is described in [docs/ci-cd.md](docs/ci-cd.md). Security problems go through [SECURITY.md](SECURITY.md), never a public issue.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Keep a pull request to one focused change. Include tests when behaviour changes.
- Never commit credentials, bucket names, account IDs, personal paths, `.build*`, `.runtime/` or other generated output. `.gitignore` covers the usual ones.

## Build and test locally

Requirements: an Apple Silicon Mac, Swift and Go. The app additionally needs **Xcode 27 (macOS 27 SDK)**, because it calls FSKit APIs introduced in macOS 27, and XcodeGen (`brew install xcodegen`). The contract checks need Node 22 or later. The build scripts refuse to start with less than 100 GiB free disk (this workspace's policy).

Each block below is what the CI job of the same name runs.

```sh
# swift: package build, unit tests (native-library tests skip themselves), CLI acceptance on a local fixture
swift build --build-system native --jobs 4
swift test --build-system native --jobs 4
bash scripts/acceptance.sh "$(swift build --build-system native --show-bin-path)/streamdrive"

# native: pinned JuiceFS bridge, its Go tests, the Go race detector run, then Swift tests against the real library
scripts/build-juicefs.sh --test --race
STREAMDRIVE_NATIVE_LIBRARY="$PWD/native/lib/libstreamdrive.dylib" swift test --build-system native --jobs 4

# app: ad hoc app build (runs the FSKit callback, mount lifecycle and drive appearance harnesses), then UI snapshots
scripts/build-app.sh
bash scripts/render-ui-snapshots.sh .runtime/ui-snapshots

# contract: the public ParaAir Cloud API fixtures
node contract/paraair-cloud-v1/generate-manifests.mjs --check
node scripts/check-contract.mjs

# site: static checks of the landing page
python3 scripts/check-site.py
```

None of these install, register, mount or sign anything, and none needs network access to your storage. `scripts/build-app.sh` without signing variables produces an ad hoc build for local testing only.

If you change the UI, attach before/after PNGs from `render-ui-snapshots.sh` to the pull request. CI uploads the same set as the `ui-snapshots` artifact.

## What CI runs on a pull request

| Check | Runner | What it proves |
|---|---|---|
| `swift` | macOS 27, Xcode 27.0 | The package builds; unit tests and CLI acceptance pass |
| `native` | macOS 27, Xcode 27.0 | The pinned JuiceFS bridge builds and passes its Go tests, with and without the race detector; Swift tests pass against the real library |
| `app` | macOS 27, Xcode 27.0 | The app and FSKit extension build; the callback, mount lifecycle and drive appearance harnesses pass; UI snapshots render |
| `contract` | Ubuntu | `manifests.json` matches its generator; error and path fixtures are well formed |
| `site` | Ubuntu | The landing page files exist, local links resolve, no em dash in visible copy, nothing the CSP would block |

All five must pass before a pull request can merge. CI uses no secrets and a read-only token; nothing is signed, notarized or deployed from a pull request.

## Pull requests from outside contributors

If you are not a member of this repository, **CI does not start on your pull request until a maintainer approves the run.** The pull request shows the checks as waiting for approval; that is expected and does not mean anything is wrong.

Why: a pull request's workflows run the code in the pull request, including any change to `.github/workflows/` or the build scripts, on GitHub's runners. Before approving, the maintainer reads the diff, especially `.github/`, `scripts/`, `Package.swift` and `macOS/project.yml`, to make sure it does nothing beyond building and testing. Later pushes to the pull request wait for approval again.

The flow:

1. Open an issue (or comment on an existing one) describing the change.
2. Fork, branch, commit, and open a pull request against `main`. Fill in the template.
3. CI waits. A maintainer reviews the diff and approves the run.
4. Fix anything the checks or the review find; each push waits for approval again.
5. The maintainer squash-merges: your pull request becomes one commit on `main`, titled after the pull request. The head branch is deleted afterwards.

Maintainers may push small fixes to your branch if you allow edits from maintainers.

## License of contributions

ParaAir is licensed under the [Apache License 2.0](LICENSE). Contributions use the same license, inbound = outbound: as section 5 of the license states, anything you intentionally submit for inclusion is under the Apache License 2.0 without additional terms or conditions. There is no contributor license agreement and no sign-off (DCO) requirement. Only submit work you have the right to license this way.
