import SwiftUI
import AppKit
import StreamDriveCore

/// Offscreen checks for the app's presentation layer. Renders the home window, menu bar
/// panel and Storage Settings for fixed states into PNGs, and checks the state logic.
/// It never launches ParaAir, mounts, reads Keychain or writes the app's preferences.
@main
struct UISnapshots {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "ui-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var failures = checkPresentation()
        failures += checkCloudPresentation()
        failures += checkNaming()

        for (name, input) in homeScenarios {
            for appearance in [NSAppearance.Name.aqua, .darkAqua]
            where appearance == .aqua || name.hasPrefix("1-") || name.hasPrefix("5-") || name.hasPrefix("9-") {
                let view = DriveHomeContent(input: input, details: details(for: input),
                                            connectAutomatically: .constant(true), actions: HomeActions())
                try render(view, size: CGSize(width: 620, height: 680), appearance: appearance,
                           to: output.appendingPathComponent("home-\(name)-\(suffix(appearance)).png"))
            }
        }
        for (name, input) in homeScenarios
        where ["1-first-run", "3-turn-on", "5-connected", "6-connected-sign-in", "10-cloud-quota-blocked", "11-cloud-signed-out"].contains(name) {
            let view = MenuBarPanel(input: input, details: details(for: input),
                                    connectAutomatically: .constant(true), actions: HomeActions())
            try render(view, size: nil, appearance: .aqua, to: output.appendingPathComponent("menu-\(name)-light.png"))
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paraair-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = MemoryVault()
        try render(ConnectionsView(stateRoot: root, vault: vault), size: CGSize(width: 680, height: 760), appearance: .aqua,
                   to: output.appendingPathComponent("storage-empty-light.png"))
        try seedConnections(root: root, vault: vault)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try render(ConnectionsView(stateRoot: root, vault: vault), size: CGSize(width: 680, height: 860), appearance: appearance,
                       to: output.appendingPathComponent("storage-saved-\(suffix(appearance)).png"))
        }
        failures += try renderCloudStorage(output: output)

        if failures.isEmpty {
            print("PASS: presentation logic and naming checks; snapshots in \(output.path)")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }

    // MARK: Scenarios

    static let homeScenarios: [(String, HomeInputs)] = {
        var base = HomeInputs()
        base.credentialCheckFinished = true
        base.extensionState = .enabled
        var drive = base
        drive.driveName = "Client Footage"
        drive.storageSummary = "Cloudflare R2 · studio-footage"
        drive.mountPath = "/Volumes/Client Footage"

        var firstRun = base; firstRun.extensionState = .unchecked
        var ready = base; ready.readyConnectionName = "Cloudflare R2"; ready.extensionState = .disabled
        var turnOn = drive; turnOn.extensionState = .disabled
        var checking = drive; checking.credentialCheckFinished = false
        var connected = drive; connected.mounted = true
        connected.sidebarMessage = "Client Footage is in Finder’s Favorites."
        var mountedIssue = connected; mountedIssue.sidebarMessage = nil
        mountedIssue.connectionIssue = "Reconnect your saved storage connection in Storage settings."
        var issue = drive
        issue.connectionIssue = "Cloudflare sign-in expired. Sign in again in Storage Settings."
        var connecting = drive; connecting.mounting = true
        connecting.mountMessage = "macOS is still opening the drive. ParaAir will finish setup when it replies."
        var cloudReady = base
        cloudReady.driveName = "ParaAir Cloud"
        cloudReady.storageSummary = "ParaAir Cloud · " + fixtureEmail
        cloudReady.mountPath = "/Volumes/ParaAir Cloud"
        cloudReady.mounted = true
        cloudReady.storageKind = .paraairCloud
        cloudReady.cloudUsage = CloudUsage(workspace: fixtureMe(stored: 212_000_000_000).workspaces.first, state: .loaded)
        cloudReady.uploadActivity = UploadActivity(waiting: 2, pendingBytes: 96_000_000)
        var quotaBlocked = cloudReady
        quotaBlocked.cloudUsage = CloudUsage(workspace: fixtureMe(stored: 1_000_000_000_000).workspaces.first, state: .loaded)
        quotaBlocked.uploadActivity = UploadActivity(blockedQuota: 3, pendingBytes: 2_400_000_000)
        var cloudSignedOut = cloudReady
        cloudSignedOut.mounted = false
        cloudSignedOut.cloudUsage = nil
        cloudSignedOut.connectionIssue = "Sign in to ParaAir Cloud in Storage Settings."
        cloudSignedOut.uploadActivity = UploadActivity(blockedAuth: 2, pendingBytes: 12_000_000)
        var otherFolder = cloudReady
        otherFolder.uploadActivity = nil
        otherFolder.folderNotice = "“Client Footage” didn’t connect at login. Choose its state folder, "
            + "/Users/maya/Library/Application Support/StreamDrive, with Choose State Folder… to review it."
        return [("1-first-run", firstRun), ("2-storage-ready", ready), ("3-turn-on", turnOn),
                ("4-checking", checking), ("5-connected", connected), ("6-connected-sign-in", mountedIssue),
                ("7-sign-in-needed", issue), ("8-connecting", connecting),
                ("9-cloud-ready", cloudReady), ("10-cloud-quota-blocked", quotaBlocked), ("11-cloud-signed-out", cloudSignedOut),
                ("12-other-folder", otherFolder)]
    }()

