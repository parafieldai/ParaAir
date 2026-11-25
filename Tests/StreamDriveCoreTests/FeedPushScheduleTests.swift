import XCTest
@testable import StreamDriveCore

final class FeedPushScheduleTests: XCTestCase {
    func testConnectsAtOnceThenPullsOnlyWhenTheStreamToldOfSomethingNew() {
        var push = FeedPushSchedule(now: 0)
        XCTAssertTrue(push.shouldConnect(now: 0))
        push.pulled(reached: 10, now: 0)
        push.connecting()
        XCTAssertFalse(push.shouldConnect(now: 1))
        XCTAssertFalse(push.pullDue(now: 1), "not up yet: the caller's poll schedule applies")
        push.heard(cursor: 10, first: true)
        XCTAssertTrue(push.isUp)
        XCTAssertFalse(push.pullDue(now: 5), "the newest cursor is the one already reached")
        push.heard(cursor: 12, first: false)
        XCTAssertTrue(push.pullDue(now: 5))
        push.pulled(reached: 12, now: 5)
        XCTAssertFalse(push.pullDue(now: 6))
        // A stale notice (already pulled past) doesn't pull.
        push.heard(cursor: 11, first: false)
        XCTAssertFalse(push.pullDue(now: 7))
    }

    func testABurstPullsAtMostOncePerGap() {
        var push = FeedPushSchedule(minimumGap: 1, now: 0)
        push.connecting(); push.heard(cursor: nil, first: true)
        push.pulled(reached: 1, now: 0)
        push.heard(cursor: 2, first: false)
        XCTAssertFalse(push.pullDue(now: 0.5))
        XCTAssertEqual(push.untilPull(now: 0.5), 0.5)
        XCTAssertTrue(push.pullDue(now: 1))
        push.pulled(reached: 2, now: 1)
        for cursor in Int64(3)...20 { push.heard(cursor: cursor, first: false) }
        XCTAssertFalse(push.pullDue(now: 1.9))
        XCTAssertTrue(push.pullDue(now: 2))
        push.pulled(reached: 20, now: 2)
        XCTAssertFalse(push.behind)
    }

    func testAnUnknownCursorOnConnectingPullsOnce() {
        var push = FeedPushSchedule(now: 0)
        push.pulled(reached: 5, now: 0)
        push.connecting(); push.heard(cursor: nil, first: true)
        XCTAssertTrue(push.behind)
        XCTAssertTrue(push.pullDue(now: 1))
        push.pulled(reached: 5, now: 1)
        XCTAssertFalse(push.behind)
        XCTAssertFalse(push.pullDue(now: 2))
    }

    func testPullsEverySafetyIntervalWhileQuiet() {
        var push = FeedPushSchedule(safety: 600, now: 0)
        push.pulled(reached: 3, now: 0)
        push.connecting(); push.heard(cursor: 3, first: true)
        XCTAssertFalse(push.pullDue(now: 599))
        XCTAssertEqual(push.untilPull(now: 599), 1)
        XCTAssertTrue(push.pullDue(now: 600))
    }

    func testReconnectWaitsDoubleUntilUpAndExpiryReconnectsAtOnce() {
        var push = FeedPushSchedule(shortestRetry: 2, longestRetry: 8, now: 0)
        push.connecting(); push.closed(expired: false, now: 0)
        XCTAssertFalse(push.shouldConnect(now: 1.9)); XCTAssertTrue(push.shouldConnect(now: 2))
        push.connecting(); push.closed(expired: false, now: 2)
        XCTAssertFalse(push.shouldConnect(now: 5.9)); XCTAssertTrue(push.shouldConnect(now: 6))
        push.connecting(); push.closed(expired: false, now: 6)
        push.connecting(); push.closed(expired: false, now: 14)
        XCTAssertFalse(push.shouldConnect(now: 21.9)); XCTAssertTrue(push.shouldConnect(now: 22), "capped at longestRetry")
        push.connecting(); push.heard(cursor: 1, first: true)
        push.closed(expired: true, now: 30)
        XCTAssertTrue(push.shouldConnect(now: 30), "an expired token reconnects at once")
        push.connecting(); push.closed(expired: false, now: 30)
        XCTAssertTrue(push.shouldConnect(now: 32), "being up reset the wait")
        XCTAssertFalse(push.pullDue(now: 40), "down: the caller polls")
        XCTAssertNil(push.untilPull(now: 40))
    }

    func testReconnectSoonAfterWake() {
        var push = FeedPushSchedule(shortestRetry: 2, longestRetry: 300, now: 0)
        for t in stride(from: 0.0, to: 100, by: 10) { push.connecting(); push.closed(expired: false, now: t) }
        XCTAssertFalse(push.shouldConnect(now: 100))
        push.reconnectSoon(now: 100)
        XCTAssertTrue(push.shouldConnect(now: 100))
        push.connecting(); push.closed(expired: false, now: 100)
        XCTAssertTrue(push.shouldConnect(now: 102))
    }

    func testStreamMessages() {
        XCTAssertEqual(ParaAirCloudChangeStream.cursor(in: #"{"cursor":42}"#), .some(42))
        XCTAssertEqual(ParaAirCloudChangeStream.cursor(in: #"{"cursor":null}"#), .some(nil))
        XCTAssertEqual(ParaAirCloudChangeStream.cursor(in: #"{"cursor":-1}"#), .some(nil), "an invalid cursor only makes the follower pull")
        XCTAssertEqual(ParaAirCloudChangeStream.cursor(in: #"{"cursor":1.5}"#), .some(nil))
        XCTAssertEqual(ParaAirCloudChangeStream.cursor(in: #"{"cursor":true}"#), .some(nil))
        XCTAssertNil(ParaAirCloudChangeStream.cursor(in: "pong"))
        XCTAssertNil(ParaAirCloudChangeStream.cursor(in: #"{"other":1}"#))
        XCTAssertNil(ParaAirCloudChangeStream.cursor(in: String(repeating: " ", count: 300) + #"{"cursor":1}"#))
    }
}
