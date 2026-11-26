import SwiftUI
import AppKit
import OSLog
import StreamDriveCore

/// Get Help… and Copy Diagnostics (release review 2026-11-26). ParaAir runs from the menu bar without a visible menu
/// bar of its own, so these sit where people find them: About ParaAir, the menu bar panel's More menu and the ParaAir
/// window's Advanced section.
struct SupportActions {
    var getHelp: () -> Void = {}
    /// Puts the diagnostics on the clipboard; false when nothing could be copied.
    var copyDiagnostics: @MainActor () async -> Bool = { false }
    var showAbout: () -> Void = {}

    /// What the app uses. `stateRoot` is the selected state folder; nil reads the one ParaAir saved (About ParaAir has no
    /// model of its own).
    @MainActor static func live(stateRoot: URL? = nil, showAbout: @escaping () -> Void = {}) -> SupportActions {
        SupportActions(getHelp: { _ = NSWorkspace.shared.open(SupportLinks.helpEmail(version: .current, system: SupportDiagnosticsCollector.system)) },
                       copyDiagnostics: { await SupportDiagnosticsCollector.copy(stateRoot: stateRoot ?? SupportDiagnosticsCollector.savedStateRoot) },
                       showAbout: showAbout)
    }
}

/// Gathers Copy Diagnostics' input. `paraair setup-status --json` and `paraair status NAME --json` come from the CLI
/// helper this app ships, run as the user exactly as another app would run them; the log lines are this app's own,
/// which it may read without an entitlement (`OSLogStore` scoped to its process). StreamDriveCore's
/// `SupportDiagnostics` removes tokens, keys, file names and other people's addresses before anything is copied.
enum SupportDiagnosticsCollector {
    static let timeout: TimeInterval = 20
    /// More than this from one command is not a status report: it is left out, and the command stopped.
    static let maxOutputBytes = 4 << 20
    /// Collecting waits on the helper, so it runs here, never on the Swift concurrency pool's few threads.
    static let queue = DispatchQueue(label: "dev.streamdrive.app.diagnostics", qos: .userInitiated)

    /// "Version 27.3 (Build 27D60)".
    static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// The state folder ParaAir last selected (MenuModel saves it under `selectedStateRoot`), else the default one.
    static var savedStateRoot: URL {
        if let value = UserDefaults.standard.string(forKey: "selectedStateRoot"), !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StreamDrive", isDirectory: true)
    }