    // MARK: ParaAir Cloud fixtures (no network, no Keychain)

    static let fixtureEmail = "maya@example.com"
    static let fixtureIssuer = URL(string: "https://cloud.example.com")!
    static let fixtureUserID = "usr_01J9ZX5Q4WJ3M8K2V7N6R1T0YB"
    static let fixtureWorkspaceID = "ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC"

    static func fixtureMe(stored: Int64, retained: Int64 = 3_100_000_000, transfer: Int64 = 48_300_000_000,
                          throttled: Bool = false) -> ParaAirCloudMe {
        let now = Date(timeIntervalSince1970: 1_791_547_200)
        let periodStart = Date(timeIntervalSince1970: 1_790_812_800), periodEnd = Date(timeIntervalSince1970: 1_793_491_200)
        let plan = ParaAirCloudMe.Plan(id: "beta", name: "Beta", storageLimitBytes: 1_000_000_000_000,
                                       transferAllowanceBytes: 3_000_000_000_000, retentionDays: 30,
                                       retentionCapBytes: 150_000_000_000, seats: 1, manageUrl: nil)
        let usage = ParaAirCloudMe.Usage(storedBytes: stored, retainedBytes: retained, reservedBytes: 0, transferBytes: transfer,
                                         uploadedBytes: stored, periodStart: periodStart, periodEnd: periodEnd,
                                         throttled: throttled, reconciledAt: nil)
        return ParaAirCloudMe(user: .init(id: fixtureUserID, email: fixtureEmail, createdAt: now),
                              session: .init(id: "grt_fixture", clientId: "paraair-macos", createdAt: now,
                                             expiresAt: now.addingTimeInterval(30 * 86_400)),
                              workspaces: [.init(id: fixtureWorkspaceID, name: "Personal", kind: "personal", role: "owner",
                                                 status: "active", plan: plan, usage: usage)])
    }

    static let fixtureDrives = [
        ParaAirCloudDrive(id: "3f0c2a7e-6b1d-4e0a-9c2f-1d2e3f4a5b6c", workspaceId: fixtureWorkspaceID, name: "ParaAir Cloud",
                          role: "owner", writable: true, chunkSize: 4_194_304, createdAt: Date(timeIntervalSince1970: 1_791_547_200)),
        ParaAirCloudDrive(id: "8d2b4f61-0c3a-4e7b-9a15-6f2e8c1d0b97", workspaceId: fixtureWorkspaceID, name: "Client Footage",
                          role: "owner", writable: true, chunkSize: 4_194_304, createdAt: Date(timeIntervalSince1970: 1_788_000_000)),
    ]

