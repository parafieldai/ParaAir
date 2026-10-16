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
        failures += checkBilling()
        failures += checkNaming()
        failures += checkLoginItem()
        failures += checkVersionText()
        failures += checkUpdateGate()
        failures += checkButtonHeights()

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
        where ["1-first-run", "3-turn-on", "5-connected", "6-connected-sign-in", "10-cloud-quota-blocked", "11-cloud-signed-out",
               "14-cloud-past-due", "15-cloud-read-only", "16-cloud-pending-deletion"].contains(name) {
            let view = MenuBarPanel(input: input, details: details(for: input),
                                    connectAutomatically: .constant(true), actions: HomeActions())
            try render(view, size: nil, appearance: .aqua, to: output.appendingPathComponent("menu-\(name)-light.png"))
        }
        try renderLoginItem(output: output)

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
        failures += try renderBilling(output: output)

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
        var planActive = cloudReady
        planActive.uploadActivity = nil
        planActive.cloudUsage = CloudUsage(workspace: fixtureMe(stored: 212_000_000_000, billing: billingActive).workspaces.first, state: .loaded)
        var pastDue = cloudReady
        pastDue.uploadActivity = nil
        pastDue.cloudUsage = CloudUsage(workspace: fixtureMe(stored: 1_240_000_000_000, billing: billingPastDue, kind: "team", seats: 3).workspaces.first,
                                        state: .loaded)
        var readOnly = cloudReady
        readOnly.uploadActivity = nil
        readOnly.cloudUsage = CloudUsage(workspace: fixtureMe(stored: 640_000_000_000, billing: billingReadOnly, status: "read_only").workspaces.first,
                                         state: .loaded)
        var pendingDeletion = readOnly
        pendingDeletion.cloudUsage = CloudUsage(workspace: fixtureMe(stored: 640_000_000_000, billing: billingPendingDeletion,
                                                                     status: "read_only").workspaces.first, state: .loaded)
        return [("1-first-run", firstRun), ("2-storage-ready", ready), ("3-turn-on", turnOn),
                ("4-checking", checking), ("5-connected", connected), ("6-connected-sign-in", mountedIssue),
                ("7-sign-in-needed", issue), ("8-connecting", connecting),
                ("9-cloud-ready", cloudReady), ("10-cloud-quota-blocked", quotaBlocked), ("11-cloud-signed-out", cloudSignedOut),
                ("12-other-folder", otherFolder), ("13-cloud-plan-active", planActive), ("14-cloud-past-due", pastDue),
                ("15-cloud-read-only", readOnly), ("16-cloud-pending-deletion", pendingDeletion)]
    }()

    // MARK: ParaAir Cloud fixtures (no network, no Keychain)

    static let fixtureEmail = "maya@example.com"
    static let fixtureIssuer = URL(string: "https://cloud.example.com")!
    static let fixtureUserID = "usr_01J9ZX5Q4WJ3M8K2V7N6R1T0YB"
    static let fixtureWorkspaceID = "ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC"

    /// The drive's workspace first; `extra` workspaces follow it (for the plan sheet's Personal and Team choice).
    static func fixtureMe(stored: Int64, retained: Int64 = 3_100_000_000, transfer: Int64 = 48_300_000_000,
                          throttled: Bool = false, billing: ParaAirCloudBilling? = nil, kind: String = "personal", role: String = "owner",
                          seats: Int = 1, status: String = "active", manageUrl: URL? = nil,
                          extra: [ParaAirCloudMe.Workspace] = []) -> ParaAirCloudMe {
        let now = Date(timeIntervalSince1970: 1_791_547_200)
        let usage = fixtureUsage(stored: stored, retained: retained, transfer: transfer, throttled: throttled)
        return ParaAirCloudMe(user: .init(id: fixtureUserID, email: fixtureEmail, createdAt: now),
                              session: .init(id: "grt_fixture", clientId: "paraair-macos", createdAt: now,
                                             expiresAt: now.addingTimeInterval(30 * 86_400)),
                              workspaces: [.init(id: fixtureWorkspaceID, name: kind == "team" ? "Studio" : "Personal", kind: kind, role: role,
                                                 status: status, plan: fixturePlan(seats: seats, manageUrl: manageUrl), usage: usage,
                                                 billing: billing)] + extra)
    }

    static func fixturePlan(seats: Int, manageUrl: URL? = nil) -> ParaAirCloudMe.Plan {
        ParaAirCloudMe.Plan(id: "beta", name: "Beta", storageLimitBytes: 1_000_000_000_000 * Int64(seats),
                            transferAllowanceBytes: 3_000_000_000_000 * Int64(seats), retentionDays: seats > 1 ? 90 : 30,
                            retentionCapBytes: 150_000_000_000 * Int64(seats), seats: seats, manageUrl: manageUrl)
    }

    static func fixtureUsage(stored: Int64, retained: Int64 = 3_100_000_000, transfer: Int64 = 48_300_000_000,
                             throttled: Bool = false) -> ParaAirCloudMe.Usage {
        ParaAirCloudMe.Usage(storedBytes: stored, retainedBytes: retained, reservedBytes: 0, transferBytes: transfer,
                             uploadedBytes: stored, periodStart: Date(timeIntervalSince1970: 1_790_812_800),
                             periodEnd: Date(timeIntervalSince1970: 1_793_491_200), throttled: throttled, reconciledAt: nil)
    }

    /// A second workspace (a team the user owns, by default) for the plan sheet.
    static func fixtureTeam(billing: ParaAirCloudBilling?, role: String = "owner", seats: Int = 3,
                            id: String = "ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YD", name: String = "Studio") -> ParaAirCloudMe.Workspace {
        .init(id: id, name: name, kind: "team", role: role, status: "active", plan: fixturePlan(seats: seats),
              usage: fixtureUsage(stored: 420_000_000_000), billing: billing)
    }

    // MARK: Billing fixtures (UTC days, as the service sends them)

    static func day(_ value: String) -> Date { ISO8601DateFormatter().date(from: value + "T00:00:00Z")! }
    static let billingBeta = ParaAirCloudBilling(provider: .paddle, status: .none, checkoutAvailable: true)
    static let billingActive = ParaAirCloudBilling(provider: .paddle, status: .active, plan: .personal, interval: .year, seats: 1,
                                                   currentPeriodEnd: day("2027-10-12"), portalAvailable: true)
    static let billingCancelled = ParaAirCloudBilling(provider: .paddle, status: .active, plan: .personal, interval: .month, seats: 1,
                                                      currentPeriodEnd: day("2026-11-12"), cancelAtPeriodEnd: true,
                                                      readOnlyAt: day("2026-11-12"), deletionAt: day("2026-12-12"), portalAvailable: true)
    static let billingPastDue = ParaAirCloudBilling(provider: .stripe, status: .pastDue, plan: .team, interval: .month, seats: 3,
                                                    currentPeriodEnd: day("2026-11-12"), graceEndsAt: day("2026-10-26"),
                                                    readOnlyAt: day("2026-10-26"), deletionAt: day("2026-11-25"), portalAvailable: true)
    static let billingReadOnly = ParaAirCloudBilling(provider: .paddle, status: .readOnly, plan: .personal, interval: .month, seats: 1,
                                                     currentPeriodEnd: day("2026-10-05"), readOnlyAt: day("2026-10-05"),
                                                     deletionAt: day("2026-11-04"), checkoutAvailable: true, portalAvailable: true)
    /// An ended Stripe plan after the service moved to Paddle: billing still names Stripe, the offer names Paddle.
    static let billingReadOnlyStripe = ParaAirCloudBilling(provider: .stripe, status: .readOnly, plan: .personal, interval: .month, seats: 1,
                                                           currentPeriodEnd: day("2026-10-05"), readOnlyAt: day("2026-10-05"),
                                                           deletionAt: day("2026-11-04"), checkoutAvailable: true)
    static let billingPendingDeletion = ParaAirCloudBilling(provider: .paddle, status: .pendingDeletion, plan: .personal, interval: .year,
                                                            seats: 1, currentPeriodEnd: day("2026-09-01"), readOnlyAt: day("2026-09-10"),
                                                            deletionAt: day("2026-10-10"), checkoutAvailable: true)
    static let billingDeleting = ParaAirCloudBilling(provider: .paddle, status: .deleting, plan: .personal, interval: .year, seats: 1,
                                                     currentPeriodEnd: day("2026-09-01"), readOnlyAt: day("2026-09-10"),
                                                     deletionAt: day("2026-10-10"))
    static let billingDeleted = ParaAirCloudBilling(provider: .paddle, status: .deleted, plan: .personal, interval: .year, seats: 1,
                                                    currentPeriodEnd: day("2026-09-01"), readOnlyAt: day("2026-09-10"),
                                                    deletionAt: day("2026-10-10"), checkoutAvailable: true)
    /// A team member's view of the owner's failed payment: the service offers members neither checkout nor the portal.
    static let billingMemberPastDue = ParaAirCloudBilling(provider: .stripe, status: .pastDue, plan: .team, interval: .month, seats: 3,
                                                          currentPeriodEnd: day("2026-11-12"), graceEndsAt: day("2026-10-26"),
                                                          readOnlyAt: day("2026-10-26"), deletionAt: day("2026-11-25"))

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
            try seedSignedIn(base.appendingPathComponent(name, isDirectory: true), vault: vault, drive: drive)
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

    /// A state folder signed in to the fixture account; tokens stay in `vault`.
    static func seedSignedIn(_ root: URL, vault: MemoryVault, drive: Bool, workspaceID: String? = nil) throws -> URL {
        let account = CloudAccount(id: UUID().uuidString.lowercased(), issuer: fixtureIssuer.absoluteString,
                                   userID: fixtureUserID, email: fixtureEmail)
        try CloudAccountStore(root: root).signIn(account, tokens: OAuthTokens(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600)), vault: vault)
        if drive {
            try ProfileStore(root: root).save(DriveProfile(name: "ParaAir-Cloud", backend: .paraairCloud, blockSize: 4_194_304,
                                                           displayName: "ParaAir Cloud", cloudIssuer: fixtureIssuer.absoluteString,
                                                           cloudAccountID: account.id, cloudDriveID: fixtureDrives[0].id,
                                                           cloudWorkspaceID: workspaceID))
        }
        return root
    }

    /// Runs the main run loop until `done` or five seconds.
    @MainActor
    static func settle(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    // MARK: ParaAir Cloud billing

    /// Storage Settings in every billing state, the plan sheet's steps, and the model's offer, checkout and portal
    /// flow against fixture starters. Nothing reaches a network or a browser: `openURL` only records.
    @MainActor
    static func renderBilling(output: URL) throws -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("paraair-ui-billing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let vault = MemoryVault()
        let dependencies = EngineOpenDependencies(cloudVault: vault, cloudConfiguration: .ephemeral,
                                                  cloudPolicy: .init(allowsLoopbackHTTP: false))
        let stripeCheckout = URL(string: "https://checkout.stripe.com/c/pay/cs_test_a1B2c3D4#fidkdWxOYHwnPyd1blpxYHZxWjA0")!
        let stripeCheckout2 = URL(string: "https://checkout.stripe.com/c/pay/cs_test_e5F6g7H8#fidkdWxOYHwnPyd1blpxYHZxWjA0")!
        let paddleCheckout = URL(string: fixtureIssuer.absoluteString + "/billing/pay?_ptxn=txn_01j9zx5q4wj3m8k2v7n6r1t0yc")!
        let stripePortal = URL(string: "https://billing.stripe.com/p/session/test_YWNjdF8xTTJKVGtMa2RJd0h1N2l4")!
        let refusedText = "ParaAir Cloud returned a payment page this app won’t open."

        func model(_ name: String, _ summary: SummaryBox, recorder: BillingRecorder, checkout: [URL] = [stripeCheckout],
                   portal: URL = stripePortal, delay: TimeInterval = 0, workspaceID: String? = fixtureWorkspaceID,
                   offer: OfferBox = OfferBox(), profileWorkspaceID: String? = nil) throws -> CloudAccountModel {
            let root = try seedSignedIn(base.appendingPathComponent(name, isDirectory: true), vault: vault, drive: true,
                                        workspaceID: profileWorkspaceID)
            let cloud = CloudAccountModel(
                stateRoot: root, dependencies: dependencies, baseURL: { _ in fixtureIssuer },
                summaryLoader: { request in (summary.me, request.workspaceID ?? workspaceID) },
                uploader: { _, _ in UploadActivity() },
                driveLister: { _, _ in (fixtureDrives, summary.me) },
                checkoutStarter: { _, _, request in
                    let count = recorder.record(request)
                    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                    return checkout[min(count - 1, checkout.count - 1)]
                },
                portalStarter: { _, _, _ in portal },
                offerLoader: { _, _, selection in try offer.offer(selection) },
                openURL: { recorder.open($0); return true })
            cloud.billingWatchDelays = [0.2, 0.2, 0.2, 0.2]
            cloud.reloadSummary()
            settle { cloud.summaryState == .loaded }
            expect(cloud.summaryState == .loaded, "\(name): the fixture summary loads")
            return cloud
        }
        /// Opens the sheet's review for `request` and agrees to the service's terms, as the plan sheet does.
        func agree(_ cloud: CloudAccountModel, _ request: ParaAirCloudCheckoutRequest) {
            cloud.loadQuote(request.selection)
            settle { if case .loading = cloud.quote { return false } else { return true } }
            guard case .loaded(let quote) = cloud.quote else { failures.append("the terms load for \(request.plan)"); return }
            var agreed = request
            agreed.consent = ParaAirCloudCheckoutConsent(disclosureVersion: quote.offer.disclosureVersion, autoRenew: true, terms: true)
            cloud.startCheckout(agreed)
            settle { cloud.checkout != .working }
        }
        func offerLoaded(_ cloud: CloudAccountModel) -> Bool { if case .loaded = cloud.offer { return true } else { return false } }

        // Storage Settings, ParaAir Cloud section, one image per billing state.
        let storage: [(String, ParaAirCloudMe)] = [
            ("beta", fixtureMe(stored: 212_000_000_000, billing: billingBeta)),
            ("active", fixtureMe(stored: 212_000_000_000, billing: billingActive)),
            ("cancelled", fixtureMe(stored: 212_000_000_000, billing: billingCancelled)),
            ("past-due", fixtureMe(stored: 1_240_000_000_000, billing: billingPastDue, kind: "team", seats: 3)),
            ("past-due-member", fixtureMe(stored: 1_240_000_000_000, billing: billingMemberPastDue, kind: "team", role: "member", seats: 3)),
            ("read-only", fixtureMe(stored: 640_000_000_000, billing: billingReadOnly, status: "read_only")),
            ("pending-deletion", fixtureMe(stored: 640_000_000_000, billing: billingPendingDeletion, status: "read_only")),
            ("deleting", fixtureMe(stored: 640_000_000_000, billing: billingDeleting, status: "read_only")),
            ("deleted", fixtureMe(stored: 0, retained: 0, transfer: 0, billing: billingDeleted, status: "read_only")),
        ]
        for (name, me) in storage {
            let cloud = try model("storage-\(name)", SummaryBox(me), recorder: BillingRecorder())
            for appearance in name == "active" || name == "past-due" ? [NSAppearance.Name.aqua, .darkAqua] : [.aqua] {
                try render(ConnectionsView(stateRoot: cloud.stateRoot, vault: MemoryVault(), cloudAccount: cloud),
                           size: CGSize(width: 680, height: 800), appearance: appearance,
                           to: output.appendingPathComponent("storage-billing-\(name)-\(suffix(appearance)).png"))
            }
        }

        // Choosing a plan: Personal and Team are both on sale; Personal is bought with Paddle (the issuer payment page).
        let summary = SummaryBox(fixtureMe(stored: 212_000_000_000, billing: billingBeta, extra: [fixtureTeam(billing: billingBeta)]))
        let recorder = BillingRecorder()
        let paddle = OfferBox(provider: .paddle)
        let buyer = try model("checkout", summary, recorder: recorder, checkout: [paddleCheckout], offer: paddle)
        expect(buyer.billing.controls == [CloudBillingPresentation.choosePlan], "the beta plan offers Choose a Plan…")
        buyer.perform(.choosePlan)
        expect(buyer.planSheetPresented && buyer.checkout == .idle, "Choose a Plan… opens the plan sheet")
        settle { offerLoaded(buyer) }
        expect(offerLoaded(buyer) && paddle.requests == [nil], "the sheet asks the service what it sells")
        try render(CloudPlanSheet(model: buyer), size: nil, appearance: .aqua, to: output.appendingPathComponent("plan-choose-monthly-light.png"))
        try render(CloudPlanSheet(model: buyer, plan: .team, interval: .year, seats: 3), size: nil, appearance: .darkAqua,
                   to: output.appendingPathComponent("plan-choose-team-yearly-dark.png"))
        let personal = ParaAirCloudCheckoutRequest(workspaceID: fixtureWorkspaceID, plan: .personal, interval: .month)
        buyer.loadQuote(personal.selection)
        settle { if case .loaded = buyer.quote { return true } else { return false } }
        try render(CloudPlanSheet(model: buyer, step: .review), size: nil, appearance: .aqua,
                   to: output.appendingPathComponent("plan-review-personal-light.png"))
        let teamYear = ParaAirCloudOfferRequest(plan: .team, interval: .year, seats: 3)
        buyer.loadQuote(teamYear)
        settle { if case .loaded = buyer.quote { return true } else { return false } }
        try render(CloudPlanSheet(model: buyer, step: .review, plan: .team, interval: .year, seats: 3, agreed: true),
                   size: nil, appearance: .aqua, to: output.appendingPathComponent("plan-review-team-agreed-light.png"))
        // Only the selection whose terms are on screen can start, with that text's version and both boxes ticked.
        buyer.startCheckout(personal)
        var unticked = personal
        unticked.consent = ParaAirCloudCheckoutConsent(disclosureVersion: paddle.version, autoRenew: true, terms: false)
        buyer.startCheckout(unticked)
        expect(recorder.requests.isEmpty && buyer.checkout == .idle, "no checkout without the shown terms and both boxes")
        agree(buyer, personal)
        expect(buyer.checkout == .opened(paddleCheckout) && recorder.opened == [paddleCheckout],
               "the issuer payment page opens once in the browser")
        expect(recorder.requests.map(\.consent) == [ParaAirCloudCheckoutConsent(disclosureVersion: paddle.version, autoRenew: true, terms: true)]
               && recorder.requests.map(\.selection) == [personal.selection],
               "checkout sends the chosen plan with the version of the terms shown and both boxes")
        try render(CloudPlanSheet(model: buyer), size: nil, appearance: .aqua, to: output.appendingPathComponent("plan-waiting-light.png"))
        buyer.reopenCheckout()
        expect(recorder.opened == [paddleCheckout, paddleCheckout], "Open Payment Page Again reopens the same page")
        // The processor's webhook made the plan active; the next summary shows it.
        summary.me = fixtureMe(stored: 212_000_000_000, billing: billingActive, extra: [fixtureTeam(billing: billingBeta)])
        settle { buyer.reloadSummary(); return buyer.workspace?.billing?.status == .active }
        expect(buyer.billing.controls == [CloudBillingPresentation.managePlan], "an active plan offers Manage Plan…")
        expect(buyer.pendingCheckout == nil, "a paid page is no longer pending")
        try render(CloudPlanSheet(model: buyer), size: nil, appearance: .aqua, to: output.appendingPathComponent("plan-paid-light.png"))
        buyer.closePlans()
        expect(!buyer.planSheetPresented && buyer.checkout == .idle, "Done closes the sheet")

        // Only Personal on sale: Team explains why it can't be chosen.
        let paidTeam = ParaAirCloudBilling(provider: .stripe, status: .active, plan: .team, interval: .year, seats: 3,
                                           currentPeriodEnd: day("2027-03-01"), portalAvailable: true)
        let single = try model("single", SummaryBox(fixtureMe(stored: 212_000_000_000, billing: billingBeta,
                                                              extra: [fixtureTeam(billing: paidTeam)])), recorder: BillingRecorder())
        single.perform(.choosePlan)
        settle { offerLoaded(single) }
        try render(CloudPlanSheet(model: single, interval: .year), size: nil, appearance: .aqua,
                   to: output.appendingPathComponent("plan-choose-team-unavailable-light.png"))

        // A reply naming a host outside the policy is refused here as well as in the API, and never opened.
        let refusedRecorder = BillingRecorder()
        let refused = try model("refused", SummaryBox(fixtureMe(stored: 212_000_000_000, billing: billingBeta)), recorder: refusedRecorder,
                                checkout: [URL(string: "https://checkout.stripe.com.example.net/c/pay/cs_test_1")!])
        refused.perform(.choosePlan)
        agree(refused, ParaAirCloudCheckoutRequest(workspaceID: fixtureWorkspaceID, plan: .personal, interval: .year))
        expect(refused.checkout == .failed(refusedText) && refusedRecorder.opened.isEmpty && refused.pendingCheckout == nil,
               "a foreign checkout host is refused and never opened")
        try render(CloudPlanSheet(model: refused, step: .review, interval: .year, agreed: true), size: nil,
                   appearance: .aqua, to: output.appendingPathComponent("plan-review-refused-light.png"))

        // Closing the sheet while the checkout is being created drops it: no page opens later.
        let slowRecorder = BillingRecorder()
        let slow = try model("slow", SummaryBox(fixtureMe(stored: 212_000_000_000, billing: billingBeta)), recorder: slowRecorder, delay: 0.5)
        slow.perform(.choosePlan)
        slow.loadQuote(personal.selection)
        settle { if case .loaded = slow.quote { return true } else { return false } }
        var slowRequest = personal
        slowRequest.consent = ParaAirCloudCheckoutConsent(disclosureVersion: OfferBox().version, autoRenew: true, terms: true)
        slow.startCheckout(slowRequest)
        expect(slow.checkout == .working, "a checkout shows progress while it is created")
        slow.closePlans()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        expect(slowRecorder.requests.count == 1 && slowRecorder.opened.isEmpty && slow.checkout == .idle && slow.pendingCheckout == nil,
               "closing the sheet drops a checkout still being created")
        slow.startCheckout(slowRequest)
        expect(slow.checkout == .idle && slowRecorder.requests.count == 1, "checkout starts only from the open sheet")

        // The portal: Update Payment… opens Stripe's portal; a checkout host in a portal reply is refused.
        let portalRecorder = BillingRecorder()
        let owner = try model("portal", SummaryBox(fixtureMe(stored: 1_240_000_000_000, billing: billingPastDue, kind: "team", seats: 3)),
                              recorder: portalRecorder)
        expect(owner.billing.controls.map(\.action) == [.updatePayment], "past due offers Update Payment…")
        owner.perform(.updatePayment)
        settle { !portalRecorder.opened.isEmpty || owner.message != nil }
        settle { !owner.billingBusy }
        expect(portalRecorder.opened == [stripePortal] && owner.message == nil, "Update Payment… opens the processor portal")
        let wrongRecorder = BillingRecorder()
        let wrong = try model("portal-refused", SummaryBox(fixtureMe(stored: 212_000_000_000, billing: billingActive)),
                              recorder: wrongRecorder, portal: stripeCheckout)
        wrong.perform(.managePlan)
        settle { wrong.message != nil }
        expect(wrong.message == refusedText && wrongRecorder.opened.isEmpty, "a checkout host in a portal reply is refused")
        try render(ConnectionsView(stateRoot: wrong.stateRoot, vault: MemoryVault(), cloudAccount: wrong),
                   size: CGSize(width: 680, height: 800), appearance: .aqua,
                   to: output.appendingPathComponent("storage-billing-portal-refused-light.png"))

        // A service from before billing: Manage Plan… opens its plan page; nothing to choose.
        let legacyRecorder = BillingRecorder()
        let manage = URL(string: "https://account.parafield.ai/plan")!
        let legacy = try model("legacy", SummaryBox(fixtureMe(stored: 212_000_000_000, manageUrl: manage)), recorder: legacyRecorder)
        expect(legacy.billing.controls == [CloudBillingPresentation.managePlan], "an older service keeps its Manage Plan link")
        legacy.perform(.managePlan)
        legacy.perform(.choosePlan)
        expect(legacyRecorder.opened == [manage] && !legacy.planSheetPresented, "an older service opens its plan page and offers no checkout")

        // Review 2026-10-13 (app). A payment page that is open and unpaid is never followed by a second checkout:
        // Done, the home window's Choose a Plan… and a reopened sheet all keep showing it. Start Over is the way out,
        // and the next checkout makes the earlier page unpayable on the service.
        let onceRecorder = BillingRecorder()
        let once = try model("once", SummaryBox(fixtureMe(stored: 212_000_000_000, billing: billingBeta)), recorder: onceRecorder,
                             checkout: [stripeCheckout, stripeCheckout2])
        once.perform(.choosePlan)
        agree(once, personal)
        expect(once.checkout == .opened(stripeCheckout), "the first checkout opens")
        once.perform(.choosePlan)
        expect(once.checkout == .opened(stripeCheckout), "Choose a Plan… while the sheet shows the payment page keeps it")
        once.closePlans()
        expect(once.billing.controls.map(\.title) == ["Finish Payment…"], "an open payment page is offered again, not a new plan choice")
        expect(once.billing.notice?.text == "A payment page is open for this workspace. Your plan shows here once the payment goes through.",
               "Storage Settings says a payment page is open")
        try render(ConnectionsView(stateRoot: once.stateRoot, vault: MemoryVault(), cloudAccount: once),
                   size: CGSize(width: 680, height: 800), appearance: .aqua,
                   to: output.appendingPathComponent("storage-billing-payment-open-light.png"))
        once.perform(.choosePlan)
        expect(once.planSheetPresented && once.checkout == .opened(stripeCheckout), "the reopened sheet shows the open payment page")
        once.loadQuote(personal.selection)
        settle { if case .loading = once.quote { return false } else { return true } }
        var again = personal
        again.consent = ParaAirCloudCheckoutConsent(disclosureVersion: OfferBox().version, autoRenew: true, terms: true)
        once.startCheckout(again)
        settle { once.checkout != .working }
        expect(onceRecorder.requests.count == 1 && onceRecorder.opened == [stripeCheckout], "no second checkout while one is open")
        // A folder switch replaces the model; the open page is still known.
        let replaced = CloudAccountModel(stateRoot: once.stateRoot, dependencies: dependencies, baseURL: { _ in fixtureIssuer },
                                         summaryLoader: { _ in (fixtureMe(stored: 1, billing: billingBeta), fixtureWorkspaceID) },
                                         openURL: { _ in true })
        expect(replaced.pendingCheckout?.url == stripeCheckout, "a replaced model still knows the open payment page")
        once.startOver()
        expect(once.pendingCheckout == nil && once.checkout == .idle && once.planSheetPresented, "Start Over returns to the plan choice")
        settle { offerLoaded(once) }
        agree(once, personal)
        expect(onceRecorder.requests.count == 2 && once.checkout == .opened(stripeCheckout2), "after Start Over a new checkout opens")

        // The drive's workspace decides the plan. Unresolved, nothing billing-related is shown, never another workspace's.
        let teamReadOnly = ParaAirCloudBilling(provider: .stripe, status: .readOnly, plan: .team, interval: .month, seats: 3,
                                               currentPeriodEnd: day("2026-10-05"), readOnlyAt: day("2026-10-05"), deletionAt: day("2026-11-04"),
                                               checkoutAvailable: true, portalAvailable: true)
        let teamID = "ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YD"
        let twoWorkspaces = fixtureMe(stored: 1, billing: billingActive, extra: [fixtureTeam(billing: teamReadOnly)])
        let unresolvedRecorder = BillingRecorder()
        let unresolved = try model("unresolved", SummaryBox(twoWorkspaces), recorder: unresolvedRecorder, workspaceID: nil)
        expect(unresolved.workspace == nil, "an unresolved drive workspace names no workspace")
        expect(unresolved.billing == CloudBillingPresentation() && unresolved.usage.billing == CloudBillingPresentation(),
               "an unresolved drive workspace shows no plan, notice or billing action")
        expect(unresolved.presentationState == .failed
               && CloudUsagePresentation.make(unresolved.workspace, state: unresolved.presentationState).planLine == "Plan and usage are unavailable right now.",
               "an unresolved drive workspace reads as unavailable, with Retry")
        unresolved.perform(.managePlan)
        settle { !unresolved.billingBusy }
        expect(unresolvedRecorder.opened.isEmpty, "Manage Plan… opens nothing for an unresolved workspace")
        try render(ConnectionsView(stateRoot: unresolved.stateRoot, vault: MemoryVault(), cloudAccount: unresolved),
                   size: CGSize(width: 680, height: 800), appearance: .aqua,
                   to: output.appendingPathComponent("storage-billing-unresolved-light.png"))
        // A profile that saved its workspace needs no lookup, even after the drive is gone.
        let saved = try model("saved-workspace", SummaryBox(twoWorkspaces), recorder: BillingRecorder(), workspaceID: nil, profileWorkspaceID: teamID)
        expect(saved.workspace?.id == teamID && saved.billing.notice?.tone == .problem, "the saved workspace's read-only plan is shown")

        // Waiting for the payment: an intermediate change (the processor's customer appears first) does not end the
        // wait, and coming back to ParaAir refreshes until the plan is live.
        let waitSummary = SummaryBox(fixtureMe(stored: 1, billing: billingBeta))
        let waiter = try model("waiter", waitSummary, recorder: BillingRecorder())
        waiter.perform(.choosePlan)
        agree(waiter, personal)
        var incomplete = billingBeta
        incomplete.portalAvailable = true
        waitSummary.me = fixtureMe(stored: 1, billing: incomplete)
        settle { waiter.workspace?.billing == incomplete }
        expect(waiter.workspace?.billing == incomplete, "the watch saw the intermediate change")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        expect(waiter.paymentWaitTimedOut && waiter.pendingCheckout != nil && waiter.checkout == .opened(stripeCheckout),
               "the wait runs out to a neutral state, still on the open page")
        try render(CloudPlanSheet(model: waiter), size: nil, appearance: .aqua, to: output.appendingPathComponent("plan-waiting-timed-out-light.png"))
        waitSummary.me = fixtureMe(stored: 1, billing: billingActive)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        settle { waiter.workspace?.billing?.status == .active }
        expect(waiter.workspace?.billing?.status == .active && waiter.checkout == .opened(stripeCheckout),
               "after an intermediate change, returning to ParaAir still shows the paid plan")
        expect(!waiter.paymentWaitTimedOut && waiter.pendingCheckout == nil, "a live plan ends the wait")

        // The merchant and the terms come from the offer, not from the workspace's earlier processor: an ended Stripe
        // plan bought again through Paddle says Paddle charges.
        let switched = try model("switched", SummaryBox(fixtureMe(stored: 1, billing: billingReadOnlyStripe, status: "read_only")),
                                 recorder: BillingRecorder(), offer: OfferBox(provider: .paddle))
        switched.perform(.choosePlan)
        settle { offerLoaded(switched) }
        switched.loadQuote(personal.selection)
        settle { if case .loaded = switched.quote { return true } else { return false } }
        if case .loaded(let quote) = switched.quote {
            expect(CloudPlanSheet.seller(OfferBox(provider: .stripe).fixture(nil)) == "Sold by Parafield Inc.", "a name ending in a period gets no second one")
            expect(CloudPlanSheet.seller(quote.offer) == "Sold by Paddle, our reseller."
                   && quote.terms.bullets.contains { $0.hasPrefix("Then Paddle, our reseller, charges") }, "the offer names the merchant who charges")
        } else { failures.append("the switched processor's terms load") }

        // Prices come from the service: a changed price shows without an app update, and no offer means no checkout.
        let raised = try model("raised", SummaryBox(fixtureMe(stored: 1, billing: billingBeta)), recorder: BillingRecorder(),
                               offer: OfferBox(prices: ["personal_month": 1_200]))
        raised.perform(.choosePlan)
        settle { offerLoaded(raised) }
        if case .loaded(let offer) = raised.offer {
            expect(CloudPlanOffer.make(.personal, interval: .month, seats: 1, offer: offer)?.price == "$12 per month", "the card shows the service's price")
        } else { failures.append("the raised offer loads") }
        let closedRecorder = BillingRecorder()
        let closed = try model("offer-failed", SummaryBox(fixtureMe(stored: 1, billing: billingBeta)), recorder: closedRecorder,
                               offer: OfferBox(failure: DriveError(EIO, "Paid plans can’t be bought right now. Try again later")))
        closed.perform(.choosePlan)
        settle { if case .failed = closed.offer { return true } else { return false } }
        expect(closed.offer == .failed("Paid plans can’t be bought right now. Try again later.") && !closed.planChoice.personal.available,
               "without the service's offer nothing can be chosen")
        try render(CloudPlanSheet(model: closed), size: nil, appearance: .aqua, to: output.appendingPathComponent("plan-offer-failed-light.png"))
        closed.loadQuote(personal.selection)
        settle { if case .failed = closed.quote { return true } else { return false } }
        var blind = personal
        blind.consent = ParaAirCloudCheckoutConsent(disclosureVersion: OfferBox().version, autoRenew: true, terms: true)
        closed.startCheckout(blind)
        expect(closedRecorder.requests.isEmpty && closed.checkout == .idle, "no checkout without the service's terms")

        // Seats: the default is not the workspace's entitlement, and the plan cards count seats, not members.
        expect(CloudPlanChoice.defaultSeats(fixtureTeam(billing: billingBeta, seats: 5)) == 1, "Team seats do not start at the entitlement")
        expect(CloudPlanOffer.make(.team, interval: .month, seats: 3, offer: OfferBox().fixture(nil))?.sizeCaption.contains("seats") == true,
               "the Team card counts seats")
        return failures
    }

    static func checkBilling() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        func make(_ billing: ParaAirCloudBilling?, kind: String = "personal", role: String = "owner", seats: Int = 1, manageUrl: URL? = nil,
                  state: CloudSummaryState = .loaded, choice: Bool = false) -> CloudBillingPresentation {
            CloudBillingPresentation.make(fixtureMe(stored: 1, billing: billing, kind: kind, role: role, seats: seats,
                                                    manageUrl: manageUrl).workspaces.first, state: state, planChoiceAvailable: choice)
        }
        typealias Row = CloudBillingPresentation.Row
        let empty = CloudBillingPresentation()

        expect(make(ParaAirCloudBilling(provider: .none, status: .none)) == empty, "billing off shows nothing")
        expect(make(nil) == empty, "a service without billing shows nothing")
        expect(make(nil, manageUrl: URL(string: "https://account.parafield.ai/plan")!).controls == [CloudBillingPresentation.managePlan],
               "a service without billing keeps its plan link")
        expect(make(billingPastDue, state: .failed) == empty, "a failed summary shows no billing")
        expect(make(billingActive, state: .loading).date == Row(label: "Renews", value: "October 12, 2027"),
               "billing stays visible while a refresh runs")

        let beta = make(billingBeta, choice: true)
        expect(beta.summary == nil && beta.date == nil && beta.notice == nil && beta.controls == [CloudBillingPresentation.choosePlan],
               "the beta plan offers Choose a Plan… without a notice")
        expect(make(billingBeta).controls.isEmpty, "no plan to choose without checkout")

        let active = make(billingActive)
        expect(active.summary == "Personal, billed yearly", "active summary names the plan and period")
        expect(active.date == Row(label: "Renews", value: "October 12, 2027"), "active shows the renewal date in UTC")
        expect(active.notice == nil && active.controls == [CloudBillingPresentation.managePlan], "active offers Manage Plan… only")
        var team = billingActive
        team.plan = .team; team.interval = .month; team.seats = 3; team.extraStorageTb = 2
        expect(make(team, kind: "team", seats: 3).summary == "Team, 3 seats, billed monthly, 2 TB added storage", "team summary counts seats")
        team.seats = 1
        expect(make(team, kind: "team").summary == "Team, 1 seat, billed monthly, 2 TB added storage", "one seat is singular")

        let cancelled = make(billingCancelled)
        expect(cancelled.date == Row(label: "Ends", value: "November 12, 2026"), "a cancelled plan shows its end")
        expect(cancelled.notice == HomePresentation.Notice(id: "billing", text: "Your plan is cancelled and ends on November 12, 2026. Files then stay "
                                         + "read-only until December 12, 2026 and are deleted after that. To keep it, resume the plan in Manage Plan.",
                                         tone: .attention), "a cancelled plan says what happens and how to keep it")

        let pastDue = make(billingPastDue, kind: "team", seats: 3)
        expect(pastDue.date == Row(label: "Grace period ends", value: "October 26, 2026"), "past due shows the grace end")
        expect(pastDue.notice == HomePresentation.Notice(id: "billing", text: "Your last payment didn’t go through. Everything keeps working until October 26, 2026. "
                                       + "Update your payment method by then to keep your plan.", tone: .attention), "past due notice")
        expect(pastDue.controls == [.init(action: .updatePayment, title: "Update Payment…", prominent: true)],
               "past due offers Update Payment… prominently")
        let member = make(billingMemberPastDue, kind: "team", role: "member", seats: 3)
        expect(member.controls.isEmpty && member.notice?.text
               == "This workspace’s last payment didn’t go through. Everything keeps working until October 26, 2026. "
               + "Ask the workspace owner to update the payment method.", "a member is told to ask the owner")

        let readOnly = make(billingReadOnly)
        expect(readOnly.summaryLabel == "Previous plan" && active.summaryLabel == "Billing", "an ended plan is not shown as billed")
        expect(readOnly.date == Row(label: "Read-only until", value: "November 4, 2026"), "read-only shows until when")
        expect(readOnly.notice == HomePresentation.Notice(id: "billing", text: "Your plan ended, so this workspace is read-only until November 4, 2026. "
                                        + "Choose a plan by then, or the files are deleted.", tone: .problem),
               "read-only says why, until when and what to do")
        expect(readOnly.controls == [.init(action: .choosePlan, title: "Choose a Plan…", prominent: true), CloudBillingPresentation.managePlan],
               "read-only offers a plan first")
        expect(make(billingReadOnly, role: "member").notice?.text == "This workspace’s plan ended, so it’s read-only until November 4, 2026. "
               + "Ask the workspace owner to choose a plan by then, or the files are deleted.", "a member is told to ask the owner")

        let pending = make(billingPendingDeletion)
        expect(pending.date == Row(label: "Deletion scheduled", value: "October 10, 2026"), "pending deletion shows the date")
        expect(pending.notice == HomePresentation.Notice(id: "billing", text: "The read-only period ended on October 10, 2026, so this workspace’s "
                                       + "files can be deleted at any time. Choose a plan now to keep them.", tone: .problem),
               "pending deletion explains the date")
        expect(pending.controls == [.init(action: .choosePlan, title: "Choose a Plan…", prominent: true)], "pending deletion offers a plan")
        expect(make(billingDeleting).controls.isEmpty && make(billingDeleting).notice?.tone == .problem, "deleting offers nothing")
        expect(make(billingDeleted).controls == [CloudBillingPresentation.choosePlan], "a deleted workspace can choose a plan again")

        // The home window carries the billing notice for ParaAir Cloud only; the menu bar panel shows it first.
        let scenarios = Dictionary(uniqueKeysWithValues: homeScenarios)
        let home = HomePresentation.make(scenarios["14-cloud-past-due"]!)
        expect(home.notices.first == pastDue.notice && home.status.tone == .good, "past due keeps the drive connected and adds the notice")
        var ownBucket = scenarios["14-cloud-past-due"]!
        ownBucket.storageKind = .ownBucket
        expect(!HomePresentation.make(ownBucket).notices.contains { $0.id == "billing" }, "your own bucket never shows ParaAir billing")
        let fenced = HomePresentation.make(scenarios["15-cloud-read-only"]!)
        expect(fenced.status == .init(title: "Connected, read-only", detail: "You can open, download, move and delete files. New and changed files don’t upload.",
                                      tone: .attention) && fenced.primary.action == .openInFinder,
               "a read-only workspace says so in the drive status")
        var fencedOwnBucket = scenarios["15-cloud-read-only"]!
        fencedOwnBucket.storageKind = .ownBucket
        expect(HomePresentation.make(fencedOwnBucket).status.title == "Connected", "read-only status is ParaAir Cloud only")
        expect(HomePresentation.make(scenarios["16-cloud-pending-deletion"]!).notices.first?.tone == .problem, "pending deletion is a problem")
        expect(HomePresentation.make(scenarios["13-cloud-plan-active"]!).notices.isEmpty, "an active plan adds no notice")

        // What the plan sheet can sell.
        let teamID = "ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YD"
        let offer = OfferBox().fixture(nil)
        let both = CloudPlanChoice.make(fixtureMe(stored: 1, billing: billingBeta, extra: [fixtureTeam(billing: billingBeta)]),
                                        preferredWorkspaceID: fixtureWorkspaceID, offer: offer)
        expect(both.personal.workspaces.map(\.id) == [fixtureWorkspaceID] && both.team.workspaces.map(\.id) == [teamID],
               "each plan is sold for its own kind of workspace")
        let personalOnly = CloudPlanChoice.make(fixtureMe(stored: 1, billing: billingBeta), preferredWorkspaceID: nil, offer: offer)
        expect(personalOnly.team.reason == "For team workspaces. This account has none yet.", "no team workspace")
        var teamActive = billingActive
        teamActive.plan = .team
        expect(CloudPlanChoice.make(fixtureMe(stored: 1, billing: billingBeta, extra: [fixtureTeam(billing: teamActive)]),
                                    preferredWorkspaceID: nil, offer: offer).team.reason == "Your team already has a plan.", "a paid team")
        expect(CloudPlanChoice.make(fixtureMe(stored: 1, billing: billingBeta,
                                              extra: [fixtureTeam(billing: ParaAirCloudBilling(provider: .paddle, status: .none), role: "admin")]),
                                    preferredWorkspaceID: nil, offer: offer).team.reason == "Only the workspace owner can choose this plan.", "not the owner")
        let notLoaded = CloudPlanChoice.make(fixtureMe(stored: 1, billing: billingBeta), preferredWorkspaceID: nil, offer: nil)
        expect(!notLoaded.personal.available && !notLoaded.team.available, "nothing is on sale before the offer arrives")
        var personalOnlyOffer = offer
        personalOnlyOffer.prices.removeAll { $0.plan == .team }
        expect(!CloudPlanChoice.make(fixtureMe(stored: 1, billing: billingBeta, extra: [fixtureTeam(billing: billingBeta)]),
                                     preferredWorkspaceID: nil, offer: personalOnlyOffer).team.available, "a plan without a price is not on sale")

        // Plan cards: the plan size leads, the price supports it. Every figure comes from the offer.
        expect(CloudPlanOffer.make(.personal, interval: .month, seats: 1, offer: offer)
               == .init(name: "Personal", size: "1 TB", sizeCaption: "of storage for you", price: "$10 per month", detail: "Or $100 a year"),
               "Personal monthly card")
        expect(CloudPlanOffer.make(.personal, interval: .year, seats: 1, offer: offer)?.price == "$100 per year"
               && CloudPlanOffer.make(.personal, interval: .year, seats: 1, offer: offer)?.detail == "Saves $20 a year", "Personal yearly card")
        expect(CloudPlanOffer.make(.team, interval: .month, seats: 3, offer: offer)
               == .init(name: "Team", size: "3 TB", sizeCaption: "3 seats, shared by the team", price: "$48 per month", detail: "$16 per seat"),
               "Team monthly card")
        expect(CloudPlanOffer.make(.team, interval: .year, seats: 3, offer: offer)?.price == "$480 per year"
               && CloudPlanOffer.make(.team, interval: .year, seats: 3, offer: offer)?.detail == "$160 per seat, saves $96 a year", "Team yearly card")
        expect(CloudPlanOffer.make(.team, interval: .month, seats: 1, offer: offer)?.sizeCaption == "1 seat, shared by the team", "one seat is singular")
        expect(CloudPlanOffer.perSeat(interval: .month, offer: offer)
               == .init(name: "Team", size: "1 TB", sizeCaption: "per seat, shared by the team", price: "$16 per seat per month",
                        detail: "Or $160 per seat a year"), "Team that can't be chosen shows per-seat terms")
        expect(CloudPlanOffer.perSeat(interval: .year, offer: offer)?.price == "$160 per seat per year"
               && CloudPlanOffer.perSeat(interval: .year, offer: offer)?.detail == "Saves $32 per seat a year", "per-seat yearly terms")
        expect(CloudPlanOffer.make(.personal, interval: .year, seats: 1, offer: personalOnlyOffer) != nil
               && CloudPlanOffer.make(.team, interval: .year, seats: 3, offer: personalOnlyOffer) == nil, "no card price without an offer price")

        // An open payment page: Finish Payment… instead of a new plan choice, with the state's own notice kept.
        let open = CloudBillingPresentation.make(fixtureMe(stored: 1, billing: billingBeta).workspaces.first, state: .loaded,
                                                 planChoiceAvailable: true, pendingCheckout: true)
        expect(open.controls == [CloudBillingPresentation.finishPayment] && open.notice?.tone == .neutral, "an open payment page is offered again")
        let openReadOnly = CloudBillingPresentation.make(fixtureMe(stored: 1, billing: billingReadOnly).workspaces.first, state: .loaded,
                                                         planChoiceAvailable: true, pendingCheckout: true)
        expect(openReadOnly.controls == [.init(action: .choosePlan, title: "Finish Payment…", prominent: true), CloudBillingPresentation.managePlan]
               && openReadOnly.notice == readOnly.notice, "read-only keeps its notice while a payment page is open")
        // A paid status without a plan the service knows still offers the portal and its dates.
        var unknownPlan = billingActive
        unknownPlan.plan = nil; unknownPlan.interval = nil
        let unknown = make(unknownPlan)
        expect(unknown.summary == nil && unknown.date == Row(label: "Renews", value: "October 12, 2027") && unknown.controls == [CloudBillingPresentation.managePlan],
               "an unknown paid plan keeps its date and Manage Plan…")
        var crowded = billingPastDue
        crowded.seats = 1001
        expect(make(crowded, kind: "team", seats: 1001).summary == "Team, 1001 seats, billed monthly", "more than 1000 seats still show")

        // Copy: no em dashes anywhere in billing text.
        var copy: [String] = []
        for presentation in [beta, active, cancelled, pastDue, member, readOnly, pending, make(billingDeleting), make(billingDeleted)] {
            copy += [presentation.summary, presentation.date?.label, presentation.date?.value, presentation.notice?.text].compactMap { $0 }
            copy += presentation.controls.map(\.title)
        }
        for plan in ParaAirCloudBilling.Plan.allCases {
            for interval in ParaAirCloudBilling.Interval.allCases {
                for card in [CloudPlanOffer.make(plan, interval: interval, seats: 3, offer: offer), .perSeat(interval: interval, offer: offer),
                             .unpriced(plan, interval: interval)].compactMap({ $0 }) {
                    copy += [card.name, card.size, card.sizeCaption, card.price, card.detail]
                }
                for seller in [ParaAirCloudBilling.Provider.stripe, .paddle] {
                    let quoted = OfferBox(provider: seller).fixture(ParaAirCloudOfferRequest(plan: plan, interval: interval,
                                                                                            seats: plan == .team ? 3 : 1, extraStorageTb: 1))
                    guard let terms = quoted.quote.flatMap(ParaAirCloudCheckoutTerms.init) else { failures.append("fixture terms parse"); continue }
                    copy += [terms.heading, terms.priceLine, terms.renewalConsent, terms.documentsConsent, CloudPlanSheet.seller(quoted)] + terms.bullets
                }
            }
        }
        copy += [both.team.reason, personalOnly.team.reason, open.notice?.text].compactMap { $0 } + open.controls.map(\.title)
        expect(!copy.joined(separator: "\n").contains("\u{2014}"), "billing copy avoids em dashes")
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

    // MARK: Open at login

    /// The toggle beside "Connect the drive when ParaAir opens", from a fixture status.
    /// Nothing here reaches ServiceManagement, System Settings or the app's preferences.
    @MainActor
    static func renderLoginItem(output: URL) throws {
        let input = Dictionary(uniqueKeysWithValues: homeScenarios)["5-connected"]!
        let states: [(String, LoginItemStatus)] = [("enabled", .enabled), ("disabled", .notRegistered), ("approval", .requiresApproval)]
        for (name, status) in states {
            let model = LoginItemModel(service: FixtureLoginItemService(status), rememberChoice: {})
            for appearance in name == "approval" ? [NSAppearance.Name.aqua, .darkAqua] : [.aqua] {
                try render(DriveHomeContent(input: input, details: details(for: input), connectAutomatically: .constant(true),
                                            actions: HomeActions(), loginItem: model),
                           size: CGSize(width: 620, height: 680), appearance: appearance,
                           to: output.appendingPathComponent("home-login-\(name)-\(suffix(appearance)).png"))
            }
            try render(MenuBarPanel(input: input, details: details(for: input), connectAutomatically: .constant(true),
                                    actions: HomeActions(), loginItem: model),
                       size: nil, appearance: .aqua, to: output.appendingPathComponent("menu-login-\(name)-light.png"))
        }
        let refused = FixtureLoginItemService(.notRegistered)
        refused.failsChanges = true
        let failed = LoginItemModel(service: refused, rememberChoice: {})
        failed.setEnabled(true)
        try render(DriveHomeContent(input: input, details: details(for: input), connectAutomatically: .constant(true),
                                    actions: HomeActions(), loginItem: failed),
                   size: CGSize(width: 620, height: 680), appearance: .aqua,
                   to: output.appendingPathComponent("home-login-failed-light.png"))
        // A gentle update reminder in the home window and the menu bar panel.
        var ready = input; ready.updateTitle = "ParaAir 0.1.0 alpha 3"
        var install = HomeActions(); install.checkForUpdates = {}
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try render(DriveHomeContent(input: ready, details: details(for: ready), connectAutomatically: .constant(true), actions: install),
                       size: CGSize(width: 620, height: 680), appearance: appearance,
                       to: output.appendingPathComponent("home-update-ready-\(suffix(appearance)).png"))
        }
        try render(MenuBarPanel(input: ready, details: details(for: ready), connectAutomatically: .constant(true), actions: install),
                   size: nil, appearance: .aqua, to: output.appendingPathComponent("menu-update-ready-light.png"))
        // Advanced open: the version with its release stage, Check for Updates and the automatic check setting.
        var updates = HomeActions(); updates.checkForUpdates = {}
        var versioned = details(for: input); versioned.version = "0.1.0 alpha 2 (161)"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try render(DriveHomeContent(input: input, details: versioned, connectAutomatically: .constant(true), actions: updates,
                                        loginItem: LoginItemModel(service: FixtureLoginItemService(.enabled), rememberChoice: {}),
                                        checkUpdatesAutomatically: .constant(true), startsWithAdvancedOpen: true),
                       size: CGSize(width: 620, height: 900), appearance: appearance,
                       to: output.appendingPathComponent("home-advanced-updates-\(suffix(appearance)).png"))
        }
    }

    /// The prominent button sits beside native push buttons, so it must match their height.
    @MainActor
    static func checkButtonHeights() -> [String] {
        var failures: [String] = []
        for (name, size) in [("small", ControlSize.small), ("regular", .regular), ("large", .large), ("extraLarge", .extraLarge)] {
            let glide = NSHostingView(rootView: Button("Open System Settings") {}.buttonStyle(.glideProminent).controlSize(size)).fittingSize.height
            let native = NSHostingView(rootView: Button("Check Again") {}.controlSize(size)).fittingSize.height
            if glide != native { failures.append("button height (\(name)): prominent \(glide) vs native \(native)") }
        }
        return failures
    }

    static func checkUpdateGate() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append("update gate: " + message) } }
        expect(UpdateGate.outcome([]) == .install, "no mounted drive installs at once")
        expect(UpdateGate.outcome([("Client Footage", true), ("Archive", true)]) == .install, "ejected drives install")
        expect(UpdateGate.outcome([("Client Footage", true), ("Archive", false)]) == .blocked(drives: ["Archive"]), "a busy drive blocks")
        expect(UpdateGate.blockedTitle(["Archive"]) == "“Archive” is in use", "one drive names it")
        expect(UpdateGate.blockedTitle(["A", "B"]) == "2 drives are in use", "two drives count them")
        let message = UpdateGate.blockedMessage(["Archive"])
        expect(message.contains("Try Again") && message.contains("waiting to upload stay on this Mac") && !message.contains("—"),
               "the message says what to do and that nothing is lost")
        return failures
    }

    static func checkVersionText() -> [String] {
        var failures: [String] = []
        func expect(_ value: AppVersionText, _ line: String) {
            if value.line != line { failures.append("version text: expected \(line), got \(value.line)") }
        }
        expect(.make(marketing: "0.1.0", build: "148", releaseTag: "v0.1.0-alpha.2"), "0.1.0 alpha 2 (148)")
        expect(.make(marketing: "0.2.0", build: "201", releaseTag: "v0.2.0-rc.1"), "0.2.0 release candidate 1 (201)")
        expect(.make(marketing: "1.0.0", build: "300", releaseTag: "v1.0.0"), "1.0.0 (300)")
        expect(.make(marketing: "0.1.0", build: "148", releaseTag: "v0.1.1-alpha.1"), "0.1.0 (148)")
        expect(.make(marketing: "0.1.0", build: "1", releaseTag: "nightly"), "0.1.0 (1)")
        expect(.make(marketing: nil, build: nil, releaseTag: nil), "Development build")
        return failures
    }

    @MainActor
    static func checkLoginItem() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        var choices = 0
        func model(_ service: FixtureLoginItemService) -> LoginItemModel { LoginItemModel(service: service, rememberChoice: { choices += 1 }) }

        let on = FixtureLoginItemService(.enabled)
        let enabled = model(on)
        expect(enabled.isOn && !enabled.needsApproval, "an enabled login item shows the toggle on")
        enabled.setEnabled(true)
        expect(on.calls.isEmpty && choices == 0, "turning on an enabled login item does nothing")
        enabled.setEnabled(false)
        expect(on.calls == ["unregister"] && enabled.status == .notRegistered && !enabled.isOn && choices == 1,
               "turning it off unregisters and records the choice")

        let off = FixtureLoginItemService(.notRegistered)
        let disabled = model(off)
        expect(!disabled.isOn, "a login item that isn't registered shows the toggle off")
        disabled.setEnabled(true)
        expect(off.calls == ["register"] && disabled.isOn && !disabled.changeFailed && choices == 2,
               "turning it on registers and records the choice")

        let pending = model(FixtureLoginItemService(.requiresApproval))
        expect(!pending.isOn && pending.needsApproval, "a login item awaiting approval is off and points to System Settings")

        let refused = FixtureLoginItemService(.notRegistered)
        refused.failsChanges = true
        let failed = model(refused)
        failed.setEnabled(true)
        expect(failed.changeFailed && !failed.isOn, "a refused change keeps the toggle off and says so")

        // A change made in System Settings shows up on the next refresh.
        let live = FixtureLoginItemService(.enabled)
        let watched = model(live)
        live.status = .requiresApproval
        watched.refresh()
        expect(watched.needsApproval, "refresh reads the current status")

        let copy = [LoginItemToggle.title, LoginItemToggle.approvalNote, LoginItemToggle.failureNote, LoginItemToggle.settingsButton]
        expect(!copy.joined().contains("\u{2014}"), "login item copy avoids em dashes")
        expect(LoginItemToggle.approvalNote == "Allowed in System Settings only." && LoginItemToggle.settingsButton == "Open Login Items…",
               "approval copy matches the spec")
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

