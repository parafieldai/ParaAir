import Foundation

/// When a follower of a drive's change feed connects its change stream (ParaAirCloudChangeStream) and when it pulls
/// the feed while the stream is up. Pure state on the caller's monotonic clock; the caller does the I/O.
///
/// While the stream is up, a pull is due when the stream has told of a cursor beyond the one the last pull reached (at
/// most once every `minimumGap`, so a burst of changes costs one pull a second, not one per change), or when it knew
/// no cursor, or `safety` after the last pull in case a notice was lost. While it is down, the caller polls on its own
/// schedule (FeedPollSchedule) and reconnects when `shouldConnect` says so: at once after an expired token, otherwise
/// after a wait that doubles from `shortestRetry` to `longestRetry` and starts again once a connection is up.
public struct FeedPushSchedule: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case down(retryAt: TimeInterval)
        case connecting
        case up
    }
    public let minimumGap: TimeInterval
    public let safety: TimeInterval
    public let shortestRetry: TimeInterval
    public let longestRetry: TimeInterval
    public private(set) var phase: Phase
    /// The cursor the last successful pull reached; nil before the first.
    public private(set) var reached: Int64?
    /// The newest cursor the stream told of.
    public private(set) var heard: Int64?
    /// The stream knew no cursor when it connected: pull once to be sure.
    public private(set) var unknown = false
    private var lastPull: TimeInterval
    private var retry: TimeInterval

    public init(minimumGap: TimeInterval = 1, safety: TimeInterval = 600, shortestRetry: TimeInterval = 2, longestRetry: TimeInterval = 300,
                now: TimeInterval) {
        precondition(minimumGap >= 0 && safety >= minimumGap && shortestRetry > 0 && longestRetry >= shortestRetry)
        self.minimumGap = minimumGap; self.safety = safety; self.shortestRetry = shortestRetry; self.longestRetry = longestRetry
        phase = .down(retryAt: now); lastPull = now; retry = shortestRetry
    }

    public var isUp: Bool { phase == .up }

    /// Whether to open a connection now.
    public func shouldConnect(now: TimeInterval) -> Bool {
        if case .down(let at) = phase { return now >= at }
        return false
    }
    public mutating func connecting() { phase = .connecting }

    /// The stream's message: `first` is the one it sends on connecting (then the stream counts as up).
    public mutating func heard(cursor: Int64?, first: Bool) {
        if first { phase = .up; retry = shortestRetry }
        if let cursor { heard = max(heard ?? cursor, cursor) } else if first { unknown = true }
    }

    /// The stream closed. `expired`: its token's time ran out, so reconnect at once. `jitter` (around 1) spreads the
    /// reconnects of many Macs after the service drops them all at once.
    public mutating func closed(expired: Bool, now: TimeInterval, jitter: Double = 1) {
        if expired { phase = .down(retryAt: now); return }
        phase = .down(retryAt: now + retry * jitter)
        retry = min(longestRetry, retry * 2)
    }

    /// Connect again soon, with the shortest wait (the Mac woke, the network came back).
    public mutating func reconnectSoon(now: TimeInterval) {
        retry = shortestRetry
        if case .down = phase { phase = .down(retryAt: now) }
    }

    /// While up: whether to pull now.
    public func pullDue(now: TimeInterval) -> Bool {
        guard phase == .up else { return false }
        return now >= lastPull + (behind ? minimumGap : safety)
    }

    /// While up, seconds until `pullDue` turns true if nothing else is heard; nil while not up.
    public func untilPull(now: TimeInterval) -> TimeInterval? {
        guard phase == .up else { return nil }
        return max(0, lastPull + (behind ? minimumGap : safety) - now)
    }

    /// A pull at `now` reached `cursor` (whether or not the stream was up).
    public mutating func pulled(reached cursor: Int64, now: TimeInterval) {
        reached = cursor; lastPull = now; unknown = false
    }

    /// The stream told of something the last pull didn't reach (or nothing was pulled yet, or it knew no cursor).
    public var behind: Bool {
        guard let reached else { return true }
        return unknown || (heard.map { $0 > reached } ?? false)
    }
}