    /// Storage Settings with ParaAir Cloud signed out, signed in, choosing a drive and with
    /// usage unavailable. Account records are real files in a temporary folder; tokens stay
    /// in memory and the summary loader returns fixtures.
    @MainActor
    static func renderCloudStorage(output: URL) throws -> [String] {
        var failures: [String] = []
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("paraair-ui-cloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = MemoryVault()
        let dependencies = EngineOpenDependencies(cloudVault: vault, cloudConfiguration: .ephemeral,
                                                  cloudPolicy: .init(allowsLoopbackHTTP: false))
        func model(_ root: URL, summary: Result<ParaAirCloudMe, Error>) -> CloudAccountModel {
            CloudAccountModel(stateRoot: root, dependencies: dependencies, baseURL: { _ in fixtureIssuer },
                              summaryLoader: { _ in (try summary.get(), fixtureWorkspaceID) },
                              uploader: { _, _ in UploadActivity() },
                              driveLister: { _, _ in (fixtureDrives, try summary.get()) })
        }
        func signedIn(_ name: String, drive: Bool) throws -> URL {
            let root = base.appendingPathComponent(name, isDirectory: true)
            let account = CloudAccount(id: UUID().uuidString.lowercased(), issuer: fixtureIssuer.absoluteString,
                                       userID: fixtureUserID, email: fixtureEmail)
            try CloudAccountStore(root: root).signIn(account, tokens: OAuthTokens(
                accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600)), vault: vault)
            if drive {
                try ProfileStore(root: root).save(DriveProfile(name: "ParaAir-Cloud", backend: .paraairCloud, blockSize: 4_194_304,
                                                               displayName: "ParaAir Cloud", cloudIssuer: fixtureIssuer.absoluteString,
                                                               cloudAccountID: account.id, cloudDriveID: fixtureDrives[0].id))
            }
            return root
        }
        func settle(_ done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        let size = CGSize(width: 680, height: 760)

        let signedOutRoot = base.appendingPathComponent("signed-out", isDirectory: true)
        let signedOut = model(signedOutRoot, summary: .success(fixtureMe(stored: 0)))
        if signedOut.phase != .signedOut { failures.append("a configured build without an account is signed out") }
        try render(ConnectionsView(stateRoot: signedOutRoot, vault: MemoryVault(), cloudAccount: signedOut), size: size,
                   appearance: .aqua, to: output.appendingPathComponent("storage-cloud-signed-out-light.png"))

        let readyRoot = try signedIn("signed-in", drive: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let ready = model(readyRoot, summary: .success(fixtureMe(stored: 212_000_000_000)))
            ready.reloadSummary()
            settle { ready.summaryState == .loaded }
            if ready.summaryState != .loaded || ready.hasDrive == false { failures.append("signed-in fixture loads its summary and drive") }
            try render(ConnectionsView(stateRoot: readyRoot, vault: MemoryVault(), cloudAccount: ready), size: size,
                       appearance: appearance, to: output.appendingPathComponent("storage-cloud-signed-in-\(suffix(appearance)).png"))
        }

        let chooseRoot = try signedIn("choose", drive: false)
        let choosing = model(chooseRoot, summary: .success(fixtureMe(stored: 212_000_000_000)))
        choosing.chooseDrive()
        settle { if case .choosingDrive = choosing.phase { return true } else { return false } }
        if case .choosingDrive(let drives) = choosing.phase, drives.count == 2 {} else {
            failures.append("Create Drive… lists the account's drives")
        }
        try render(ConnectionsView(stateRoot: chooseRoot, vault: MemoryVault(), cloudAccount: choosing), size: size,
                   appearance: .aqua, to: output.appendingPathComponent("storage-cloud-choose-drive-light.png"))

        let throttledRoot = try signedIn("throttled", drive: true)
        let throttled = model(throttledRoot, summary: .success(fixtureMe(stored: 640_000_000_000, transfer: 3_000_000_000_000,
                                                                         throttled: true)))
        throttled.reloadSummary()
        settle { throttled.summaryState == .loaded }
        try render(ConnectionsView(stateRoot: throttledRoot, vault: MemoryVault(), cloudAccount: throttled), size: size,
                   appearance: .aqua, to: output.appendingPathComponent("storage-cloud-throttled-light.png"))

        // A real loopback PKCE listener; the sign-in link is shown but never opened or fetched.
        let signingRoot = base.appendingPathComponent("signing-in", isDirectory: true)
        let signing = model(signingRoot, summary: .success(fixtureMe(stored: 0)))
        signing.openDefaultBrowserAutomatically = false
        signing.signIn()
        settle { signing.authorizationURL != nil }
        if signing.phase != .signingIn || signing.authorizationURL == nil { failures.append("sign-in shows the browser link while waiting") }
        try render(ConnectionsView(stateRoot: signingRoot, vault: MemoryVault(), cloudAccount: signing), size: size,
                   appearance: .aqua, to: output.appendingPathComponent("storage-cloud-signing-in-light.png"))
        signing.cancelSignIn()

        // This build refuses loopback HTTP, so sign-in fails before any request.
        let refusedRoot = base.appendingPathComponent("refused", isDirectory: true)
        let refused = CloudAccountModel(stateRoot: refusedRoot, dependencies: dependencies,
                                        baseURL: { _ in URL(string: "http://127.0.0.1:8787")! })
        refused.signIn()
        settle { if case .failed = refused.phase { return true } else { return false } }
        if case .failed = refused.phase {} else { failures.append("a refused service address fails sign-in") }
        try render(ConnectionsView(stateRoot: refusedRoot, vault: MemoryVault(), cloudAccount: refused), size: size,
                   appearance: .aqua, to: output.appendingPathComponent("storage-cloud-sign-in-failed-light.png"))

        let unavailableRoot = try signedIn("unavailable", drive: true)
        let unavailable = model(unavailableRoot, summary: .failure(DriveError(ENETDOWN, "offline", disposition: .attemptNotDispatched)))
        unavailable.reloadSummary()
        settle { unavailable.summaryState == .failed }
        if unavailable.summaryState != .failed { failures.append("a failing summary loader ends in the failed state") }
        try render(ConnectionsView(stateRoot: unavailableRoot, vault: MemoryVault(), cloudAccount: unavailable), size: size,
                   appearance: .aqua, to: output.appendingPathComponent("storage-cloud-usage-unavailable-light.png"))
        settle { unavailable.summaryState == .failed }
        if unavailable.summaryState != .failed { failures.append("usage stays unavailable after Storage Settings appears") }
        return failures
    }

    static func details(for input: HomeInputs) -> HomeDetails {
        HomeDetails(driveIcon: nil, storageSummary: input.storageSummary, mountPath: input.mountPath,
                    stateFolder: "/Users/example/Library/Application Support/StreamDrive")
    }

    // MARK: Logic checks

    static func checkPresentation() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let scenarios = Dictionary(uniqueKeysWithValues: homeScenarios)
        let first = HomePresentation.make(scenarios["1-first-run"]!)
        expect(first.primary.action == .addStorage, "first run offers Add Storage")
        expect(first.steps.first?.state == .current, "first run starts at step 1")
        let ready = HomePresentation.make(scenarios["2-storage-ready"]!)
        expect(ready.primary.action == .createDrive, "saved storage without a drive offers Create Drive")
        expect(ready.steps.map(\.state) == [.done, .current, .upcoming, .upcoming], "ready storage marks step 2 current")
        let turnOn = HomePresentation.make(scenarios["3-turn-on"]!)
        expect(turnOn.primary.action == .openSystemSettings && turnOn.offersCheckAgain, "disabled extension opens System Settings")
        expect(turnOn.steps.map(\.state) == [.done, .done, .current, .upcoming], "extension step is current")
        let checking = HomePresentation.make(scenarios["4-checking"]!)
        expect(!checking.primary.enabled && checking.primary.busy, "checking storage disables the action")
        let connected = HomePresentation.make(scenarios["5-connected"]!)
        expect(connected.primary.action == .openInFinder && connected.steps.isEmpty, "healthy mount shows Open in Finder, no checklist")
        expect(connected.status.tone == .good, "healthy mount is good")
        let mountedIssue = HomePresentation.make(scenarios["6-connected-sign-in"]!)
        expect(mountedIssue.primary.action == .signInAgain && mountedIssue.offersOpenInFinder,
               "mounted drive with expired access asks to sign in and keeps Open in Finder")
        expect(mountedIssue.status.tone == .attention, "mounted drive with expired access is not shown as healthy")
        let issue = HomePresentation.make(scenarios["7-sign-in-needed"]!)
        expect(issue.primary.action == .signInAgain && issue.status.tone == .problem, "unmounted drive with expired access")
        expect(issue.steps.first?.state == .current, "expired access returns to step 1")
        let connecting = HomePresentation.make(scenarios["8-connecting"]!)
        expect(connecting.primary.busy && connecting.notices.contains { $0.id == "mount" }, "connecting shows progress and message")
        var renewal = scenarios["5-connected"]!
        renewal.renewalError = "Network unavailable"
        expect(HomePresentation.make(renewal).notices.contains { $0.id == "renewal" }, "renewal error shown when no connection issue")
        renewal.connectionIssue = "Sign in"
        expect(!HomePresentation.make(renewal).notices.contains { $0.id == "renewal" }, "renewal error folded into connection issue")
        for (name, input) in homeScenarios {
            let presentation = HomePresentation.make(input)
            let text = ([presentation.status.title, presentation.status.detail, presentation.primary.title]
                        + presentation.steps.flatMap { [$0.title, $0.detail] } + presentation.notices.map(\.text)).joined(separator: "\n")
            expect(!text.contains("\u{2014}"), "\(name): copy avoids em dashes")
            expect(!text.lowercased().contains("juicefs") && !text.lowercased().contains("metadata"), "\(name): copy avoids engine jargon")
        }
        return failures
    }

