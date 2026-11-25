import Foundation
import StreamDriveCore

/// `changes --follow --push`: keeps the drive's change stream connected (reconnecting with FeedPushSchedule's waits)
/// and blocks until the next pull is due: the stream told of a cursor beyond the one reached, or ten minutes passed
/// (a lost notice), or, while the stream is down, the poll interval passed.
final class ChangeNotices: @unchecked Sendable {
    typealias Open = (@escaping @Sendable (ParaAirCloudChangeStream.Event) -> Void) throws -> ParaAirCloudChangeStream?
    private let condition = NSCondition()
    private let open: Open
    private var push: FeedPushSchedule
    private var stream: ParaAirCloudChangeStream?
    private var generation = 0
    /// The storage can't push (nil stream): poll only.
    private var unsupported = false
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(open: @escaping Open) {
        self.open = open
        push = FeedPushSchedule(now: Self.now)
    }

    /// Called right after a pull that reached `reached`: waits until the next one is due.
    func wait(after reached: Int64, poll: TimeInterval) {
        condition.lock(); defer { condition.unlock() }
        let start = Self.now
        push.pulled(reached: reached, now: start)
        while true {
            let now = Self.now
            if !unsupported, push.shouldConnect(now: now) { connectLocked(now: now) }
            if push.isUp {
                if push.pullDue(now: now) { return }
            } else if now >= start + poll {
                return
            }
            var wake = push.isUp ? now + (push.untilPull(now: now) ?? poll) : start + poll
            if !unsupported, case .down(let at) = push.phase { wake = min(wake, at) }
            _ = condition.wait(until: Date().addingTimeInterval(max(0.01, wake - now)))
        }
    }

    func close() {
        condition.lock()
        generation += 1
        let current = stream; stream = nil
        condition.unlock()
        current?.close()
    }

    private func connectLocked(now: TimeInterval) {
        generation += 1
        let mine = generation
        push.connecting()
        let made: ParaAirCloudChangeStream?
        do { made = try open { [weak self] event in self?.heard(event, generation: mine) } }
        catch { push.closed(expired: false, now: now, jitter: .random(in: 0.8...1.2)); return }
        guard let made else { unsupported = true; push.closed(expired: false, now: now); return }
        stream = made
        made.start()
    }

    private func heard(_ event: ParaAirCloudChangeStream.Event, generation: Int) {
        condition.lock(); defer { condition.unlock() }
        guard generation == self.generation else { return }
        switch event {
        case .cursor(let cursor, let first):
            push.heard(cursor: cursor, first: first)
        case .closed(let closure):
            stream = nil
            push.closed(expired: closure == .expired, now: Self.now, jitter: .random(in: 0.8...1.2))
        }
        condition.broadcast()
    }
}
