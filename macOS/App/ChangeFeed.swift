import Foundation
import os
import StreamDriveCore

/// Brings other devices' changes to Finder and to apps watching a drive with FSEvents. FSKit has no change
/// notification of its own, so for each mounted ParaAir Cloud drive this polls the drive's change feed
/// (Engine.followChanges, which drops this Mac's cached metadata for whatever changed) and then creates and removes
/// the `.paraair-refresh` marker through the mount in every folder the feed names: the kernel reports each of those
/// folders as changed. Every 3 s while a drive is mounted; offline or failing, waiting longer, up to a minute.
@MainActor
final class ChangeFeedMonitor {
    private struct Drive: Equatable { let stateRoot: URL; let profile: DriveProfile; var key: String { stateRoot.path + "\0" + profile.name } }
    /// Engine is not Sendable; each box is used by one poll at a time.
    private final class EngineBox: @unchecked Sendable {
        let engine: Engine
        let profile: DriveProfile
        init(engine: Engine, profile: DriveProfile) { self.engine = engine; self.profile = profile }
    }

    private let log = Logger(subsystem: "dev.streamdrive.app", category: "changes")
    private let interval: TimeInterval
    private var target: [Drive]?
    private var engines: [String: EngineBox] = [:]
    private var loop: Task<Void, Never>?
    private var wait: TimeInterval

    init(interval: TimeInterval = 3) { self.interval = interval; wait = interval }

    /// Follows the ParaAir Cloud drives among `drives` (each with its state folder) while they are mounted; none stops it.
    func watch(_ drives: [(stateRoot: URL, profile: DriveProfile)]) {
        let cloud = drives.filter { $0.profile.backend == .paraairCloud }.map { Drive(stateRoot: $0.stateRoot.standardizedFileURL, profile: $0.profile) }
        let next = cloud.isEmpty ? nil : cloud
        guard next != target else { return }
        stop()
        guard next != nil else { return }
        target = next
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = await self?.poll() else { return }
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil; target = nil; engines = [:]; wait = interval
    }

    /// One pass over the mounted drives; returns how long to wait before the next, or nil to stop.
    private func poll() async -> TimeInterval? {
        guard let target else { return nil }
        let mounted = Set(ParaAirVolumes.mountedPaths())
        var failed = false
        for drive in target {
            let profile = drive.profile, root = drive.stateRoot
            guard let mount = profile.mountPoint, mounted.contains(mount) else { engines[drive.key] = nil; continue }
            let existing = engines[drive.key].flatMap { $0.profile == profile ? $0 : nil }
            let result: Result<(EngineBox, Int), Error> = await Task.detached(priority: .utility) {
                do {
                    let box = try existing ?? EngineBox(engine: Engine.open(profile: profile, stateRoot: root), profile: profile)
                    let folders = try box.engine.followChanges(consumer: "app")?.folders ?? []
                    for folder in folders { Housekeeping.touchRefreshMarker(in: folder, mountPoint: mount) }
                    return .success((box, folders.count))
                } catch { return .failure(error) }
            }.value
            guard self.target == target else { return interval }
            switch result {
            case .success(let (box, folders)):
                engines[drive.key] = box
                if folders > 0 { log.notice("changes from other devices refreshed folders=\(folders)") }
            case .failure(let error):
                engines[drive.key] = nil; failed = true
                log.error("change feed failed errno=\((error as? DriveError)?.code ?? -1)")
            }
        }
        wait = failed ? min(60, max(interval, wait * 2)) : interval
        return wait
    }
}