    static func checkCloudPresentation() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let scenarios = Dictionary(uniqueKeysWithValues: homeScenarios)

        let first = HomePresentation.make(scenarios["1-first-run"]!)
        expect(first.status.detail == "Sign in to ParaAir Cloud or connect your own storage bucket. ParaAir sets up the drive, its cache and Finder.",
               "first run offers ParaAir Cloud or your own bucket")
        expect(first.primary.title == "Set Up Storage…", "first run button is Set Up Storage…")
        expect(first.steps.first?.detail == "ParaAir Cloud, Cloudflare R2 or another S3-compatible bucket.", "step 1 names ParaAir Cloud")

        let ready = HomePresentation.make(scenarios["9-cloud-ready"]!)
        expect(ready.primary.action == .openInFinder && ready.status.tone == .good, "a mounted cloud drive is connected")
        expect(ready.notices.contains { $0.id == "upload-waiting" && $0.text == "2 files are waiting to upload." }, "waiting uploads are counted")
        let blocked = HomePresentation.make(scenarios["10-cloud-quota-blocked"]!)
        expect(blocked.notices.first { $0.id == "upload-quota" }?.text
               == "Your ParaAir Cloud storage is full. 3 files will upload when space is available.", "quota-blocked uploads explain why")
        expect(blocked.notices.first { $0.id == "upload-quota" }?.tone == .attention, "quota notice asks for attention")