/// What a fixture billing model asked the service for and would have opened in the browser.
final class BillingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var checkouts: [ParaAirCloudCheckoutRequest] = []
    private var urls: [URL] = []
    var requests: [ParaAirCloudCheckoutRequest] { lock.withLock { checkouts } }
    var opened: [URL] { lock.withLock { urls } }
    @discardableResult
    func record(_ request: ParaAirCloudCheckoutRequest) -> Int { lock.withLock { checkouts.append(request); return checkouts.count } }
    func open(_ url: URL) { lock.withLock { urls.append(url) } }
}

/// The offer the fixture service returns (`GET /v1/billing/offer`), with the service's Appendix A text
/// (cloud/src/billing/disclosure.ts, refund Option A) for the snapshot day. `requests` records the selections asked for.
final class OfferBox: @unchecked Sendable {
    let provider: ParaAirCloudBilling.Provider
    let version = "A-draft-2026-10-09"
    private let prices: [String: Int]
    private let failure: DriveError?
    private let lock = NSLock()
    private var asked: [ParaAirCloudOfferRequest?] = []
    static let catalog: [String: Int] = ["personal_month": 1_000, "personal_year": 10_000, "team_month": 1_600, "team_year": 16_000,
                                         "storage_month": 1_000, "storage_year": 12_000]

