import Foundation
import Darwin
import os
import UserNotifications
import StreamDriveCore

/// Files on this Mac that haven't reached storage yet, grouped by why they are waiting.
struct UploadActivity: Equatable, Sendable {
    /// Waiting for the next upload attempt, with no error recorded yet.
    var waiting = 0
    /// The last attempt found the ParaAir Cloud plan full (EDQUOT).
    var blockedQuota = 0
    /// The last attempt needed a new sign-in (EACCES).
    var blockedAuth = 0
    /// The file changed elsewhere; the local copy is kept and never uploads by itself.
    var conflicts = 0
    /// Any other failure, retried with the next attempt.
    var failedOther = 0
    var pendingBytes: Int64 = 0

    init(waiting: Int = 0, blockedQuota: Int = 0, blockedAuth: Int = 0, conflicts: Int = 0, failedOther: Int = 0,
         pendingBytes: Int64 = 0) {
        self.waiting = waiting; self.blockedQuota = blockedQuota; self.blockedAuth = blockedAuth
        self.conflicts = conflicts; self.failedOther = failedOther; self.pendingBytes = pendingBytes
    }

    init(_ uploads: [UploadRecord]) {
        for upload in uploads {
            if upload.state == "conflict" { conflicts += 1 }
            else if upload.lastErrno == EDQUOT { blockedQuota += 1 }
            else if upload.lastErrno == EACCES { blockedAuth += 1 }
            else if upload.lastErrno == nil { waiting += 1 }
            else { failedOther += 1 }
            pendingBytes += upload.pendingBytes
        }
    }

    var total: Int { waiting + blockedQuota + blockedAuth + conflicts + failedOther }
}

/// Polls the selected drive's upload journal every 30 seconds. One `Engine` is kept per
/// state folder and profile. Only `uploads()` runs: it is a short local read under the
/// state lock, while `status()` walks the whole cache under the lock FSKit calls need.
/// No network or Keychain access happens here, and the work runs off the main actor.
@MainActor
final class DriveActivityMonitor: ObservableObject {
    @Published private(set) var activity: UploadActivity?

    private struct Target: Equatable { let stateRoot: URL; let profile: DriveProfile }
    /// Engine is not Sendable; each box is used by one poll at a time.
    private final class EngineBox: @unchecked Sendable {
        let engine: Engine
        let profile: DriveProfile
        init(engine: Engine, profile: DriveProfile) { self.engine = engine; self.profile = profile }
    }

    private let log = Logger(subsystem: "dev.streamdrive.app", category: "activity")
    private let interval: UInt64
    private let notify: Bool
    private var target: Target?
    private var engines: [String: EngineBox] = [:]
    private var loop: Task<Void, Never>?
    private var polling = false
    private var askedForNotifications = false

    /// `notify` is false in tests and snapshots: notifications need a bundled app.
    init(interval: TimeInterval = 30, notify: Bool = true) {
        self.interval = UInt64(interval * 1_000_000_000)
        self.notify = notify
    }

    /// Starts or retargets polling. `nil` stops it and clears the published state.
    func watch(stateRoot: URL, profile: DriveProfile?) {
        let next = profile.map { Target(stateRoot: stateRoot.standardizedFileURL, profile: $0) }
        guard next != target else { return }
        stop()
        guard let next else { return }
        target = next
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// An immediate poll, for example before confirming sign-out.
    func refreshNow() async -> UploadActivity? {
        await poll()
        return activity
    }

    func stop() {
        target = nil; activity = nil; engines = [:]
        loop?.cancel(); loop = nil
    }

    private func poll() async {
        guard let target, !polling else { return }
        polling = true; defer { polling = false }
        let key = target.stateRoot.path + "\0" + target.profile.name
        let existing = engines[key].flatMap { $0.profile == target.profile ? $0 : nil }
        let result: Result<(UploadActivity, EngineBox), Error> = await Task.detached(priority: .utility) {
            do {
                let box = try existing ?? EngineBox(engine: Engine.open(profile: target.profile, stateRoot: target.stateRoot),
                                                    profile: target.profile)
                return .success((UploadActivity(try box.engine.uploads()), box))
            } catch { return .failure(error) }
        }.value
        guard self.target == target else { return }
        switch result {
        case .success(let (next, box)):
            engines = [key: box]
            let previous = activity
            activity = next
            if previous != next {
                log.notice("activity waiting=\(next.waiting) quota=\(next.blockedQuota) auth=\(next.blockedAuth) conflicts=\(next.conflicts) other=\(next.failedOther) bytes=\(next.pendingBytes)")
            }
            if let previous { announceTransitions(from: previous, to: next, cloud: target.profile.backend == .paraairCloud) }
        case .failure(let error):
            engines[key] = nil
            let code = (error as? DriveError)?.code ?? -1
            log.error("activity poll failed errno=\(code)")
        }
    }

    /// Posts one notification for each kind of problem that newly appeared. The first
    /// reading after launch is a baseline, so restarting ParaAir doesn't repeat them.
    private func announceTransitions(from previous: UploadActivity, to next: UploadActivity, cloud: Bool) {
        var messages: [String] = []
        if cloud, previous.blockedQuota == 0, next.blockedQuota > 0 { messages.append(UploadNotices.quota(next.blockedQuota)) }
        if cloud, previous.blockedAuth == 0, next.blockedAuth > 0 { messages.append(UploadNotices.signIn(next.blockedAuth)) }
        if previous.conflicts == 0, next.conflicts > 0 { messages.append(UploadNotices.conflicts(next.conflicts)) }
        guard notify, !messages.isEmpty, Self.canPostNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            for message in messages {
                let content = UNMutableNotificationContent()
                content.title = "ParaAir"
                content.body = message
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
        if askedForNotifications { post(); return }
        askedForNotifications = true
        center.requestAuthorization(options: [.alert]) { granted, _ in if granted { post() } }
    }

    /// UNUserNotificationCenter requires a bundled app; a bare test binary would crash.
    private static var canPostNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}