    /// The bundled CLI, as the mount route finds it; nil in a build without one.
    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ParaAirCLI.app/Contents/MacOS/paraair")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    @MainActor static func copy(stateRoot: URL) async -> Bool {
        let version = AppVersionText.current.line
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            queue.async { continuation.resume(returning: collect(stateRoot: stateRoot, appVersion: version)) }
        }
        let board = NSPasteboard.general
        board.clearContents()
        let copied = board.setString(text, forType: .string)
        Logger(subsystem: "dev.streamdrive.app", category: "support").notice("diagnostics copied=\(copied)")
        return copied
    }

    static func collect(stateRoot: URL, appVersion: String) -> String {
        let root = stateRoot.standardizedFileURL
        let accounts = CloudAccountStore(root: root).list().accounts.filter { $0.state == .signedIn }.map(\.email)
        let profiles = (try? ProfileStore(root: root).list()) ?? []
        let profile = profiles.first
        let setup: SupportDiagnostics.Part
        var drive: (name: String, status: SupportDiagnostics.Part)?
        if let helper {
            setup = run(helper, ["setup-status", "--json"])
            drive = profile.map { ($0.name, run(helper, ["--state-dir", root.path, "status", $0.name, "--json"])) }
        } else {
            setup = .unavailable("This build has no paraair helper, so setup-status couldn’t run.")
            drive = profile.map { ($0.name, .unavailable("This build has no paraair helper, so status couldn’t run.")) }
        }
        return SupportDiagnostics.text(.init(appVersion: appVersion, clientHeader: "mac/" + ParaAirCloudConfiguration.clientVersion,
                                             system: system, createdAt: Date(), setupStatus: setup, drive: drive,
                                             logs: logLines(since: Date().addingTimeInterval(-30 * 60)), accountEmails: accounts,
                                             home: FileManager.default.homeDirectoryForCurrentUser.path,
                                             mountPoints: profiles.compactMap(\.mountPoint)))
    }

    /// Runs the helper with JSON output, within `timeout`, keeping at most `limit` bytes of it. Its stdout is read as it
    /// arrives by a dispatch source, so a long reply can't block the helper and no thread is left waiting on the pipe:
    /// once the helper exits, a process it left behind holding stdout gets a second, and then the pipe is closed.
    static func run(_ helper: URL, _ arguments: [String], timeout: TimeInterval = timeout, limit: Int = maxOutputBytes) -> SupportDiagnostics.Part {
        let command = "paraair " + arguments.joined(separator: " ")
        let process = Process(), pipe = Pipe(), output = Output(limit: limit)
        process.executableURL = helper
        process.arguments = arguments
        // setup-status describes this copy of ParaAir, wherever it runs from.
        process.environment = ProcessInfo.processInfo.environment.merging(["PARAAIR_APP_PATH": Bundle.main.bundlePath]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in output.wake.signal() }
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { output.read($0) }
        do { try process.run() } catch {
            output.stop(reader)
            return .unavailable("paraair \(arguments.first { !$0.hasPrefix("-") } ?? "") couldn’t start.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        while !output.ended, Date() < deadline {
            if exitedAt == nil, !process.isRunning { exitedAt = Date() }
            if let exitedAt, Date().timeIntervalSince(exitedAt) > 1 { break }
            _ = output.wake.wait(timeout: .now() + 0.05)
        }
        let ended = output.ended
        output.stop(reader)
        if process.isRunning {
            process.terminate()
            let killAt = Date().addingTimeInterval(2)
            while process.isRunning, Date() < killAt { _ = output.wake.wait(timeout: .now() + 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        if output.overLimit {
            return .unavailable("\(command) printed more than \(limit >> 20) MB, so it was left out.")
        }
        guard ended || exitedAt != nil else {
            return .unavailable("\(command) didn’t finish within \(Int(timeout)) \(Int(timeout) == 1 ? "second" : "seconds").")
        }
        let data = output.data
        let exit = process.isRunning ? "" : " (exit \(process.terminationStatus))"
        // A failing command prints its error as JSON too ({"error","exitCode","code"}); its code is kept, its message isn't.
        return data.isEmpty ? .unavailable("\(command) printed nothing\(exit).") : .json(data)
    }

    /// The helper's stdout as it arrives, up to `limit` bytes.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var bytes = Data()
        private var closed = false, atEnd = false, over = false
        /// Signalled at the end of the output, past the limit and when the helper exits.
        let wake = DispatchSemaphore(value: 0)

        init(limit: Int) { self.limit = limit }

        var data: Data { lock.withLock { bytes } }
        /// End of file, or past the limit.
        var ended: Bool { lock.withLock { atEnd } }
        var overLimit: Bool { lock.withLock { over } }

        /// From the readability handler: data is waiting, or the pipe is at its end.
        func read(_ handle: FileHandle) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            let chunk = handle.availableData
            if chunk.isEmpty || bytes.count + chunk.count > limit {
                over = !chunk.isEmpty; atEnd = true
                close(handle)
            } else {
                bytes.append(chunk)
            }
        }

        /// Stops reading and closes the pipe; nothing reads it afterwards.
        func stop(_ handle: FileHandle) { lock.withLock { close(handle) } }

        private func close(_ handle: FileHandle) {
            guard !closed else { return }
            closed = true
            handle.readabilityHandler = nil
            try? handle.close()
            wake.signal()
        }
    }

    /// This app's `dev.streamdrive` log lines since `since`, newest 200. Other processes' lines (the file system
    /// extension, the CLI) need `log show`, which reads the system store this app has no entitlement for.
    static func logLines(since: Date) -> SupportDiagnostics.Part {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: since),
                                               matching: NSPredicate(format: "subsystem BEGINSWITH %@", "dev.streamdrive"))
            let formatter = ISO8601DateFormatter()
            var lines: [String] = []
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(formatter.string(from: entry.date)) \(entry.category) \(level(entry.level)): \(entry.composedMessage)")
                if lines.count > 400 { lines.removeFirst(200) }
            }
            return .lines(Array(lines.suffix(200)))
        } catch {
            return .unavailable("This app’s log couldn’t be read here. Run: log show --last 30m --info --predicate 'subsystem BEGINSWITH \"dev.streamdrive\"'")
        }
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }
}

/// Get Help…, Copy Diagnostics and, outside the About window, About ParaAir, with a line saying what copying did.
struct SupportButtons: View {
    enum CopyState: Equatable { case idle, working, copied, failed }

    let actions: SupportActions
    var showsAbout = true
    var centered = false
    @State private var copy: CopyState = .idle

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            if centered {
                HStack(spacing: 10) { buttons }
            } else {
                AirFlow { buttons }
            }
            if let line = Self.line(copy) {
                Text(line).font(.caption).foregroundStyle(Air.quiet).multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button("Get Help…", action: actions.getHelp)
        Button("Copy Diagnostics") {
            copy = .working
            Task { @MainActor in copy = await actions.copyDiagnostics() ? .copied : .failed }
        }
        .disabled(copy == .working)
        if showsAbout { Button("About ParaAir", action: actions.showAbout) }
    }

    static func line(_ state: CopyState) -> String? {
        switch state {
        case .idle: return nil
        case .working: return "Collecting diagnostics…"
        case .copied: return "Diagnostics copied, without file names, keys or other people’s addresses. Paste them into your email to support."
        case .failed: return "Diagnostics couldn’t be copied."
        }
    }
}