    init(provider: ParaAirCloudBilling.Provider = .stripe, prices: [String: Int] = [:], failure: DriveError? = nil) {
        self.provider = provider; self.prices = Self.catalog.merging(prices) { $1 }; self.failure = failure
    }
    var requests: [ParaAirCloudOfferRequest?] { lock.withLock { asked } }

    func offer(_ selection: ParaAirCloudOfferRequest?) throws -> ParaAirCloudBillingOffer {
        lock.withLock { asked.append(selection) }
        if let failure { throw failure }
        return fixture(selection)
    }

    func fixture(_ selection: ParaAirCloudOfferRequest?) -> ParaAirCloudBillingOffer {
        let ids = ["personal_month", "personal_year", "team_month", "team_year", "storage_month", "storage_year"]
        let rows = ids.map { id -> ParaAirCloudBillingOffer.Price in
            let parts = id.split(separator: "_").map(String.init)
            return .init(item: id, kind: parts[0] == "storage" ? .storage : .plan, plan: ParaAirCloudBilling.Plan(rawValue: parts[0]),
                         interval: ParaAirCloudBilling.Interval(rawValue: parts[1])!, unitAmountCents: prices[id]!, perMember: parts[0] == "team")
        }
        var quote: ParaAirCloudBillingOffer.Quote?
        if let selection {
            let unit = prices["\(selection.plan.rawValue)_\(selection.interval.rawValue)"]!, block = prices["storage_\(selection.interval.rawValue)"]!
            let total = unit * (selection.plan == .team ? selection.seats : 1) + block * selection.extraStorageTb
            let text = Self.disclosure(selection, unit: unit, block: block, total: total, seller: provider)
            quote = .init(plan: selection.plan, interval: selection.interval, seats: selection.seats, extraStorageTb: selection.extraStorageTb,
                          amountCents: total, currency: "USD", terms: text.terms, consent: text.consent)
        }
        return ParaAirCloudBillingOffer(provider: provider, merchant: provider == .paddle ? .init(name: "Paddle", reseller: true)
                                            : .init(name: "Parafield Inc.", reseller: false),
                                        disclosureVersion: version, currency: "USD", prices: rows, quote: quote)
    }

