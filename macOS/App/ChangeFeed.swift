import Foundation
import os
import Darwin
import StreamDriveCore

/// Brings other devices' changes to Finder and to apps watching a drive with FSEvents. FSKit has no change
/// notification of its own, so for each mounted ParaAir Cloud drive this polls the drive's change feed
/// (Engine.followChanges, which drops this Mac's cached metadata for whatever changed) and then creates and removes
/// the `.paraair-refresh` marker through the mount in every folder the feed names: the kernel reports each of those
/// folders as changed.
///
/// Each drive keeps its own FeedPollSchedule: every 3 s while its changes arrive (anyone's, this Mac's own uploads
/// included) and for a minute after the last one, then backing off to once a minute while nothing changes, so an idle
/// drive costs the service about one request a minute however busy another drive is. A drive that has just been
/// mounted (seen in the mount table, checked every second without the network) polls at once and fast again. A failing
/// drive waits longer, up to a minute, on its own.
@MainActor
final class ChangeFeedMonitor {
    private struct Drive: Equatable { let stateRoot: URL; let profile: DriveProfile; var key: String { stateRoot.path + "\0" + profile.name } }
    /// Engine is not Sendable; each box is used by one poll at a time.
    private final class EngineBox: @unchecked Sendable {
        let engine: Engine
        let profile: DriveProfile
        init(engine: Engine, profile: DriveProfile) { self.engine = engine; self.profile = profile }
    }
    /// One drive's polling: its schedule, when it's next due (system uptime), its failure backoff, and whether it was
    /// mounted at the last tick.
    private struct DriveState {
        var schedule: FeedPollSchedule
        var due: TimeInterval
        var failureWait: TimeInterval
        var mounted = false
    }

    private let log = Logger(subsystem: "dev.streamdrive.app", category: "changes")
    private let interval: TimeInterval
    private var target: [Drive]?
    private var engines: [String: EngineBox] = [:]
    private var states: [String: DriveState] = [:]
    private var loop: Task<Void, Never>?

    init(interval: TimeInterval = 3) { self.interval = interval }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

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
                guard await self?.tick() == true else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil; target = nil; engines = [:]; states = [:]
    }

    /// Once a second: notes which drives are mounted (a newly mounted one is due at once and polls fast), then polls
    /// the mounted drives whose time has come. False to stop.
    private func tick() async -> Bool {
        guard let target else { return false }
        let mounted = Set(ParaAirVolumes.mountedPaths())
        for drive in target {
            let key = drive.key, profile = drive.profile, root = drive.stateRoot
            guard let mount = profile.mountPoint, mounted.contains(mount) else {
                engines[key] = nil; states[key]?.mounted = false
                continue
            }
            let start = Self.now
            var state = states[key] ?? DriveState(schedule: FeedPollSchedule(fast: interval, now: start), due: start, failureWait: interval)
            if !state.mounted { state.schedule.wake(now: start); state.due = start; state.mounted = true }
            guard start >= state.due else { states[key] = state; continue }
            let existing = engines[key].flatMap { $0.profile == profile ? $0 : nil }
            let result: Result<(EngineBox, Int, Int), Error> = await Task.detached(priority: .utility) {
                do {
                    let box = try existing ?? EngineBox(engine: Engine.open(profile: profile, stateRoot: root), profile: profile)
                    let batch = try box.engine.followChanges(consumer: "app")
                    let folders = batch?.folders ?? []
                    // A folder deleted or moved elsewhere can't be dropped from the kernel's caches like a file. Ask the
                    // drive to forget it and remove it through the mount: the extension answers without touching
                    // storage, and only when storage no longer has it, so nothing is ever deleted here.
                    if Housekeeping.isParaAirMount(mount) {
                        for path in Engine.foldersGone(batch?.changes ?? []) {
                            guard (try? box.engine.requestPurge(path)) != nil else { continue }
                            _ = Darwin.rmdir(mount + path)
                            try? box.engine.clearPurgeRequest(path)
                        }
                    }
                    for folder in folders { Housekeeping.touchRefreshMarker(in: folder, mountPoint: mount) }
                    return .success((box, folders.count, (batch?.changes.count ?? 0) + (batch?.reset == true ? 1 : 0)))
                } catch { return .failure(error) }
            }.value
            guard self.target == target else { return true }
            let done = Self.now
            switch result {
            case .success(let (box, folders, changes)):
                engines[key] = box
                state.failureWait = interval
                state.due = done + state.schedule.next(changes: changes, now: done)
                if folders > 0 { log.notice("changes from other devices refreshed folders=\(folders)") }
            case .failure(let error):
                engines[key] = nil
                state.failureWait = min(60, max(interval, state.failureWait * 2))
                state.due = done + state.failureWait
                log.error("change feed failed errno=\((error as? DriveError)?.code ?? -1)")
            }
            states[key] = state
        }
        return true
    }
}