        var mixed = scenarios["9-cloud-ready"]!
        mixed.uploadActivity = UploadActivity(waiting: 1, blockedQuota: 0, blockedAuth: 4, conflicts: 1, failedOther: 2)
        let mixedNotices = HomePresentation.make(mixed).notices.map(\.text)
        expect(mixedNotices.contains("Sign in to ParaAir Cloud to upload 4 files."), "sign-in notice counts files")
        expect(mixedNotices.contains("1 file changed on another device. Your copy is kept on this Mac."), "conflict notice is singular")
        expect(mixedNotices.contains("3 files are waiting to upload."), "other failures count as waiting")
        let otherFolder = HomePresentation.make(scenarios["12-other-folder"]!)
        expect(otherFolder.status.tone == .good && otherFolder.notices.map(\.id) == ["folder"]
               && otherFolder.notices.first?.tone == .attention,
               "a drive from another state folder that didn't connect is shown beside the selected drive")
        let signedOut = HomePresentation.make(scenarios["11-cloud-signed-out"]!)
        expect(signedOut.primary.action == .signInAgain && signedOut.status.tone == .problem, "a signed-out cloud drive asks to sign in")
        expect(signedOut.notices.map(\.text) == ["2 files are waiting to upload."],
               "a signed-out drive counts its uploads without repeating the sign-in request")
        var ownBucket = mixed
        ownBucket.storageKind = .ownBucket
        expect(!HomePresentation.make(ownBucket).notices.contains { $0.text.contains("ParaAir Cloud") },
               "your own bucket never gets ParaAir Cloud wording")
        expect(HomePresentation.make(ownBucket).notices.contains { $0.text == "7 files are waiting to upload." },
               "your own bucket counts quota and sign-in failures as waiting")
        expect(UploadNotices.notUploaded(1) == "1 file on this Mac hasn’t uploaded yet.", "sign-out notice is singular")
        expect(UploadNotices.notUploaded(5) == "5 files on this Mac haven’t uploaded yet.", "sign-out notice is plural")

