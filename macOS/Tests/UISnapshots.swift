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
        failures += checkNaming()

        for (name, input) in homeScenarios {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] where appearance == .aqua || name.hasPrefix("1") || name.hasPrefix("5") {
                let view = DriveHomeContent(input: input, details: details(for: input),
                                            connectAutomatically: .constant(true), actions: HomeActions())
                try render(view, size: CGSize(width: 620, height: 680), appearance: appearance,
                           to: output.appendingPathComponent("home-\(name)-\(suffix(appearance)).png"))
            }
        }
        for (name, input) in homeScenarios where ["1-first-run", "3-turn-on", "5-connected", "6-connected-sign-in"].contains(name) {
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
        return [("1-first-run", firstRun), ("2-storage-ready", ready), ("3-turn-on", turnOn),
                ("4-checking", checking), ("5-connected", connected), ("6-connected-sign-in", mountedIssue),
                ("7-sign-in-needed", issue), ("8-connecting", connecting)]
    }()

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
        for (_, input) in homeScenarios {
            let text = ([HomePresentation.make(input).status.title, HomePresentation.make(input).status.detail]
                        + HomePresentation.make(input).steps.flatMap { [$0.title, $0.detail] }).joined()
            expect(!text.contains("\u{2014}"), "copy avoids em dashes")
            expect(!text.lowercased().contains("juicefs") && !text.lowercased().contains("metadata"), "copy avoids engine jargon")
        }
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
