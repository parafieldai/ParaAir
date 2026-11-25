import Foundation
import AppKit
import os
import Darwin
import StreamDriveCore

/// Brings other devices' changes to Finder and to apps watching a drive with FSEvents. FSKit has no change
/// notification of its own, so for each mounted ParaAir Cloud drive this reads the drive's change feed
/// (Engine.followChanges, which drops this Mac's cached metadata for whatever changed) and then creates and removes
/// the `.paraair-refresh` marker through the mount in every folder the feed names: the kernel reports each of those
/// folders as changed.
///
/// When to read the feed: each mounted drive holds its change stream open (ParaAirCloudChangeStream, a WebSocket that
/// ParaAir Cloud uses to say a change committed). While it is up (FeedPushSchedule) the feed is read when the stream
/// tells of a cursor newer than the one reached, at most once a second, and every ten minutes in case a notice got
/// lost, so an idle drive costs the service a connection now and then instead of a request a minute. While it is down
/// (before it first connects, offline, during a service deploy) the drive falls back to FeedPollSchedule: every 3 s
/// while changes arrive and for a minute after, then backing off to once a minute; it reconnects after 2 s, doubling
/// up to five minutes. A drive that has just been mounted (seen in the mount table, checked every second without the
/// network) reads its feed at once. Streams close before the Mac sleeps and reconnect when it wakes.
@MainActor
final class ChangeFeedMonitor {
    private struct Drive: Equatable { let stateRoot: URL; let profile: DriveProfile; var key: String { stateRoot.path + "\0" + profile.name } }
    /// Engine is not Sendable; each box is used by one task at a time (the monitor awaits each before the next).
    private final class EngineBox: @unchecked Sendable {
        let engine: Engine
        let profile: DriveProfile
        init(engine: Engine, profile: DriveProfile) { self.engine = engine; self.profile = profile }
    }
    /// One drive: its stream and when to read its feed (system uptime).
    private struct DriveState {
        var schedule: FeedPollSchedule
        var push: FeedPushSchedule
        /// While the stream is down: when the next poll is due.
        var due: TimeInterval
        /// After a failed read: no read before this, stream or not.
        var failureUntil: TimeInterval = 0
        var failureWait: TimeInterval
        var mounted = false
        var stream: ParaAirCloudChangeStream?
        /// Which stream `stream` is; events from earlier ones are ignored.
        var streamID = 0
        var streamProfile: DriveProfile?
    }

