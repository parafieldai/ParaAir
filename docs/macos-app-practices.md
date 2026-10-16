# macOS app practices and ParaAir gap analysis

Last updated: 2026-10-13

Scope: shipping ParaAir (SwiftUI menu-bar app, FSKit module `StreamDriveFS.appex`, bundled CLI) outside the Mac App Store on macOS 26 and 27. Part 1 is what good looks like, cited to the numbered [Sources](#sources). Part 2 is the ParaAir gap table. Claims that could not be confirmed are listed under [Unverified](#unverified-claims-and-open-tests). Sources were read on 2026-10-13; Apple pages were read from the live documentation (which already lists macOS 27.x availability).

## Part 1: what good looks like

### 1. Distribution

- **Sign inside out, never with `--deep`.** Sign each nested code item first, then its container. Entitlements go on main executables only, never on libraries. Developer ID builds use `--timestamp` and `-o runtime`. Restricted entitlements such as `keychain-access-groups` need an embedded Developer ID provisioning profile [3]. `--deep` applies one set of options to every nested item and is the wrong tool for signing; it is fine for `--verify` [7].
- **Hardened runtime with no exceptions unless required.** Library validation is on by default: libraries must be signed by Apple or by the same Team ID. Gatekeeper runs extra checks on programs that disable it [5][6].
- **Notarize every distributed container and read the log every time.** Requirements: Developer ID certificate, hardened runtime, secure timestamp, no `get-task-allow` [1]. Use `notarytool` (an App Store Connect API key works in CI); check the log even when the status is Accepted [2]. Staple the app and the DMG; re-signing invalidates a staple [9].
- **Test like a user.** Each release candidate: a fresh VM snapshot, a browser download (so the file is quarantined), optional offline launch to prove the staple. Quick checks: `syspolicy_check distribution App.app` (macOS 14+) and `spctl -a -t open -vvv --context context:primary-signature App.dmg` [8]. Since macOS 15, users can no longer Control-click past Gatekeeper; they must go to System Settings > Privacy & Security [10], so notarization problems become support tickets.
- **Container.** A notarized, Developer ID signed DMG with an `/Applications` link is the recommended website download; for zip or tar keep only the app inside [21]. Zip with `ditto -c -k --keepParent` [4]. A PKG is only worth it when something must be installed outside the app bundle. `hdiutil` supports `ULFO` (lzfse) and `ULMO` (lzma, macOS 10.15+) besides `UDZO` [20].
- **App Translocation.** A quarantined app launched from a disk image, an archive or Downloads runs from a randomized read-only location [12]. Moving it with Finder clears that state. There is no supported way to detect translocation or to find the original path; Apple's advice is to work either way [11]. Sparkle cannot update an app on a read-only or translocated path and by default does not tell the user [21].
- **Versions.** `CFBundleShortVersionString` is the user-visible three-integer version [13]. `CFBundleVersion` must increase before each distributed build [14]; Sparkle compares it [21], and Sparkle's `sparkle:version` is not meant for git identifiers [23].
- **Architecture and minimum OS.** macOS 27 runs only on Apple silicon Macs [15], so arm64-only is natural from 27. `FSPathURLResource` exists from macOS 26.0 [16]; `FSClient.mountSingleVolume` and `openFileSystemExtensionsSettings()` from 27.0 [17][18]. A freeze after an unclean FSKit unmount was reported fixed in the macOS 26.4 beta, with no backport to 15 [19].

### 2. Updates

- **Sparkle 2 is the standard updater.** Current release 2.10.0 (2026-09-13) requires macOS 12 or later [27]. Setup: `SUFeedURL` over HTTPS, `SUPublicEDKey`, EdDSA-signed archives; `generate_appcast` writes signatures and delta files [21][23].
- **Harden the feed.** `SUVerifyUpdateBeforeExtraction` (2.7.3+) and `SURequireSignedFeed` (2.9+, signs appcast and release notes) [22]. Key rotation: change either the Developer ID certificate or the EdDSA key, not both; with verify-before-extraction, an EdDSA key change needs a Developer ID signed DMG [21].
- **Key custody in CI.** `generate_keys -x` exports the private key for backup [32]. `generate_appcast` and `sign_update` take `--ed-key-file -` to read the key from a secret on stdin; `-s` is deprecated [30][31].
- **Release controls.** `sparkle:channel` plus `allowedChannelsForUpdater:` for beta tracks, `sparkle:minimumSystemVersion` per item, critical updates, phased rollout over 7 groups [23][28]. Deltas fall back to the full archive on failure and reject code-signing data stored in extended attributes [24].
- **Unsandboxed host.** The XPC services are only for sandboxed apps; unsandboxed apps can remove them [25].
- **Menu-bar apps.** Background (dockless) apps should implement gentle reminders (`supportsGentleScheduledUpdateReminders`, Sparkle 2.2+) and switch to a regular activation policy while showing an update [26]. `SUAutomaticallyUpdate` installs silently on quit; `SUScheduledImpatientCheckInterval` (default one week) surfaces it if the app never quits [22]. Delegate hooks to control timing: `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`, `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`, `updaterShouldRelaunchApplication(_:)` [28].
- **How the install happens.** Sparkle swaps the bundle atomically, releases the new copy from quarantine and runs a Gatekeeper scan [29]. That matches Apple's rule to replace signed code rather than modify it in place [33]. Since macOS 13, apps from the same Team ID may modify the bundle; `NSUpdateSecurityPolicy` customizes that [34].
- **FSKit specifics (the hard part).**
  - Updating or deleting the containing app terminates the FSKit extension and unmounts its volumes without a clean `synchronize` (FB21287341, FB21287688). Apple DTS: think in terms of the app, keep an app running while a volume is mounted [19].
  - After a Sparkle replace, `lsd` can register the appex under a new identity while `extensionkitservice` keeps the old one, so the next mount fails with `com.apple.extensionKit.errorDomain error 2`. A developer's workaround: on first launch of a new `CFBundleVersion`, run `lsregister -f` on the app and `pluginkit -a` on the appex. DTS: "None of this should be necessary", but no objection to it [35]. macFUSE 5.2.0 ships a similar workaround [37]; the same class of failure is reported on macOS 26.0.1 release builds and the macOS 27 beta [36]. The same report says System Settings still showed the extension enabled after the update [35].

### 3. First run and permissions

- **Onboarding.** Fast and optional; postpone nonessential setup; request permissions inside onboarding only when the app cannot function without them, explaining why [38]. Notifications: ask in context, or use `.provisional` to deliver quietly first [39].
- **Login item.** `SMAppService.mainApp` (macOS 13+): `register()` makes the app launch at later logins; `unregister()` stops future launches without quitting [40][41][42]. `.requiresApproval` is also returned when the user revokes consent in System Settings [43]; `openSystemSettingsLoginItems()` opens the pane [40]. Users manage items in System Settings > General > Login Items; `sfltool dumpbtm` and `sfltool resetbtm` help testing [44]. The Mac App Store rule (not binding on Developer ID, still the norm users expect): no launch at login without consent [45].
- **Move to Applications.** No Apple API exists and translocation cannot be detected in a supported way [11]. LetsMove, the common library, was last pushed in 2022 and does not support sandboxed apps [46].
- **Menu-bar app conventions.** `LSUIElement` means `.accessory`: no Dock icon and no menu bar [47]. HIG: show a menu rather than a popover from a menu bar extra, let people decide whether it is shown, and do not rely on it being present [48]. Current macOS lets users switch any app's item off in System Settings > Menu Bar > Allow in the Menu Bar [49]. `MenuBarExtra(isInserted:)` supports a user toggle; a menu-bar-only app is terminated if its extra is removed [50]. A `Settings` scene enables the Settings item and Command-Comma [51]; HIG: settings live in the app menu, the window title is "App Name Settings" for a single pane, and it restores the last pane [52].
- **FSKit enablement.** `FSClient.installedExtensions` and `FSModuleIdentity.isEnabled` (macOS 15.4+) give live state [53][54]. On 27, `openFileSystemExtensionsSettings()` opens the File System Extensions pane [18]; `mountSingleVolume` needs `com.apple.developer.fskit.mount`, mounts under `/Volumes`, and only sees modules visible to the caller [17]. macOS 26 has no public deep link.
- **Local network.** macOS 15+ applies local network privacy. App extensions share the container app's state; background-type extensions are denied while the state is undetermined. Put `NSLocalNetworkUsageDescription` in the app's Info.plist, not the extension's [55].

### 4. Finder integration

- **Sidebar favorites.** `kLSSharedFileListFavoriteItems` has been deprecated since macOS 10.11 [56]; no supported replacement was found. The user route is drag or Control-Command-T ("Add the selected item to the sidebar") [57]. A mounted volume already appears under Locations without any API.
- **Volume name and capabilities.** The name comes from `FSVolume(volumeID:volumeName:)` [58]. `FSVolume.SupportedCapabilities` declares hidden files, document IDs, volume sizes, links and case format [59].
- **macOS 27 FSKit changes.** `FSVolume.Handler` and related handler protocols replace the deprecated operations protocols, with richer results and caller user and group IDs; `FSVolume.DataCacheHandler` enables kernel data caching [60][61][64]. Apple engineers expect a volume to conform to both the old and new protocols to support older systems [62]. Extended attributes go through `FSVolume.XattrHandler` (27) [63]. `DataCacheHandler` is aimed at network-style file systems where data changes outside the kernel [81].
- **Spotlight and search.** Spotlight's index is Finder search's primary mechanism, and the system avoids indexing remote volumes [65]. How Spotlight treats an FSKit volume is not documented (see Unverified).

### 5. Reliability and support

- **Logging.** Use `Logger`; leave log points on in release builds; dynamic strings are private by default; `.private(mask: .hash)` keeps correlation without content [66][67]. Every sysdiagnose includes a log snapshot; `sudo log collect --last 5m` captures recent entries [66].
- **Reading logs from the app.** `OSLogStore.local()` needs an admin user and the `com.apple.logging.local-store` entitlement [68]; the `.currentProcessIdentifier` scope (macOS 12+) reads only the calling process [69]. `log show` reportedly returns nothing for non-admin users [70].
- **Crash reports.** The Xcode Crashes organizer only covers App Store and TestFlight; for other Mac apps users find reports in Console > Crash Reports [71].
- **MetricKit.** On-device; diagnostic reports arrive immediately on macOS 12+; macOS 27 adds `MetricManager` with async sequences, and `MXMetricManager` is deprecated in 27.2 [72][73][74]. Nothing leaves the Mac unless the app sends it.
- **Privacy manifest.** Data-collection declarations apply to all platforms, but required-reason API declarations are specified for iOS, iPadOS, tvOS, visionOS and watchOS, and enforcement is at App Store Connect upload [75][76]. Optional for a Developer ID Mac app.

### 6. Security

- Minimal entitlements, hardened runtime, no runtime exceptions [5]. Same-team libraries pass library validation without `disable-library-validation` [6].
- Prefer the data protection keychain via `SecItem` with `kSecUseDataProtectionKeychain`; access groups come from provisioned entitlements; a command-line tool needs an app-like bundle to carry the profile; the data protection keychain is available only in a user login context [77].
- Bundle layout: frameworks and dylibs in `Contents/Frameworks`, helper tools in `Contents/Helpers`, login items in `Contents/Library/LoginItems` [78].
- Keep the host app unsandboxed only with a reason; the FSKit module itself runs sandboxed with network client access.
- Quarantine is part of the trust chain: Sparkle releases it only on the verified new bundle [29].

### 7. Lifecycle and HIG

- **Uninstall.** `unregister()` the login item [42]; deleting the app while mounted terminates the extension uncleanly [19]; keychain items, Application Support data and defaults stay unless the app removes them.
- **Migration.** Version on-disk formats and migrate forward before use (practice, no Apple rule).
- **Accessibility.** Text up to 17 pt needs 4.5:1 contrast in light and dark, or a higher-contrast scheme under Increase Contrast; label everything for VoiceOver; support Full Keyboard Access; audit with Accessibility Inspector [79].
- **Localization readiness.** String Catalogs extract strings and handle plurals [80].

## Part 2: ParaAir gap table

Priority: **P0** blocks the public alpha, **P1** before beta, **P2** later. Effort: S under a day, M a few days, L a week or more.

| Area | What ParaAir does today | Gap | Recommendation | Priority | Effort |
|---|---|---|---|---|---|
| Release verification | `.github/workflows/release.yml` signs, notarizes, staples, runs `spctl` on app and DMG; v0.1.0-alpha.1 was hand-made; `README.md` acceptance matrix lists clean-Mac install as unvalidated; `docs/ci-cd.md` says CI release is unproven | No quarantined-download test on a fresh machine | For every public tag: Safari-download the draft DMG into a fresh macOS VM snapshot, install, enable the extension, mount, then update to the next build. Add `syspolicy_check distribution` to `release.yml` [8] | P0 | M |
| Notary log | `release.yml` fetches `notarytool log` only when status is not Accepted | Apple says read it even on success [2] | Save the log for every submission as a workflow artifact; fail on any `issues` entry | P1 | S |
| Minimum OS and arch | `macOS/project.yml` and `scripts/build-app.sh` target 26.0; native mount is `@available(macOS 27.0, *)` in `macOS/App/NativeMount.swift`, 26 uses the CLI helper; CI builds only on `xcode-27`; arm64 only; `site/index.html` promises macOS 26 | The 26 path has no clean-Mac test; 26.0 to 26.3 lack the FSKit unclean-unmount freeze fix [19] | Decide now: 27.0 (one mount path, CI-testable, Apple silicon only [15]) or 26.4 with a 26.x clean-VM lane. Mirror it in `LSMinimumSystemVersion`, `sparkle:minimumSystemVersion` and the site | P0 | S (27) / M (26.4 lane) |
| Version display | Tag gives `PARAAIR_VERSION` 0.1.0, `PARAAIR_BUILD` commit count, `ParaAirReleaseTag` (`scripts/build-app.sh`) | Every 0.1.0-alpha.N shows as "0.1.0"; nothing in `macOS/App` displays the tag or build; commit count only rises for tags on `main` | Show "0.1.0 alpha 3 (412)" in the menu panel footer and diagnostics; set the appcast `sparkle:shortVersionString` to the tag text; tag only `main` commits [13][14] | P1 | S |
| Update mechanism | None; users re-download from the site or GitHub Releases | The first public build without an updater can never update itself | Ship Sparkle 2.10 in the first public alpha: `SUFeedURL` `https://paraair.pages.dev/appcast.xml`, `SUPublicEDKey`, `SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`; enclosure = the notarized DMG on GitHub Releases; `release.yml` runs `generate_appcast --ed-key-file -` from a `release` environment secret after the release is published; back the key up offline with `generate_keys -x`; remove Sparkle's XPC services [21][22][25][30][32] | P0 | M |
| Update while mounted | Nothing; Quit leaves the drive mounted (`MenuModel.quit()` in `macOS/App/StreamDriveApp.swift`) | Replacing the bundle kills `StreamDriveFS` and unmounts without sync [19] | In `willInstallUpdateOnQuit` / `shouldPostponeRelaunchForUpdate`: wait until no uploads are pending, eject every ParaAir volume, then install; remount after relaunch if it was mounted. Mark updates that change the module or state format as critical [23][28] | P0 | M |
| Post-update registration | Setup coordinator detects missing, ambiguous and disabled modules (`StreamDriveApp.swift`, `FinderSetupCoordinator`) | Stale ExtensionKit registration makes the first mount after an update fail with error 2 [35][36] | On first launch of a new `CFBundleVersion`: `lsregister -f` the app, `pluginkit -a` the appex, re-read `FSClient.installedExtensions`, retry the mount once, log the outcome | P0 | S |
| Move to Applications | Being added | Translocation cannot be detected in a supported way [11]; a DMG or translocated launch can register the FSKit module and login item from the wrong path; `/Applications` is not writable for standard users | Supported checks only: bundle URL inside an Applications directory and not on a read-only volume. Otherwise one modal (Move / Quit): copy with `FileManager`, clear quarantine on the copy only (as Sparkle does for updates [29]), relaunch from the new path, offer to eject the DMG; fall back to `~/Applications`; handle an existing copy (replace if older, ask to quit if running). Do not register the login item or open FSKit settings before this passes. Avoid LetsMove's private API [46] | P0 | M |
| Login item | Being added, on by default | Silent registration posts a system notification and a Login Items entry; users can revoke it [43][44] | Visible, pre-checked "Open ParaAir at login" step in the checklist; `register()` when the user continues; read `status` on every activation; on `.requiresApproval` show "Turned off in System Settings" with `openSystemSettingsLoginItems()`; never re-register after the user turned it off; `unregister()` on uninstall [40][41][42][45] | P0 | S |
| FSKit enablement UX | 27: `FSClient.openFileSystemExtensionsSettings()`; 26: `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`; re-check on activation (`openExtensionSettings`, `resumeAfterSettings`) | The 26 URL is undocumented; checklist being added | Keep; derive every checklist row from live state (`installedExtensions`/`isEnabled`, `SMAppService.status`, mount table); on 26 print the exact System Settings path as a fallback [18][53] | P1 | S |
| Spotlight and Quick Look | Quick Look range reads and benchmark harness (`README.md`) | Unknown whether `mds` indexes `/Volumes/ParaAir`; indexing would read every file and cost egress and requests [65] | On a clean Mac: `mdutil -s /Volumes/ParaAir` and object counters while idle after mount; if indexing occurs, stop it and document how | P0 | S |
| Extended attributes and quarantine | `maximumXattrSize` 0 and no xattr protocol (`macOS/Extension/StreamDriveVolume.swift`); `README.md` says xattrs are not implemented | Unknown whether `com.apple.quarantine` and `com.apple.provenance` on files saved to the drive are dropped (a Gatekeeper gap) or stored as `._` files that get uploaded | Test a Safari download onto the drive (`xattr -l`, look for `._*`). Implement `XattrHandler` (27) and `XattrOperations` (26) for at least quarantine, provenance and FinderInfo, or reject cleanly; never upload `._` files [62][63] | P1 (P0 if quarantine is lost) | M |
| Menu-bar conventions | `LSUIElement`; `MenuBarExtra` with `.window` style; `Window` scenes "ParaAir" and "ParaAir Storage Settings"; custom Quit (`StreamDriveApp.swift`) | No `Settings` scene or Command-Comma; no reopen handler, so after a user hides the item in System Settings > Menu Bar [49], opening ParaAir again from Finder is the only way back and nothing handles it; accessory apps have no menu bar [47] | `Settings` scene titled "ParaAir Settings" (General: open at login, mount at launch, updates, sidebar; Storage; Advanced: state folder, diagnostics, uninstall) [51][52]; `applicationShouldHandleReopen` opens the home window; `.regular` while a ParaAir window is open, `.accessory` after; `MenuBarExtra(isInserted:)` toggle [50] | P1 | M |
| Quit while mounted | Alert offers Keep running / Quit; the drive stays mounted | Renewal stops; a later Finder or Sparkle replace kills the extension uncleanly [19] | Default button "Eject and Quit", showing pending uploads | P1 | S |
| Finder sidebar | Automatic one-time `LSSharedFileList` insert after mount plus Add to Sidebar (`macOS/App/FinderSidebar.swift`, `macOS/CFinderSidebar/FinderSidebarBridge.h`) | Deprecated since 10.11, no replacement [56]; the native Locations entry already exists (`README.md`) | Stop auto-inserting; offer an explicit, default-off "Add to Finder sidebar" step; keep the bookmark check and the manual route (drag or Control-Command-T [57]); keep the code isolated so it can be dropped when it breaks | P1 | S |
| Volume icon | Drive appearance stores an icon; Finder shows a generic icon (`README.md`) | Custom volume icons rely on Finder metadata that a volume without xattrs cannot hold (inference) | After xattr support, test `NSWorkspace.setIcon` on the volume root; until then do not imply a Finder icon in the UI | P2 | M |
| FSKit API currency | `FSVolume.Operations`, `ReadWriteOperations`, `OpenCloseOperations` (`StreamDriveVolume.swift`) | Deprecated in the macOS 27 SDK [60][61] | Conform to both families as Apple expects [62]; evaluate `DataCacheHandler` on 27 after correctness tests [64] | P2 | M |
| Diagnostics | `Logger` subsystems `dev.streamdrive.app`, `.app.filesystem`, `.core`, `.cloud` with hashed paths; `log show` recipe in `README.md` | No in-app export; `log show` needs an admin user [70]; extension logs come from another process | "Copy Diagnostics…": version, tag, build, macOS build, FSKit module list and state, `SMAppService` status, ParaAir mount-table rows, profile count, `log show --last 1h --predicate 'subsystem BEGINSWITH "dev.streamdrive"'` when admin (else the `sudo log collect` recipe [66]), recent ParaAir and StreamDriveFS crash reports [71]; preview before saving; never upload automatically | P1 | M |
| Crash and metrics | None | No field crash signal | No third-party SDK in the alpha; on 27 read `MetricManager.diagnosticReports` locally and include them in diagnostics [73] | P2 | M |
| Privacy manifest | None | Not required outside the App Store [75][76] | Skip; state in the privacy policy that update checks send IP address and app version to the appcast host | P2 | S |
| Entitlements | App: `fskit.mount` plus provisioned keychain group; extension: `fsmodule`, sandbox, `files.user-selected.read-write`, `network.client`, keychain group; hardened runtime, no exceptions (`macOS/App/StreamDrive.entitlements`, `macOS/Extension/StreamDriveFS.entitlements`, `scripts/prepare-signing.py`) | `files.user-selected.read-write` on the extension may be unused | Mount without it on a test build; drop it if nothing breaks; keep zero runtime exceptions [5][6] | P2 | S |
| Signing layout and size | Inside-out `codesign`, `--deep` only to verify (`scripts/build-app.sh`); the 45 MB `libstreamdrive.dylib` is copied into the app, extension and CLI (142 MB app, 51 MB DMG); `Contents/Helpers/paraair` signed without `-i`; DMG `UDZO` (`scripts/dmg-settings.py`) | Triple payload on every download and update | One dylib in `Contents/Frameworks` loaded by the extension and CLI by relative path (verify sandbox read access and library validation); sign the launcher with `-i dev.streamdrive.app.cli-launcher` [3]; DMG `ULMO` [20] | P2 | M |
| Dev and release identity | Dev and release builds share `dev.streamdrive.app` on the operator's Mac | Archives and DerivedData copies can be picked up by FSKit; DTS suggests split bundle IDs [36] | Dev builds use `dev.streamdrive.app.dev` and `.dev.filesystem` with their own profiles | P2 | M |
| Uninstall | Not documented | Deleting the app while mounted kills the extension uncleanly [19]; Keychain items in the shared group (`Sources/StreamDriveCore/KeychainInteractionPolicy.swift`), `~/Library/Application Support/StreamDrive` (journal may hold unsynced writes), defaults and the login item remain | Now: uninstall steps in `README.md` and the site (eject, quit, delete; optional data removal). Later: "Uninstall ParaAir…" that refuses with pending uploads, ejects, calls `SMAppService.mainApp.unregister()`, deletes the group's Keychain items, optionally removes state, deletes defaults, moves the app to the Trash and quits [42][77] | P0 docs / P1 in-app | S / M |
| Data migration | `ConnectionStore` and `CloudAccountStore` require `schemaVersion == 1`; `DriveProfile` has no version (`Sources/StreamDriveCore`) | No forward migration; an older app on newer state fails opaquely | Version every on-disk record; migrate at launch before mounting, after a backup copy; an older app on newer state says "Update ParaAir" | P1 | M |
| Accessibility | Some `accessibilityLabel`s, default and cancel shortcuts, light and dark snapshots (`scripts/render-ui-snapshots.sh`) | No VoiceOver order, Full Keyboard Access or Increase Contrast audit [79] | Accessibility Inspector pass on home window, menu panel and settings; add Increase Contrast and Reduce Transparency snapshot variants; check 4.5:1 | P1 | M |
| Localization | English literals in SwiftUI views and model code | Model-built strings are not extractable | Add `Localizable.xcstrings`; use `String(localized:)` in presentation code; ship English only for now [80] | P2 | M |
| Notifications | Asks on the first upload problem (`macOS/App/DriveActivity.swift`) | In context, as Apple advises [39]; a denial loses that first notice | Optional: request `.provisional` during setup | P2 | S |
| Local network | No `NSLocalNetworkUsageDescription` (`macOS/App/Info.plist`) | A LAN NAS backend would be denied in the extension until the app triggers the prompt [55] | Add the key to the app; probe the NAS from the app during NAS setup | P2 (P1 when NAS ships) | S |

## Unverified claims and open tests

- Whether FSKit extension approval survives a Developer ID update on macOS 27 (only a third-party report on 26.4.1 [35]). Answered 2026-10-16 on macOS 27.2: on a clean Mac, a disk-image install, a Sparkle install on quit and a Sparkle Install and Relaunch all kept the module enabled with no restart. An earlier failure came from stale LaunchServices data left by development copies. The per-app System Settings sheet cannot enable a module on 27.2; the By Category → File System Extensions view can (see `docs/ci-cd.md`, In-app updates).
- Whether the extension-termination-on-update behaviour [19] (reported on macOS 15.7) and the ExtensionKit stale-registration bug [35][36] still occur on macOS 27.2.
- How Spotlight treats an FSKit volume, and the supported way to stop it indexing one (`.metadata_never_index` is folklore, not Apple documentation).
- Whether macOS drops quarantine and provenance xattrs on an FSKit volume without xattr support or emulates them with `._` files.
- Whether a translocated app reports `volumeIsReadOnly` (inferred from "read-only location" [12]).
- Whether `SMAppService.mainApp` registered from a DMG or translocated path keeps pointing at the old path after the move.
- That `log show` returns nothing for non-admin users (third-party source [70]).
- That `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` works on all macOS 26 releases (undocumented).
- Whether MetricKit delivers reports for an FSKit app extension.
- Whether the extension needs `com.apple.security.files.user-selected.read-write`, and whether a sandboxed extension can load the dylib from the containing app's `Contents/Frameworks`.
- How a custom volume icon can be set on an FSKit volume.

## Sources

1. Notarizing macOS software before distribution, Apple: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
2. Customizing the notarization workflow, Apple: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
3. Creating distribution-signed code for macOS, Apple: https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
4. Packaging Mac software for distribution, Apple: https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
5. Hardened Runtime, Apple: https://developer.apple.com/documentation/security/hardened-runtime
6. Disable Library Validation Entitlement, Apple: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
7. `--deep` Considered Harmful, Quinn (Apple DTS), revised 2024-05-06: https://developer.apple.com/forums/thread/129980
8. Testing a Notarised Product, Quinn (Apple DTS), revised 2024-12-05: https://developer.apple.com/forums/thread/130560
9. stapler(1) manual page (mirror of the Xcode man page): https://keith.github.io/xcode-man-pages/stapler.1.html
10. Updates to runtime protection in macOS Sequoia, Apple Developer News, 2024-08-06: https://developer.apple.com/news/?id=saqachfa
11. App Translocation Notes, Quinn (Apple DTS), 2023: https://developer.apple.com/forums/thread/724969
12. App Translocation, Lapcat Software (quotes the macOS 10.12 release notes): https://lapcatsoftware.com/articles/app-translocation.html
13. CFBundleShortVersionString, Apple: https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring
14. CFBundleVersion, Apple: https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion
15. macOS 27 Golden Gate is compatible with these computers, Apple Support, 2026-09-14: https://support.apple.com/en-us/127255
16. FSPathURLResource, Apple: https://developer.apple.com/documentation/fskit/fspathurlresource
17. FSClient.mountSingleVolume(resource:bundleID:options:completionHandler:), Apple: https://developer.apple.com/documentation/fskit/fsclient/mountsinglevolume(resource:bundleid:options:completionhandler:)
18. FSClient.openFileSystemExtensionsSettings(), Apple: https://developer.apple.com/documentation/fskit/fsclient/openfilesystemextensionssettings()
19. Safely updating an FSKit module via the Mac App Store, Apple Developer Forums (Kevin Elliott, DTS), Dec 2025 to Feb 2026: https://developer.apple.com/forums/thread/809747
20. hdiutil(1) manual page, read locally on macOS 27.2 (`man hdiutil`); no URL
21. Sparkle: Documentation (basic setup): https://sparkle-project.org/documentation/
22. Sparkle: Customizing Sparkle (Info.plist keys): https://sparkle-project.org/documentation/customization/
23. Sparkle: Publishing an update: https://sparkle-project.org/documentation/publishing/
24. Sparkle: Delta Updates: https://sparkle-project.org/documentation/delta-updates/
25. Sparkle: Sandboxing with Sparkle: https://sparkle-project.org/documentation/sandboxing/
26. Sparkle: Gentle update reminders: https://sparkle-project.org/documentation/gentle-reminders/
27. Sparkle 2.10.0 release notes, 2026-09-13: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0
28. Sparkle SPUUpdaterDelegate.h (2.x): https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUUpdaterDelegate.h
29. Sparkle SUPlainInstaller.m (2.x): https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUPlainInstaller.m
30. Sparkle generate_appcast/main.swift (2.x): https://github.com/sparkle-project/Sparkle/blob/2.x/generate_appcast/main.swift
31. Sparkle sign_update/main.swift (2.x): https://github.com/sparkle-project/Sparkle/blob/2.x/sign_update/main.swift
32. Sparkle generate_keys/main.swift (2.x): https://github.com/sparkle-project/Sparkle/blob/2.x/generate_keys/main.swift
33. Updating Mac Software, Apple: https://developer.apple.com/documentation/security/updating-mac-software
34. NSUpdateSecurityPolicy, Apple: https://developer.apple.com/documentation/bundleresources/information-property-list/nsupdatesecuritypolicy
35. FSKit module mount fails with permission error, Apple Developer Forums (TestFS Sparkle report and Kevin Elliott, DTS, Apr 2026): https://developer.apple.com/forums/thread/788609
36. Failure to mount an FSKit volume sometimes, Apple Developer Forums (Kevin Elliott, DTS, Oct 2025 and Jul 2026): https://developer.apple.com/forums/thread/804432
37. Announcing macFUSE 5.2.0, 2026-04-09: https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html
38. Human Interface Guidelines: Onboarding: https://developer.apple.com/design/human-interface-guidelines/onboarding
39. Asking permission to use notifications, Apple: https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications
40. SMAppService, Apple: https://developer.apple.com/documentation/servicemanagement/smappservice
41. SMAppService.register(), Apple: https://developer.apple.com/documentation/servicemanagement/smappservice/register()
42. SMAppService.unregister(), Apple: https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()
43. SMAppService.Status.requiresApproval, Apple: https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval
44. Manage login items and background tasks on Mac, Apple Platform Deployment: https://support.apple.com/guide/deployment/manage-login-items-background-tasks-mac-depdca572563/web
45. App Review Guidelines (2.4.5), Apple: https://developer.apple.com/app-store/review/guidelines/
46. LetsMove (potionfactory), last pushed 2022-06-26: https://github.com/potionfactory/LetsMove
47. NSApplication.ActivationPolicy.accessory, Apple: https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory
48. Human Interface Guidelines: The menu bar (Menu bar extras): https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
49. Change Menu Bar settings on Mac, Apple Support: https://support.apple.com/guide/mac-help/change-menu-bar-settings-mchlad96d366/mac
50. MenuBarExtra, Apple: https://developer.apple.com/documentation/swiftui/menubarextra
51. Settings (SwiftUI scene), Apple: https://developer.apple.com/documentation/swiftui/settings
52. Human Interface Guidelines: Settings: https://developer.apple.com/design/human-interface-guidelines/settings
53. FSClient, Apple: https://developer.apple.com/documentation/fskit/fsclient
54. FSClient.fetchInstalledExtensions(completionHandler:), Apple: https://developer.apple.com/documentation/fskit/fsclient/fetchinstalledextensions(completionhandler:)
55. TN3179: Understanding local network privacy, Apple: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
56. kLSSharedFileListFavoriteItems, Apple: https://developer.apple.com/documentation/coreservices/klssharedfilelistfavoriteitems
57. Mac keyboard shortcuts, Apple Support, 2026-09-14: https://support.apple.com/en-us/102650
58. FSVolume, Apple: https://developer.apple.com/documentation/fskit/fsvolume
59. FSVolume.SupportedCapabilities, Apple: https://developer.apple.com/documentation/fskit/fsvolume/supportedcapabilities
60. FSKit updates (June 2026), Apple: https://developer.apple.com/documentation/updates/fskit
61. FSVolume.Operations (deprecated 27.0), Apple: https://developer.apple.com/documentation/fskit/fsvolume/operations
62. Updating an FSKit module to use the new Handler protocols, Apple Developer Forums (Apple frameworks engineers, WWDC26 Q&A): https://developer.apple.com/forums/thread/831376
63. FSVolume.XattrHandler, Apple: https://developer.apple.com/documentation/fskit/fsvolume/xattrhandler
64. FSVolume.DataCacheHandler, Apple: https://developer.apple.com/documentation/fskit/fsvolume/datacachehandler
65. Spotlight / Finder Search / Finder Tags not working on virtual file system, Apple Developer Forums (Kevin Elliott, DTS): https://developer.apple.com/forums/thread/757338
66. Your Friend the System Log, Quinn (Apple DTS), revised 2026-05-11: https://developer.apple.com/forums/thread/705868
67. Generating log messages from your code, Apple: https://developer.apple.com/documentation/os/generating-log-messages-from-your-code
68. OSLogStore.local(), Apple: https://developer.apple.com/documentation/oslog/oslogstore/local()
69. OSLogStore.Scope.currentProcessIdentifier, Apple: https://developer.apple.com/documentation/oslog/oslogstore/scope/currentprocessidentifier
70. How to read Sierra's unified log as a normal user, The Eclectic Light Company (third party): https://eclecticlight.co/2017/07/11/how-to-read-sierras-unified-log-as-a-normal-user/
71. Acquiring crash reports and diagnostic logs, Apple: https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs
72. MetricKit, Apple: https://developer.apple.com/documentation/metrickit
73. MetricManager (macOS 27), Apple: https://developer.apple.com/documentation/metrickit/metricmanager
74. MXMetricManager (deprecated 27.2), Apple: https://developer.apple.com/documentation/metrickit/mxmetricmanager
75. Privacy manifest files, Apple: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
76. Describing use of required reason API, Apple: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
77. TN3137: On Mac keychain APIs and implementations, Apple: https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
78. Placing content in a bundle, Apple: https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
79. Human Interface Guidelines: Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility
80. Localizing and varying text with a string catalog, Apple: https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog
81. FSKit and Network File Systems?, Apple Developer Forums (Apple staff, WWDC26 Q&A): https://developer.apple.com/forums/thread/831417
