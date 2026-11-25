import XCTest
@testable import StreamDriveCore

final class FeedPollScheduleTests: XCTestCase {
    /// Runs the schedule with no changes from `start` until `end` seconds, returning each wait.
    private func idle(_ schedule: inout FeedPollSchedule, from start: TimeInterval, until end: TimeInterval) -> [TimeInterval] {
        var now = start, waits: [TimeInterval] = []
        while now < end { let wait = schedule.next(changes: 0, now: now); waits.append(wait); now += wait }
        return waits
    }

    func testFastWhileChangesArriveThenBacksOffToTheSlowestWait() {
        var schedule = FeedPollSchedule(now: 0)
        XCTAssertEqual(schedule.next(changes: 2, now: 0), 3)
        XCTAssertEqual(schedule.next(changes: 1, now: 3), 3)
        let waits = idle(&schedule, from: 6, until: 600)
        XCTAssertEqual(Array(waits.prefix(19)), Array(repeating: 3, count: 19), "fast for 60 s after the last change")
        XCTAssertEqual(Array(waits.dropFirst(19).prefix(6)), [6, 12, 24, 48, 60, 60], "then doubling up to a minute")
        XCTAssertEqual(waits.last, 60)
    }

    func testAnIdleHourCostsAboutAMinuteOfPolls() {
        var schedule = FeedPollSchedule(now: 0)
        let polls = idle(&schedule, from: 0, until: 3600).count
        XCTAssertLessThan(polls, 90, "about one poll a minute once quiet, against 1,200 at a steady 3 s")
    }

    func testAChangeAfterAQuietSpellSnapsBackToFast() {
        var schedule = FeedPollSchedule(now: 0)
        _ = idle(&schedule, from: 0, until: 600)
        XCTAssertEqual(schedule.current, 60)
        XCTAssertEqual(schedule.next(changes: 1, now: 660), 3)
        XCTAssertEqual(schedule.next(changes: 0, now: 663), 3, "and stays fast for the next minute")
    }

    func testWakePollsFastAgain() {
        var schedule = FeedPollSchedule(now: 0)
        _ = idle(&schedule, from: 0, until: 600)
        schedule.wake(now: 700)
        XCTAssertEqual(schedule.current, 3)
        XCTAssertEqual(schedule.next(changes: 0, now: 703), 3)
    }

    func testCustomBounds() {
        var schedule = FeedPollSchedule(fast: 1, slowest: 4, fastFor: 0, now: 0)
        XCTAssertEqual(idle(&schedule, from: 0, until: 20).prefix(4), [2, 4, 4, 4])
    }
}