    private let log = Logger(subsystem: "dev.streamdrive.app", category: "changes")
    private let interval: TimeInterval
    private var target: [Drive]?
    private var engines: [String: EngineBox] = [:]
    private var states: [String: DriveState] = [:]
    /// Stream events since the last tick, applied by the tick (which keeps a drive's state in a local across awaits).
    private var heard: [String: [(id: Int, event: ParaAirCloudChangeStream.Event)]] = [:]
    private var woke = false
    private var nextStreamID = 0
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

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
        observeSleep()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.tick() == true else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil; target = nil; engines = [:]
        for state in states.values { state.stream?.close() }
        states = [:]; heard = [:]
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    private func observeSleep() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke = true }
        })
    }

    /// A socket left open over sleep is dead on waking; close them now, and reconnect on waking.
    private func sleeping() {
        for state in states.values { state.stream?.close() }
    }

    private func streamEvent(_ event: ParaAirCloudChangeStream.Event, key: String, id: Int) {
        heard[key, default: []].append((id, event))
    }

    /// Applies the stream events heard since the last call, and a wake.
    private func catchUp(_ state: inout DriveState, key: String, now: TimeInterval) {
        if woke { state.push.reconnectSoon(now: now) }
        for (id, event) in heard.removeValue(forKey: key) ?? [] where id == state.streamID {
            switch event {
            case .cursor(let cursor, let first):
                if first { log.notice("change stream up") }
                state.push.heard(cursor: cursor, first: first)
            case .closed(let closure):
                state.stream = nil
                state.push.closed(expired: closure == .expired, now: now, jitter: .random(in: 0.8...1.2))
                // Anything missed while it went down shows within a poll.
                state.due = min(state.due, now + interval)
                if closure != .expired, closure != .closedByClient { log.notice("change stream closed: \(String(describing: closure), privacy: .public)") }
            }
        }
    }

    private func closeStream(_ state: inout DriveState) {
        state.stream?.close()
        state.stream = nil; state.streamID = 0; state.streamProfile = nil
    }

    /// Once a second: notes which drives are mounted (a newly mounted one is due at once), keeps each mounted drive's
    /// stream connected, then reads the feeds whose time has come. False to stop.
    private func tick() async -> Bool {
        guard let target else { return false }
        let mounted = Set(ParaAirVolumes.mountedPaths())
        for drive in target {
            let key = drive.key, profile = drive.profile, root = drive.stateRoot
            guard let mount = profile.mountPoint, mounted.contains(mount) else {
                engines[key] = nil
                if var state = states[key] {
                    closeStream(&state); heard[key] = nil
                    state.mounted = false; state.push = FeedPushSchedule(now: Self.now)
                    states[key] = state
                }
                continue
            }
            let start = Self.now
            var state = states[key] ?? DriveState(schedule: FeedPollSchedule(fast: interval, now: start), push: FeedPushSchedule(now: start),
                                                  due: start, failureWait: interval)
            if !state.mounted { state.schedule.wake(now: start); state.due = start; state.mounted = true }
            catchUp(&state, key: key, now: start)
            if state.stream != nil, state.streamProfile != profile { closeStream(&state); state.push = FeedPushSchedule(now: start) }

            // The stream, once the drive's engine is open (after its first read of the feed).
            if state.stream == nil, state.push.shouldConnect(now: start), let box = engines[key], box.profile == profile {
                nextStreamID += 1
                let id = nextStreamID
                state.streamID = id; state.streamProfile = profile
                state.push.connecting()
                let sink: @Sendable (ParaAirCloudChangeStream.Event) -> Void = { [weak self] event in
                    Task { @MainActor in self?.streamEvent(event, key: key, id: id) }
                }
                let made = await Task.detached(priority: .utility) { try? box.engine.changeStream(sink) }.value
                guard self.target == target else { made?.close(); return true }
                if let made {
                    state.stream = made
                    made.start()
                } else {
                    state.push.closed(expired: false, now: Self.now)
                }
            }

            let pull = state.push.isUp ? state.push.pullDue(now: start) && start >= state.failureUntil : start >= state.due
            guard pull else { states[key] = state; continue }
            let existing = engines[key].flatMap { $0.profile == profile ? $0 : nil }
            let result: Result<(EngineBox, Int, Int, Int64), Error> = await Task.detached(priority: .utility) {
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
                    return .success((box, folders.count, (batch?.changes.count ?? 0) + (batch?.reset == true ? 1 : 0), batch?.cursor ?? 0))
                } catch { return .failure(error) }
            }.value
            guard self.target == target else { return true }
            let done = Self.now
            catchUp(&state, key: key, now: done)
            switch result {
            case .success(let (box, folders, changes, cursor)):
                engines[key] = box
                state.failureWait = interval; state.failureUntil = 0
                state.push.pulled(reached: cursor, now: done)
                state.due = done + state.schedule.next(changes: changes, now: done)
                if folders > 0 { log.notice("changes from other devices refreshed folders=\(folders)") }
            case .failure(let error):
                engines[key] = nil
                state.failureWait = min(60, max(interval, state.failureWait * 2))
                state.failureUntil = done + state.failureWait
                state.due = state.failureUntil
                log.error("change feed failed errno=\((error as? DriveError)?.code ?? -1)")
            }
            states[key] = state
        }
        woke = false
        return true
    }
}
