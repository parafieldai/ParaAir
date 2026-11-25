import XCTest
import Darwin
@testable import StreamDriveCore

/// Account deletion on the client (cloud item P4, `account-deletion-api.md`): the status the app shows, the typed
/// confirmation, cancelling, and a service that predates the routes. The fake service answers the routes from
/// fixtures shaped like the service's draft.
final class ParaAirCloudAccountDeletionTests: XCTestCase {
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount()
    }

    private func api() throws -> ParaAirCloudAPI {
        let tokens = fake.issueTokens(for: account)
        let http = try ParaAirCloudHTTP(baseURL: fake.issuer, policy: .init(allowsLoopbackHTTP: false), configuration: fake.configuration)
        let api = ParaAirCloudAPI(http: http, tokens: StaticAccessToken(tokens.accessToken))
        api.retryDelays = [0.01, 0.01]; api.sleep = { _ in }
        return api
    }

    private static let none = Data("""
    {"deletion":null,"graceDays":7,
     "workspaces":[{"id":"ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC","name":"Personal","kind":"personal","role":"owner","action":"delete"},
                   {"id":"ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YD","name":"Parafield","kind":"team","role":"admin","action":"leave"}],
     "blockers":[]}
    """.utf8)
    private static let scheduled = Data("""
    {"deletion":{"state":"scheduled","requestedAt":"2026-11-25T08:00:00.000Z","deleteAfter":"2026-12-02T08:00:00.000Z","requestedBy":"user"},
     "graceDays":7,"workspaces":[{"id":"ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC","name":"Personal","kind":"personal","role":"owner","action":"delete"}],
     "blockers":[]}
    """.utf8)
    private static let json = ["content-type": "application/json"]

    func testAServiceWithoutAccountDeletionReadsAsNotOffered() throws {
        XCTAssertNil(try api().accountDeletion(), "an older service answers 404 not_found")
        XCTAssertThrowsError(try api().requestAccountDeletion(confirmEmail: account.email)) {
            XCTAssertEqual(($0 as? DriveError)?.message.hasPrefix("This ParaAir Cloud service can’t delete accounts yet"), true, "\($0)")
        }
    }

    func testStatusDecodesTheServiceShape() throws {
        fake.injectRaw(route: "GET /v1/account/deletion", status: 200, body: Self.none, headers: Self.json)
        let status = try XCTUnwrap(try api().accountDeletion())
        XCTAssertNil(status.deletion)
        XCTAssertEqual(status.graceDays, 7)
        XCTAssertEqual(status.workspaces.map(\.action), ["delete", "leave"])
        XCTAssertTrue(status.blockers.isEmpty)

        fake.injectRaw(route: "GET /v1/account/deletion", status: 200, body: Self.scheduled, headers: Self.json)
        let pending = try XCTUnwrap(try api().accountDeletion()?.deletion)
        XCTAssertTrue(pending.isScheduled)
        XCTAssertEqual(pending.deleteAfter, ParaAirCloudJSON.parseDate("2026-12-02T08:00:00Z"))

        let bad = Data(String(decoding: Self.none, as: UTF8.self).replacingOccurrences(of: "ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YD", with: "nope").utf8)
        fake.injectRaw(route: "GET /v1/account/deletion", status: 200, body: bad, headers: Self.json)
        XCTAssertThrowsError(try api().accountDeletion()) {
            XCTAssertEqual(($0 as? DriveError)?.message, "ParaAir Cloud returned a malformed response")
        }
    }

    func testRequestSendsTheTypedAddressOnceWithAnIdempotencyKey() throws {
        fake.injectRaw(route: "POST /v1/account/deletion", status: 202, body: Self.scheduled, headers: Self.json)
        let result = try api().requestAccountDeletion(confirmEmail: "Person@Example.test")
        XCTAssertEqual(result.deletion?.state, "scheduled")
        let sent = try XCTUnwrap(fake.requests("POST /v1/account/deletion").last)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.body) as? [String: String], ["confirmEmail": "Person@Example.test"])
        XCTAssertNotNil(sent.headers["idempotency-key"])

        fake.injectRaw(route: "DELETE /v1/account/deletion", status: 200, body: Self.none, headers: Self.json)
        XCTAssertNil(try api().cancelAccountDeletion().deletion)
        XCTAssertNotNil(fake.requests("DELETE /v1/account/deletion").last?.headers["idempotency-key"])
    }

    func testRefusalsSayWhatToDo() throws {
        func expect(_ route: String, _ status: Int, _ code: String, _ message: String, _ call: (ParaAirCloudAPI) throws -> Void,
                    line: UInt = #line) throws {
            fake.inject(route: route, status: status, code: code)
            let api = try self.api()
            XCTAssertThrowsError(try call(api), line: line) {
                XCTAssertEqual(($0 as? DriveError)?.message.hasPrefix(message), true, "\($0)", line: line)
            }
        }
        try expect("POST /v1/account/deletion", 409, "busy", "Your account can’t be deleted yet. Something needs to change first") {
            _ = try $0.requestAccountDeletion(confirmEmail: account.email)
        }
        try expect("POST /v1/account/deletion", 400, "invalid_request", "That isn’t this account’s email address") {
            _ = try $0.requestAccountDeletion(confirmEmail: "someone@else.test")
        }
        try expect("DELETE /v1/account/deletion", 409, "busy", "Your account is already being deleted, so it’s too late to cancel") {
            _ = try $0.cancelAccountDeletion()
        }
        try expect("GET /v1/account/deletion", 401, "unauthorized", "") { _ = try $0.accountDeletion() }
    }
}
