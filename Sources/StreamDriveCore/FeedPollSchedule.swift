import Foundation

/// How long to wait between polls of a drive's change feed. Polls come every `fast` seconds while changes keep
/// arriving (anyone's, this Mac's own uploads included) and for `fastFor` seconds after the last one. Then, while
/// nothing changes, the wait doubles up to `slowest`. An idle Mac costs the service about one request a minute per
/// drive instead of twenty; the first change after a quiet spell shows within `slowest` seconds, and everything after
/// it within `fast` seconds again.
public struct FeedPollSchedule: Sendable, Equatable {
    public let fast: TimeInterval
    public let slowest: TimeInterval
    public let fastFor: TimeInterval
    /// When a change was last seen (or the schedule was woken), in the caller's monotonic seconds.
    public private(set) var lastActivity: TimeInterval
    /// The wait chosen last.
    public private(set) var current: TimeInterval

    public init(fast: TimeInterval = 3, slowest: TimeInterval = 60, fastFor: TimeInterval = 60, now: TimeInterval) {
        precondition(fast > 0 && slowest >= fast && fastFor >= 0)
        self.fast = fast; self.slowest = slowest; self.fastFor = fastFor
        lastActivity = now; current = fast
    }

    /// The wait after a successful poll at `now` that found `changes` changes.
    public mutating func next(changes: Int, now: TimeInterval) -> TimeInterval {
        if changes > 0 { lastActivity = now }
        current = now - lastActivity < fastFor ? fast : min(slowest, current * 2)
        return current
    }

    /// Something suggests changes are coming (the app started, a drive was mounted): poll fast again.
    public mutating func wake(now: TimeInterval) {
        lastActivity = now; current = fast
    }
}