        let loaded = CloudUsagePresentation.make(fixtureMe(stored: 212_000_000_000).workspaces.first, state: .loaded)
        expect(loaded.planLine == "1 TB plan" && loaded.planSize == "1 TB", "plan size is the primary figure")
        expect(loaded.usedLine == "212 GB used" && loaded.usedSize == "212 GB", "used is the supporting line")
        expect(abs((loaded.fraction ?? 0) - 0.212) < 0.0001, "used fraction is stored over the plan size")
        expect(loaded.retainedLine == "Kept for recovery: 3.1 GB (deleted files stay 30 days)", "retention line")
        expect(loaded.transferLine == "Transfer this month: 48.3 GB of 3 TB", "transfer line")
        expect(loaded.notice == nil, "no throttled notice by default")
        let none = CloudUsagePresentation.make(fixtureMe(stored: 0, retained: 0).workspaces.first, state: .loaded)
        expect(none.retainedLine == "Kept for recovery: none (deleted files stay 30 days)", "nothing kept reads as none")
        let throttled = CloudUsagePresentation.make(fixtureMe(stored: 1, throttled: true).workspaces.first, state: .loaded)
        expect(throttled.notice == "This month’s transfer allowance is used up, so downloads are slower until November 1.",
               "throttled notice names the period end in UTC")
        let refreshing = CloudUsagePresentation.make(fixtureMe(stored: 212_000_000_000).workspaces.first, state: .loading)
        expect(refreshing.usedLine == "212 GB used", "values stay visible while a refresh runs")

        for (label, presentation) in [("nil failed", CloudUsagePresentation.make(nil, state: .failed)),
                                      ("values failed", CloudUsagePresentation.make(fixtureMe(stored: 5).workspaces.first, state: .failed)),
                                      ("nil loaded", CloudUsagePresentation.make(nil, state: .loaded))] {
            let text = [presentation.planLine, presentation.usedLine, presentation.retainedLine, presentation.transferLine,
                        presentation.notice, presentation.planSize, presentation.usedSize].compactMap { $0 }.joined(separator: "\n")
            expect(!text.contains("0 B") && !text.contains("0 bytes") && !text.contains("Zero"), "\(label): failed usage shows no zeros")
            expect(presentation.planLine == "Plan and usage are unavailable right now." && presentation.fraction == nil,
                   "\(label): failed usage says it is unavailable")
        }
        expect(CloudUsagePresentation.make(nil, state: .loading).planLine == "Checking plan and usage…", "loading says checking")