    static func disclosure(_ s: ParaAirCloudOfferRequest, unit unitCents: Int, block: Int, total totalCents: Int,
                           seller: ParaAirCloudBilling.Provider) -> (terms: [String], consent: String) {
        let team = s.plan == .team, yearly = s.interval == .year, storageTb = s.extraStorageTb
        let unit = ParaAirCloudBillingCatalog.formatUSD(cents: unitCents), total = ParaAirCloudBillingCatalog.formatUSD(cents: totalCents)
        let when = yearly ? "every year on October 12" : "on the 12th of every month"
        let period = yearly ? "year" : "month"
        let charger = seller == .paddle ? "Paddle, our reseller, charges" : "we charge"
        let account = UISnapshots.fixtureIssuer.absoluteString + "/billing/account"
        var terms = ["ParaAir Cloud \(team ? "Team" : "Personal"), billed \(yearly ? "yearly" : "monthly")",
                     "\(unit) \(team ? "per member " : "")per \(period) plus tax. Renews automatically every \(period) until you cancel."]
        var bullets: [String] = []
        if team { bullets.append("You are buying \(s.seats) member seats\(storageTb > 0 ? " and added storage" : ""): \(total) per \(period) plus tax.") }
        bullets.append("Today you pay \(total) plus any tax, which is shown before you pay.")
        if storageTb > 0 {
            bullets.append("This includes \(storageTb) TB of added storage at \(ParaAirCloudBillingCatalog.formatUSD(cents: block)) per TB per \(period) plus tax.")
        }
        bullets.append(team ? "Then \(charger) for the current number of members, at \(unit) per member plus tax\(storageTb > 0 ? ", plus added storage" : ""), \(when)."
                            : "Then \(charger) \(total) plus tax \(when).")
        if team {
            bullets.append("Your \(yearly ? "yearly" : "monthly") charge changes when you add or remove members. Adding a member charges a prorated amount "
                + "\(yearly ? "for the rest of the year " : "")right away. Removing a member lowers the charge from your next \(yearly ? "yearly " : "")renewal; "
                + "the seat stays paid until then.")
            bullets.append("Includes 1 TB of storage per member, shared by the team, and up to 3 TB of full-speed transfer per member each month, shared. "
                + "No overage charges.")
        } else {
            bullets.append(storageTb > 0
                ? "Includes \(1 + storageTb) TB of storage and up to \(3 * (1 + storageTb)) TB of full-speed transfer each month. No overage charges."
                : "Includes 1 TB of storage and up to 3 TB of full-speed transfer each month. No overage charges.")
        }
        if yearly {
            bullets.append(team ? "We will email the owner and billing admins 25 to 30 days before each yearly renewal."
                           : "We will email you 25 to 30 days before each yearly renewal.")
        }
        bullets.append(team
            ? "The owner, or an admin with billing access, can cancel any time online in the ParaAir app (Settings > Account > Subscription) or at \(account). "
                + "Cancel before your renewal date to avoid the next charge."
            : "Cancel any time online: in the ParaAir app (Settings > Account > Subscription) or at \(account). Cancel before your renewal date "
                + "to avoid the next charge. You keep access until the end of the \(period) you paid for.")
        bullets.append("Full refund if you ask within 14 days of this first payment\(yearly ? " or within 14 days of any yearly renewal charge" : "").")
        bullets.append("We will email you at least 14 days before any price change, and you can cancel first.")
        terms += bullets.map { "- " + $0 }
        let renewal = team
            ? "I agree that this ParaAir Cloud Team plan renews automatically at \(unit) per member per \(period) plus tax, for the number of members at each renewal, until I cancel."
            : "I agree that my ParaAir Cloud Personal plan renews automatically at \(total) per \(period) plus tax until I cancel."
        let legal = UISnapshots.fixtureIssuer.absoluteString + "/legal/"
        let documents = "I agree to the [Terms of Service](\(legal)terms) and the [Subscription, Cancellation and Refund Policy](\(legal)subscription-policy)"
            + "\(team ? ", and I am authorized to agree for this team" : "")."
        return (terms, renewal + " " + documents)
    }
}

/// The summary the fixture service returns; replacing it stands in for a processor webhook.
final class SummaryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ParaAirCloudMe
    init(_ me: ParaAirCloudMe) { value = me }
    var me: ParaAirCloudMe {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A login item status for the snapshots. Records calls; never reaches ServiceManagement.
@MainActor
final class FixtureLoginItemService: LoginItemService {
    var status: LoginItemStatus
    var failsChanges = false
    private(set) var calls: [String] = []
    init(_ status: LoginItemStatus) { self.status = status }
    func register() throws {
        calls.append("register")
        if failsChanges { throw DriveError(EPERM, "fixture refused") }
        status = .enabled
    }
    func unregister() throws {
        calls.append("unregister")
        if failsChanges { throw DriveError(EPERM, "fixture refused") }
        status = .notRegistered
    }
    func openSystemSettings() { calls.append("open-settings") }
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