        let copy = [loaded, none, throttled].flatMap { [$0.planLine, $0.usedLine, $0.retainedLine, $0.transferLine, $0.notice] }
            .compactMap { $0 } + [CloudAccountModel.inviteOnly, UploadNotices.quota(2), UploadNotices.signIn(2),
                                  UploadNotices.conflicts(2), UploadNotices.waiting(2), UploadNotices.notUploaded(2)]
        expect(!copy.joined().contains("\u{2014}"), "cloud copy avoids em dashes")
        return failures
    }

    static func checkNaming() -> [String] {
        let cases: [(String, String)] = [
            ("ParaAir", "ParaAir"), ("Client Footage", "Client-Footage"), ("  Spaced   out ", "Spaced-out"),
            ("Café Reel 2026", "Caf-Reel-2026"), ("—", "ParaAir"), ("-lead.and.trail_", "lead.and.trail"),
            (String(repeating: "a", count: 80), String(repeating: "a", count: 64)),
        ]
        var failures: [String] = []
        for (input, expected) in cases {
            let name = DriveNaming.profileName(for: input)
            if name != expected { failures.append("profileName(\(input)) = \(name), expected \(expected)") }
            do { try DriveProfile.validateName(name) } catch { failures.append("profileName(\(input)) = \(name) is not a valid profile name") }
        }
        return failures
    }

    // MARK: Rendering

    static func suffix(_ appearance: NSAppearance.Name) -> String { appearance == .darkAqua ? "dark" : "light" }

    @MainActor
    static func render<V: View>(_ view: V, size: CGSize?, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let frameSize = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: frameSize)
        let window = KeyLookingWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw DriveError(EIO, "Could not allocate a snapshot bitmap")
        }
        // A real window paints its background behind the hosting view; do the same here.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw DriveError(EIO, "PNG encoding failed") }
        try png.write(to: url)
        window.close()
    }

    static func seedConnections(root: URL, vault: MemoryVault) throws {
        let store = ConnectionStore(root: root)
        let ready = StorageConnection(provider: .cloudflareR2, name: "Studio R2", state: .storageReady,
                                      accountID: "0123456789abcdef0123456789abcdef", bucket: "studio-footage",
                                      endpoint: try CloudflareR2Provider.bucketEndpoint(
                                          accountID: "0123456789abcdef0123456789abcdef", bucketName: "studio-footage").absoluteString,
                                      region: "auto")
        try store.authorize(ready, secrets: ConnectionSecrets(binding: ready.credentialBinding,
            oauth: OAuthTokens(accessToken: "fixture", expiresAt: Date().addingTimeInterval(3600))), vault: vault)
        let other = StorageConnection(provider: .backblazeB2, name: "Archive B2", state: .storageReady,
                                      bucket: "archive-b2", endpoint: "https://s3.us-west-004.backblazeb2.com",
                                      region: "us-west-004")
        try store.authorize(other, secrets: ConnectionSecrets(binding: other.credentialBinding,
            s3: try S3Credentials(accessKey: "fixture-key", secretKey: "fixture-secret")), vault: vault)
        try store.disconnect(other.id, vault: vault)
    }
}

/// Renders controls in their active (key window) appearance without showing a window.
final class KeyLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// In-memory vault so the harness never touches Keychain.
final class MemoryVault: ConnectionVault, @unchecked Sendable {
    private var items: [String: ConnectionSecrets] = [:]
    private let lock = NSLock()
    func load(id: String) throws -> ConnectionSecrets {
        try lock.withLock {
            guard let value = items[id] else { throw DriveError(ENOENT, "No secrets") }
            return value
        }
    }
    func save(_ secrets: ConnectionSecrets, id: String) throws { lock.withLock { items[id] = secrets } }
    func remove(id: String) throws { _ = lock.withLock { items.removeValue(forKey: id) } }
}
