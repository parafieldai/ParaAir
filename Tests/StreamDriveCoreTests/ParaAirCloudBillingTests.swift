import XCTest
import Darwin
@testable import StreamDriveCore

/// Billing on the client: the `/v1/me` billing object, the browser-link host policy, the offer, checkout and portal
/// calls against the fake service, and the checkout terms the plan sheet shows from the offer's quote.
final class ParaAirCloudBillingTests: XCTestCase {
    private var fake: FakeParaAirCloud!
    private var account: FakeParaAirCloud.Account!

    override func setUpWithError() throws {
        fake = FakeParaAirCloud(); account = fake.createAccount()
    }

    private func api(for account: FakeParaAirCloud.Account? = nil) throws -> ParaAirCloudAPI {
        let tokens = fake.issueTokens(for: account ?? self.account)
        let http = try ParaAirCloudHTTP(baseURL: fake.issuer, policy: .init(allowsLoopbackHTTP: false), configuration: fake.configuration)
        let api = ParaAirCloudAPI(http: http, tokens: StaticAccessToken(tokens.accessToken))
        api.retryDelays = [0.01, 0.01]; api.sleep = { _ in }
        return api
    }

    private func expectBillingError(_ code: Int32, _ message: String, file: StaticString = #filePath, line: UInt = #line,
                                    _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            let drive = error as? DriveError
            XCTAssertEqual(drive?.code, code, "\(error)", file: file, line: line)
            XCTAssertTrue(drive?.message.hasPrefix(message) == true, "\(drive?.message ?? "\(error)")", file: file, line: line)
        }
    }

    // MARK: Decoding

    private static func workspaceJSON(billing: String?) -> Data {
        let field = billing.map { #","billing":"# + $0 } ?? ""
        return Data(("""
        {"id":"ws_01J9ZX5Q4WJ3M8K2V7N6R1T0YC","name":"Studio","kind":"team","role":"owner","status":"active",
         "plan":{"id":"beta","name":"Beta","storageLimitBytes":3000000000000,"transferAllowanceBytes":9000000000000,"retentionDays":90,
                 "retentionCapBytes":450000000000,"seats":3,"manageUrl":null}
        """ + field + "}").utf8)
    }

    func testBillingObjectDecodesTheContractExample() throws {
        // contract/paraair-cloud-v1/README.md, "billing in GET /v1/me".
        let billing = """
        {"provider":"stripe","status":"past_due","plan":"team","interval":"year","seats":3,"extraStorageTb":1,
         "currentPeriodEnd":"2027-10-12T00:00:00.000Z","cancelAtPeriodEnd":false,"graceEndsAt":"2026-10-26T00:00:00.000Z",
         "readOnlyAt":"2026-10-26T00:00:00.000Z","deletionAt":"2026-11-25T00:00:00.000Z","checkoutAvailable":false,"portalAvailable":true}
        """
        let workspace = try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: billing))
        let decoded = try XCTUnwrap(workspace.billing)
        XCTAssertEqual(decoded, ParaAirCloudBilling(
            provider: .stripe, status: .pastDue, plan: .team, interval: .year, seats: 3, extraStorageTb: 1,
            currentPeriodEnd: ParaAirCloudJSON.parseDate("2027-10-12T00:00:00.000Z"), cancelAtPeriodEnd: false,
            graceEndsAt: ParaAirCloudJSON.parseDate("2026-10-26T00:00:00.000Z"), readOnlyAt: ParaAirCloudJSON.parseDate("2026-10-26T00:00:00.000Z"),
            deletionAt: ParaAirCloudJSON.parseDate("2026-11-25T00:00:00.000Z"), checkoutAvailable: false, portalAvailable: true))
        XCTAssertTrue(decoded.isLive)
        XCTAssertEqual(workspace.plan?.seats, 3)

        let off = """
        {"provider":"none","status":"none","plan":null,"interval":null,"seats":null,"extraStorageTb":0,"currentPeriodEnd":null,
         "cancelAtPeriodEnd":false,"graceEndsAt":null,"readOnlyAt":null,"deletionAt":null,"checkoutAvailable":false,"portalAvailable":false}
        """
        let none = try XCTUnwrap(try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: off)).billing)
        XCTAssertEqual(none, ParaAirCloudBilling(provider: .none, status: .none))
        XCTAssertFalse(none.isLive)
    }

    func testOlderServerWithoutBillingStillDecodes() throws {
        let workspace = try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: nil))
        XCTAssertNil(workspace.billing)
        XCTAssertEqual(workspace.plan?.storageLimitBytes, 3_000_000_000_000)

        fake.omitsBilling = true
        let me = try api().me()
        XCTAssertEqual(me.workspaces.count, 1)
        XCTAssertNil(me.workspaces[0].billing)
        XCTAssertNotNil(me.workspaces[0].usage)
    }

    func testMalformedBillingIsDroppedWithoutLosingThePlan() throws {
        let valid = #""provider":"stripe","status":"active","plan":"personal","interval":"month","seats":1,"extraStorageTb":0,"currentPeriodEnd":null,"cancelAtPeriodEnd":false,"graceEndsAt":null,"readOnlyAt":null,"deletionAt":null,"checkoutAvailable":false,"portalAvailable":true"#
        XCTAssertNotNil(try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: "{" + valid + "}")).billing)
        let broken = [
            valid.replacingOccurrences(of: #""status":"active""#, with: #""status":"trialing""#),
            valid.replacingOccurrences(of: #""provider":"stripe""#, with: #""provider":"lemonsqueezy""#),
            valid.replacingOccurrences(of: #""seats":1"#, with: #""seats":-1"#),
            valid.replacingOccurrences(of: #""seats":1"#, with: #""seats":1.5"#),
            valid.replacingOccurrences(of: #""extraStorageTb":0"#, with: #""extraStorageTb":-1"#),
            valid.replacingOccurrences(of: #""status":"active""#, with: #""status":"none""#),
            valid.replacingOccurrences(of: #""provider":"stripe""#, with: #""provider":"none""#),
            valid.replacingOccurrences(of: #""currentPeriodEnd":null"#, with: #""currentPeriodEnd":"next week""#),
            valid.replacingOccurrences(of: #","portalAvailable":true"#, with: ""),
        ]
        for body in broken {
            let workspace = try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: "{" + body + "}"))
            XCTAssertNil(workspace.billing, body)
            XCTAssertEqual(workspace.plan?.seats, 3, body)
        }
        XCTAssertNil(try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: "[]")).billing)
    }

    /// Review 2026-10-13 (app): seats above 1000 (seat sync has no cap), more than 100 TB of storage blocks (from the
    /// processor's items) and a paid status without a known plan are shapes the service emits. Dropping the object hid
    /// the past-due notice and every billing control, so they decode; the presentation shows only what it knows.
    func testBillingShapesTheServiceEmitsStillDecode() throws {
        let pastDue = #""provider":"stripe","status":"past_due","plan":"team","interval":"month","seats":1001,"extraStorageTb":0,"currentPeriodEnd":"2026-11-12T00:00:00.000Z","cancelAtPeriodEnd":false,"graceEndsAt":"2026-10-26T00:00:00.000Z","readOnlyAt":"2026-10-26T00:00:00.000Z","deletionAt":"2026-11-25T00:00:00.000Z","checkoutAvailable":false,"portalAvailable":true"#
        let big = try XCTUnwrap(try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: "{" + pastDue + "}")).billing)
        XCTAssertEqual(big.status, .pastDue)
        XCTAssertEqual(big.seats, 1001)
        XCTAssertTrue(big.portalAvailable)
        let storage = pastDue.replacingOccurrences(of: #""extraStorageTb":0"#, with: #""extraStorageTb":250"#)
        XCTAssertEqual(try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: "{" + storage + "}")).billing?.extraStorageTb, 250)
        let unknownPlan = pastDue.replacingOccurrences(of: #""status":"past_due","plan":"team","interval":"month""#,
                                                       with: #""status":"active","plan":null,"interval":null"#)
        let active = try XCTUnwrap(try ParaAirCloudJSON.decode(ParaAirCloudMe.Workspace.self, from: Self.workspaceJSON(billing: "{" + unknownPlan + "}")).billing)
        XCTAssertEqual(active.status, .active)
        XCTAssertNil(active.plan)
        XCTAssertTrue(active.isLive)
    }

    func testMeReportsBillingFromTheService() throws {
        XCTAssertEqual(try api().me().workspaces[0].billing, ParaAirCloudBilling(provider: .none, status: .none))
        fake.billingProvider = "paddle"
        XCTAssertEqual(try api().me().workspaces[0].billing, ParaAirCloudBilling(provider: .paddle, status: .none, checkoutAvailable: true))
        let end = Date(timeIntervalSince1970: 1_823_040_000)
        fake.setBilling(workspaceID: account.workspaceID, .init(provider: "paddle", state: "active", plan: "personal", interval: "year",
                                                                periodEnd: end))
        let billing = try XCTUnwrap(try api().me().workspaces[0].billing)
        XCTAssertEqual(billing.status, .active)
        XCTAssertEqual(billing.currentPeriodEnd, end)
        XCTAssertFalse(billing.checkoutAvailable, "a live subscription offers the portal, not checkout")
        XCTAssertTrue(billing.portalAvailable)
    }

    // MARK: Link policy

    func testLinkPolicyOpensOnlyKnownCheckoutAndPortalHosts() throws {
        let issuer = URL(string: "https://cloud.parafield.ai")!
        let checkout = [
            "https://checkout.stripe.com/c/pay/cs_test_a11YYufWQzNY63zpQ6QSNRQhkUpVph4WRmzW0zWJO2znZKdVujZ0N0S22u#fidkdWxOYHwnPyd1blpxYHZxWjA0SDdPUW5JbmFMck1wMmx9N2BLZjFEfGRUNWhqTmJ%2FM2F8bUA2SDRySkFdUV81T1BSV0YxcWJcTUJcYW5rSzN3dzBLPUE0TzRKTTxzNFBjPWZEX1NKSkxpNTVjRjN8VHE0YicpJ2N3amhWYHdzYHcnP3F3cGApJ2lkfGpwcVF8dWAnPyd2bGtiaWBabHFgaCcpJ2BrZGdpYFVpZGZgbWppYWB3dic%2FcXdwYHgl",
            "https://CHECKOUT.STRIPE.COM/c/pay/cs_live_1",
            "https://checkout.stripe.com:443/c/pay/cs_live_1",
            "https://cloud.parafield.ai/billing/pay?_ptxn=txn_01h2b0qpjc0xt8k5aw6nsdec4p",
            "https://cloud.parafield.ai:443/billing/pay?_ptxn=txn_01h2b0qpjc0xt8k5aw6nsdec4p",
            "https://pay.paddle.io/checkout/hsc_01jt8s46kx4nv91002z7vy4ecj_1as3scas9cascascasasx23dsa3asd2a?transaction_id=txn_1",
            "https://sandbox.pay.paddle.io/checkout/hsc_01jt8s46kx4nv91002z7vy4ecj?transaction_id=txn_1",
        ]
        let portal = [
            "https://billing.stripe.com/p/session?secret=test_YWNjdF8xTTJKVGtMa2RJd0h1N2l4LF9OY2lBYjJXcHY4a2NPck96UjBEbFVYRnU5bjlwVUF50100BUtQs3bl",
            "https://billing.stripe.com/p/session/live_YWNjdF8x",
            "https://customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw?action=overview&token=pga_eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
            "https://sandbox-customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw?action=overview&token=pga_1",
        ]
        for value in checkout { XCTAssertNoThrow(try ParaAirCloudBillingLink.validate(value, kind: .checkout, issuer: issuer), value) }
        for value in portal { XCTAssertNoThrow(try ParaAirCloudBillingLink.validate(value, kind: .portal, issuer: issuer), value) }
        // Each kind opens only its own hosts.
        for value in portal { expectDriveError(EPROTO) { _ = try ParaAirCloudBillingLink.validate(value, kind: .checkout, issuer: issuer) } }
        for value in checkout { expectDriveError(EPROTO) { _ = try ParaAirCloudBillingLink.validate(value, kind: .portal, issuer: issuer) } }

        let refused = [
            "", "http://checkout.stripe.com/c/pay/cs_1", "https://checkout.stripe.com.evil.example/c/pay/cs_1",
            "https://evil.example/billing/pay?_ptxn=txn_1", "https://stripe.com/c/pay/cs_1", "https://pay.stripe.com/c/pay/cs_1",
            "https://user:pass@checkout.stripe.com/c/pay/cs_1", "https://checkout.stripe.com@evil.example/c/pay/cs_1",
            "https://checkout.stripe.com:8443/c/pay/cs_1", "https://checkout.stripe.com./c/pay/cs_1", "https://checkout%2Estripe.com/c/pay/cs_1",
            "https://xn--chckout-gya.stripe.com/c/pay/cs_1", "https://chéckout.stripe.com/c/pay/cs_1", "https://checkout.stripe.com/c/pay/cs 1",
            "https://checkout.stripe.com/c/pay/cs_1\n", "javascript:alert(1)", "file:///etc/passwd", "//checkout.stripe.com/c/pay/cs_1",
            "https://cloud.parafield.ai/oauth/authorize", "https://cloud.parafield.ai/billing/pay/../../oauth",
            "https://cloud.parafield.ai/billing/success", "http://cloud.parafield.ai/billing/pay?_ptxn=txn_1",
            "https://cloud.parafield.ai:8443/billing/pay?_ptxn=txn_1", "https://cloud.parafield.ai.evil.example/billing/pay?_ptxn=txn_1",
            "https://checkout.stripe.com/" + String(repeating: "a", count: 8200),
        ]
        for value in refused { expectDriveError(EPROTO) { _ = try ParaAirCloudBillingLink.validate(value, kind: .checkout, issuer: issuer) } }
        expectDriveError(EPROTO) { _ = try ParaAirCloudBillingLink.validate("https://cloud.parafield.ai/billing/pay?_ptxn=txn_1", kind: .portal, issuer: issuer) }

        // A loopback development issuer: only its own exact address and port.
        let dev = URL(string: "http://127.0.0.1:8797")!
        XCTAssertNoThrow(try ParaAirCloudBillingLink.validate("http://127.0.0.1:8797/billing/pay?_ptxn=txn_1", kind: .checkout, issuer: dev))
        for value in ["http://127.0.0.1:8798/billing/pay?_ptxn=txn_1", "http://localhost:8797/billing/pay?_ptxn=txn_1",
                      "https://127.0.0.1:8797/billing/pay?_ptxn=txn_1", "http://127.0.0.1/billing/pay?_ptxn=txn_1"] {
            expectDriveError(EPROTO) { _ = try ParaAirCloudBillingLink.validate(value, kind: .checkout, issuer: dev) }
        }
    }

    // MARK: Checkout and portal against the fake service

    func testStripeCheckoutSendsOnlyThePlanAndOpensStripeCheckout() throws {
        fake.billingProvider = "stripe"
        let url = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
        XCTAssertEqual(url.host, "checkout.stripe.com")
        XCTAssertNotNil(url.fragment, "Stripe's session URL keeps its fragment")
        let request = try XCTUnwrap(fake.requests("POST /v1/billing/checkout").last)
        XCTAssertEqual(request.headers["content-type"], "application/json")
        XCTAssertTrue(request.headers["x-paraair-client"]?.hasPrefix("mac/") == true)
        XCTAssertTrue(request.headers["authorization"]?.hasPrefix("Bearer pca_") == true)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["workspaceId", "plan", "interval", "extraStorageTb"], "no amount and no seats for Personal")
        XCTAssertEqual(body["workspaceId"] as? String, account.workspaceID)
        XCTAssertEqual(body["plan"] as? String, "personal")
        XCTAssertEqual(body["interval"] as? String, "month")
        XCTAssertEqual(body["extraStorageTb"] as? Int, 0)
    }

    func testPaddleCheckoutOpensTheIssuerPaymentPageAndPortalOpensPaddle() throws {
        fake.billingProvider = "paddle"; fake.paddleSandbox = true
        let url = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .year))
        XCTAssertEqual(url.host, fake.host)
        XCTAssertEqual(url.path, "/billing/pay")
        XCTAssertTrue(url.query?.hasPrefix("_ptxn=txn_") == true)

        expectBillingError(ENOENT, "This workspace has no paid plan to manage") { _ = try api().billingPortal(workspaceID: account.workspaceID) }
        fake.setBilling(workspaceID: account.workspaceID, .init(provider: "paddle", state: "past_due", plan: "personal", interval: "year"))
        let portal = try api().billingPortal(workspaceID: account.workspaceID)
        XCTAssertEqual(portal.host, "sandbox-customer-portal.paddle.com")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(fake.requests("POST /v1/billing/portal").last).body) as? [String: Any])
        XCTAssertEqual(body as? [String: String], ["workspaceId": account.workspaceID])
        fake.paddleSandbox = false
        XCTAssertEqual(try api().billingPortal(workspaceID: account.workspaceID).host, "customer-portal.paddle.com")
    }

    func testTeamCheckoutSendsSeatsAndStorage() throws {
        fake.billingProvider = "stripe"
        let team = fake.createTeamWorkspace(owner: account)
        for _ in 0..<2 { fake.addMember(workspaceID: team, userID: fake.createAccount().userID, role: "member") }
        let me = try api().me()
        XCTAssertEqual(me.workspaces.first { $0.id == team }?.kind, "team")
        XCTAssertEqual(me.workspaces.first { $0.id == team }?.billing?.checkoutAvailable, true)

        _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: team, plan: .team, interval: .year, seats: 4, extraStorageTb: 2))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(fake.requests("POST /v1/billing/checkout").last).body) as? [String: Any])
        XCTAssertEqual(body["plan"] as? String, "team")
        XCTAssertEqual(body["seats"] as? Int, 4)
        XCTAssertEqual(body["extraStorageTb"] as? Int, 2)

        expectBillingError(EINVAL, "ParaAir Cloud didn’t accept that plan. For Team, choose at least one seat per member") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: team, plan: .team, interval: .month, seats: 2))
        }
        expectBillingError(EINVAL, "ParaAir Cloud didn’t accept that plan") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: team, plan: .personal, interval: .month))
        }
    }

    func testBillingErrorsExplainThePlanNotFiles() throws {
        expectBillingError(ENOENT, "Paid plans aren’t available for this workspace right now") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
        }
        fake.billingProvider = "stripe"
        let member = fake.createAccount()
        let team = fake.createTeamWorkspace(owner: account)
        fake.addMember(workspaceID: team, userID: member.userID, role: "admin")
        XCTAssertEqual(try api(for: member).me().workspaces.first { $0.id == team }?.billing?.checkoutAvailable, false, "owner only")
        expectBillingError(EACCES, "Only the workspace owner can change its plan") {
            _ = try api(for: member).billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: team, plan: .team, interval: .month, seats: 2))
        }
        expectBillingError(ENOENT, "The ParaAir Cloud workspace does not exist") {
            _ = try api(for: member).billingPortal(workspaceID: account.workspaceID)
        }
        fake.setBilling(workspaceID: account.workspaceID, .init(state: "past_due"))
        expectBillingError(EBUSY, "This workspace already has a paid plan or a payment that is still going through") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
        }
        fake.setStatus(workspaceID: account.workspaceID, "suspended")
        expectBillingError(EACCES, "This ParaAir Cloud workspace is suspended") { _ = try api().billingPortal(workspaceID: account.workspaceID) }
        fake.setStatus(workspaceID: account.workspaceID, "active")

        fake.sellablePlans = ["personal"]
        expectBillingError(EIO, "Paid plans can’t be bought right now. Try again later") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: team, plan: .team, interval: .month, seats: 2))
        }
        XCTAssertEqual(fake.requests("POST /v1/billing/checkout").count, 4, "billing calls are never retried")

        // ownerOf counts every session; the 21st in an hour is refused with the wait in minutes.
        let api = try self.api()
        let before = fake.requests("POST /v1/billing/portal").count
        var limited: Error?
        for _ in 0..<25 {
            do { _ = try api.billingPortal(workspaceID: account.workspaceID) } catch { limited = error; break }
        }
        let drive = try XCTUnwrap(limited as? DriveError)
        XCTAssertEqual(drive.code, EAGAIN)
        XCTAssertTrue(drive.message.hasPrefix("Too many payment pages were opened for this workspace. Try again in "), drive.message)
        XCTAssertTrue(drive.message.range(of: #"Try again in [0-9]+ minutes? \(request req_[0-9A-Z]+\)$"#, options: .regularExpression) != nil, drive.message)
        XCTAssertGreaterThanOrEqual(fake.requests("POST /v1/billing/portal").count - before, 20)
    }

    func testRepliesWithForeignLinksAreRefused() throws {
        fake.billingProvider = "stripe"
        fake.setBilling(workspaceID: account.workspaceID, .init(state: "active"))
        for link in ["https://evil.example/pay", "https://checkout.stripe.com.evil.example/c/pay/cs_1", "javascript:alert(1)",
                     "https://billing.stripe.com/p/session/test_1"] {
            fake.checkoutURLOverride = link
            fake.setBilling(workspaceID: account.workspaceID, nil)
            expectBillingError(EPROTO, "ParaAir Cloud returned a payment page this app won’t open") {
                _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
            }
        }
        fake.setBilling(workspaceID: account.workspaceID, .init(state: "active"))
        for link in ["https://checkout.stripe.com/c/pay/cs_1", fake.issuerString + "/billing/pay?_ptxn=txn_1", "http://billing.stripe.com/p/session/1"] {
            fake.portalURLOverride = link
            expectBillingError(EPROTO, "ParaAir Cloud returned a payment page this app won’t open") {
                _ = try api().billingPortal(workspaceID: account.workspaceID)
            }
        }
        fake.injectRaw(route: "POST /v1/billing/portal", status: 200, body: Data(#"{"link":"https://billing.stripe.com/p/session/1"}"#.utf8),
                       headers: ["Content-Type": "application/json"])
        expectDriveError(EIO) { _ = try api().billingPortal(workspaceID: account.workspaceID) }
    }

    func testInvalidRequestsNeverLeaveTheMac() throws {
        fake.billingProvider = "stripe"
        let bad = [
            ParaAirCloudCheckoutRequest(workspaceID: "ws_short", plan: .personal, interval: .month),
            ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month, seats: 2),
            ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .team, interval: .month, seats: 0),
            ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .team, interval: .month, seats: 1001),
            ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month, extraStorageTb: 101),
            ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month, extraStorageTb: -1),
        ]
        for request in bad { expectDriveError(EINVAL) { _ = try api().billingCheckout(request) } }
        expectDriveError(EINVAL) { _ = try api().billingPortal(workspaceID: "ws_" + String(repeating: "a", count: 26)) }
        XCTAssertTrue(fake.requests("POST /v1/billing/checkout").isEmpty)
        XCTAssertTrue(fake.requests("POST /v1/billing/portal").isEmpty)
    }

    /// Review 2026-10-13 (app): a 429 whose retry value is near Int.max (body or header, or a huge float) trapped on
    /// `($0 + 59) / 60`. Every value now gives a bounded wait in the message.
    func testHugeRetryAfterNeverTraps() throws {
        fake.billingProvider = "stripe"
        let envelope = { (value: String) in Data(#"{"error":{"code":"rate_limited","message":"Too many requests","requestId":"req_test","retryAfterSeconds":"# .utf8)
            + Data(value.utf8) + Data("}}".utf8) }
        let replies: [(Data, [String: String])] = [
            (envelope("9223372036854775807"), [:]), (envelope("9223372036854775749"), [:]), (envelope("1e300"), [:]),
            (Data(#"{"error":{"code":"rate_limited","message":"Too many requests","requestId":"req_test"}}"#.utf8),
             ["Retry-After": "9223372036854775807"]),
        ]
        for (body, headers) in replies {
            fake.injectRaw(route: "POST /v1/billing/checkout", status: 429, body: body,
                           headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a })
            XCTAssertThrowsError(try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal,
                                                                                        interval: .month))) { error in
                let drive = error as? DriveError
                XCTAssertEqual(drive?.code, EAGAIN, "\(error)")
                XCTAssertTrue(drive?.message.hasPrefix("Too many payment pages were opened for this workspace. Try again in") == true,
                              drive?.message ?? "\(error)")
            }
        }
        let clamped = ParaAirCloudErrorMap.parse(status: 429, body: envelope("9223372036854775807"))
        XCTAssertEqual(clamped.retryAfterSeconds, ParaAirCloudErrorMap.maximumRetryAfterSeconds)
        XCTAssertEqual(ParaAirCloudErrorMap.parse(status: 429, body: envelope("120")).retryAfterSeconds, 120)
        XCTAssertEqual(ParaAirCloudErrorMap.parse(status: 429, body: envelope("-5")).retryAfterSeconds, 0)
        XCTAssertEqual(ParaAirCloudErrorMap.parse(status: 429, body: envelope("-9223372036854775808")).retryAfterSeconds, 0)
        XCTAssertEqual(ParaAirCloudErrorMap.parse(status: 429, body: envelope("1e300")).retryAfterSeconds, ParaAirCloudErrorMap.maximumRetryAfterSeconds)
        XCTAssertEqual(ParaAirCloudErrorMap.parse(status: 429, body: Data(), headers: ["retry-after": "99999999999999999999999"]).retryAfterSeconds,
                       ParaAirCloudErrorMap.maximumRetryAfterSeconds)
    }

    func testUnavailableCheckoutIsTriedOnce() throws {
        fake.billingProvider = "stripe"
        fake.inject(route: "POST /v1/billing/checkout", status: 503, code: "unavailable", times: 3)
        expectBillingError(EIO, "Payments can’t be reached right now. Try again in a few minutes (request req_") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
        }
        XCTAssertEqual(fake.requests("POST /v1/billing/checkout").count, 1)
        fake.injectTransport(.timedOut, route: "POST /v1/billing/portal")
        expectDriveError(ETIMEDOUT) { _ = try api().billingPortal(workspaceID: account.workspaceID) }
        XCTAssertEqual(fake.requests("POST /v1/billing/portal").count, 1)
    }

    // MARK: Offer, terms and consent

    /// contract/paraair-cloud-v1/README.md, "GET /v1/billing/offer".
    func testOfferDecodesTheContractExample() throws {
        let example = Data("""
        {"provider":"paddle","merchantOfRecord":{"name":"Paddle","reseller":true},"disclosureVersion":"A-draft-2026-10-23","currency":"USD",
         "prices":[{"item":"personal_month","kind":"plan","plan":"personal","interval":"month","unitAmountCents":1000,"perMember":false},
                   {"item":"team_year","kind":"plan","plan":"team","interval":"year","unitAmountCents":16000,"perMember":true},
                   {"item":"storage_month","kind":"storage","plan":null,"interval":"month","unitAmountCents":1000,"perMember":false},
                   {"item":"gift_month","kind":"gift","plan":null,"interval":"month","unitAmountCents":500,"perMember":false}],
         "quote":{"plan":"team","interval":"year","seats":3,"extraStorageTb":0,"amountCents":48000,"currency":"USD",
                  "terms":["ParaAir Cloud Team, billed yearly","$160.00 per member per year plus tax. Renews automatically every year until you cancel.","- …"],
                  "consent":"I agree that this ParaAir Cloud Team plan renews automatically at … I agree to the Terms of Service and the …"}}
        """.utf8)
        let offer = try ParaAirCloudJSON.decode(ParaAirCloudBillingOffer.self, from: example)
        XCTAssertEqual(offer.provider, .paddle)
        XCTAssertEqual(offer.merchant, .init(name: "Paddle", reseller: true))
        XCTAssertEqual(offer.disclosureVersion, "A-draft-2026-10-23")
        XCTAssertEqual(offer.prices.map(\.item), ["personal_month", "team_year", "storage_month"], "an unknown kind of item is skipped")
        XCTAssertEqual(offer.unitAmountCents(.personal, .month), 1_000)
        XCTAssertNil(offer.unitAmountCents(.personal, .year), "only what the price map sells")
        XCTAssertEqual(offer.amountCents(plan: .team, interval: .year, seats: 3), 48_000)
        XCTAssertEqual(offer.amountCents(plan: .personal, interval: .month, seats: 1, storageTb: 2), 3_000)
        XCTAssertNil(offer.amountCents(plan: .team, interval: .month, seats: 3))
        XCTAssertNil(offer.yearlySavingsCents(.team), "no monthly Team price to compare with")
        XCTAssertEqual(offer.quote?.amountCents, 48_000)
        XCTAssertEqual(offer.format(cents: 160_000), "$1,600.00")
        XCTAssertEqual(offer.format(cents: 160_000, short: true), "$1,600")
        XCTAssertEqual(offer.format(cents: 1_650, short: true), "$16.50")
    }

    /// Review 2026-10-13 (app): the plan sheet shows the service's prices, merchant of record and disclosure text, not
    /// copies compiled into the app, and the consent record names the version that was shown.
    func testOfferComesFromTheServiceAndQuotesTheSelection() throws {
        fake.billingProvider = "paddle"
        let offer = try api().billingOffer()
        XCTAssertEqual(offer.provider, .paddle)
        XCTAssertEqual(offer.merchant, .init(name: "Paddle", reseller: true))
        XCTAssertEqual(offer.disclosureVersion, fake.disclosureVersion)
        XCTAssertEqual(offer.currency, "USD")
        XCTAssertNil(offer.quote)
        XCTAssertEqual(offer.unitAmountCents(.team, .year), 16_000)
        XCTAssertEqual(offer.yearlySavingsCents(.personal), 2_000)
        XCTAssertEqual(offer.yearlySavingsCents(.team), 3_200)
        XCTAssertEqual(fake.requests("GET /v1/billing/offer").last?.rawQuery, nil)

        let quoted = try api().billingOffer(ParaAirCloudOfferRequest(plan: .team, interval: .year, seats: 3))
        let quote = try XCTUnwrap(quoted.quote)
        XCTAssertEqual(quote.amountCents, 48_000)
        XCTAssertEqual(fake.requests("GET /v1/billing/offer").last?.query, ["plan": "team", "interval": "year", "seats": "3", "extraStorageTb": "0"])
        let terms = try XCTUnwrap(ParaAirCloudCheckoutTerms(quote))
        XCTAssertEqual(terms.heading, "ParaAir Cloud Team, billed yearly")
        XCTAssertEqual(terms.priceLine, "$160.00 per member per year plus tax. Renews automatically every year until you cancel.")
        XCTAssertEqual(terms.bullets.first, "You are buying 3 member seats: $480.00 per year plus tax.")
        XCTAssertTrue(terms.bullets.contains { $0.hasPrefix("Then Paddle, our reseller, charges for the current number of members") }, "\(terms.bullets)")
        XCTAssertEqual(terms.renewalConsent,
                       "I agree that this ParaAir Cloud Team plan renews automatically at $160.00 per member per year plus tax, for the number of members at each renewal, until I cancel.")
        XCTAssertEqual(terms.documentsConsent, "I agree to the [Terms of Service](\(fake.issuerString)/legal/terms) and the "
                       + "[Subscription, Cancellation and Refund Policy](\(fake.issuerString)/legal/subscription-policy), and I am authorized to agree for this team.")

        // Stripe: Parafield charges, and the same text says so.
        fake.billingProvider = "stripe"
        let stripe = try api().billingOffer(ParaAirCloudOfferRequest(plan: .personal, interval: .month))
        XCTAssertEqual(stripe.merchant, .init(name: "Parafield Inc.", reseller: false))
        let personal = try XCTUnwrap(stripe.quote.flatMap(ParaAirCloudCheckoutTerms.init))
        XCTAssertTrue(personal.bullets.contains { $0.hasPrefix("Then we charge $10.00 plus tax on the ") }, "\(personal.bullets)")
        XCTAssertFalse(([personal.heading, personal.priceLine, personal.renewalConsent, personal.documentsConsent] + personal.bullets).joined().contains("Paddle"))

        // A price change on the service reaches the app's figures and its terms without an update.
        fake.priceOverrides = ["personal_month": 1_200]
        let raised = try api().billingOffer(ParaAirCloudOfferRequest(plan: .personal, interval: .month))
        XCTAssertEqual(raised.unitAmountCents(.personal, .month), 1_200)
        XCTAssertEqual(raised.quote.flatMap(ParaAirCloudCheckoutTerms.init)?.priceLine,
                       "$12.00 per month plus tax. Renews automatically every month until you cancel.")
    }

    func testOfferListsOnlyWhatTheServiceSells() throws {
        fake.billingProvider = "stripe"
        fake.sellablePlans = ["personal"]
        let offer = try api().billingOffer(ParaAirCloudOfferRequest(plan: .team, interval: .month, seats: 2))
        XCTAssertTrue(offer.sells(.personal))
        XCTAssertFalse(offer.sells(.team))
        XCTAssertNil(offer.quote, "no quote for a plan that is not sold")
        expectBillingError(ENOENT, "Paid plans aren’t available for this workspace right now") {
            self.fake.billingProvider = "none"; _ = try self.api().billingOffer()
        }
        fake.billingProvider = "paddle"; fake.billingConfigured = false
        expectBillingError(EIO, "Paid plans can’t be bought right now. Try again later") { _ = try api().billingOffer() }
        XCTAssertEqual(try api().me().workspaces[0].billing?.checkoutAvailable, false, "nothing to sell without the settings checkout needs")
        expectBillingError(EIO, "Paid plans can’t be bought right now. Try again later") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
        }
        // Invalid selections never leave the Mac.
        let before = fake.requests("GET /v1/billing/offer").count
        for selection in [ParaAirCloudOfferRequest(plan: .personal, interval: .month, seats: 2),
                          ParaAirCloudOfferRequest(plan: .team, interval: .month, seats: 0),
                          ParaAirCloudOfferRequest(plan: .team, interval: .year, seats: 1001),
                          ParaAirCloudOfferRequest(plan: .personal, interval: .year, extraStorageTb: 101)] {
            expectDriveError(EINVAL) { _ = try api().billingOffer(selection) }
        }
        XCTAssertEqual(fake.requests("GET /v1/billing/offer").count, before)
    }

    /// Review 2026-10-13 (app): checkout sends the version of the text the buyer read and both ticked boxes, and the
    /// service refuses a version it no longer shows.
    func testCheckoutRecordsTheDisclosureVersionAndConsent() throws {
        fake.billingProvider = "paddle"
        let offer = try api().billingOffer(ParaAirCloudOfferRequest(plan: .personal, interval: .year))
        let consent = ParaAirCloudCheckoutConsent(disclosureVersion: offer.disclosureVersion, autoRenew: true, terms: true)
        _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .year, consent: consent))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(fake.requests("POST /v1/billing/checkout").last).body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["workspaceId", "plan", "interval", "extraStorageTb", "disclosureVersion", "consent"])
        XCTAssertEqual(body["disclosureVersion"] as? String, "A-draft-2026-10-23")
        XCTAssertEqual(body["consent"] as? [String: Bool], ["autoRenew": true, "terms": true])
        XCTAssertEqual(fake.checkouts.last?["disclosureVersion"] as? String, offer.disclosureVersion, "the service recorded the version shown")

        // The service's text changed after the app showed it: agree again to the new text.
        fake.disclosureVersion = "A-draft-2026-11-01"
        expectBillingError(ESTALE, "The plan terms changed. Read them again and agree to continue") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .year, consent: consent))
        }
        // One box, or a version the service could not store, never leaves the Mac.
        let sent = fake.requests("POST /v1/billing/checkout").count
        for bad in [ParaAirCloudCheckoutConsent(disclosureVersion: offer.disclosureVersion, autoRenew: false, terms: true),
                    ParaAirCloudCheckoutConsent(disclosureVersion: offer.disclosureVersion, autoRenew: true, terms: false),
                    ParaAirCloudCheckoutConsent(disclosureVersion: "A draft", autoRenew: true, terms: true),
                    ParaAirCloudCheckoutConsent(disclosureVersion: "", autoRenew: true, terms: true),
                    ParaAirCloudCheckoutConsent(disclosureVersion: String(repeating: "A", count: 65), autoRenew: true, terms: true)] {
            expectDriveError(EINVAL) {
                _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .year, consent: bad))
            }
        }
        XCTAssertEqual(fake.requests("POST /v1/billing/checkout").count, sent)
    }

    /// A new checkout makes the workspace's earlier unpaid page unpayable; one already paid refuses the new checkout.
    func testStartingOverClosesTheEarlierPaymentPage() throws {
        fake.billingProvider = "stripe"
        let request = ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month)
        let first = try api().billingCheckout(request)
        let second = try api().billingCheckout(request)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fake.closedCheckoutURLs, [first.absoluteString])
        fake.paidUnboundCheckouts = [account.workspaceID]
        expectBillingError(EBUSY, "This workspace already has a paid plan or a payment that is still going through") {
            _ = try api().billingCheckout(request)
        }
    }

    func testMalformedOffersAreRefused() throws {
        fake.billingProvider = "paddle"
        let valid: [String: Any] = [
            "provider": "paddle", "merchantOfRecord": ["name": "Paddle", "reseller": true], "disclosureVersion": "A-draft-2026-10-23",
            "currency": "USD", "prices": [["item": "personal_month", "kind": "plan", "plan": "personal", "interval": "month",
                                           "unitAmountCents": 1000, "perMember": false]],
            "quote": ["plan": "personal", "interval": "month", "seats": 1, "extraStorageTb": 0, "amountCents": 1000, "currency": "USD",
                      "terms": ["Heading", "Price line", "- A bullet"], "consent": "I agree to renew. I agree to the Terms."]]
        func reply(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = valid; change(&object); return try JSONSerialization.data(withJSONObject: object)
        }
        let selection = ParaAirCloudOfferRequest(plan: .personal, interval: .month)
        fake.injectRaw(route: "GET /v1/billing/offer", status: 200, body: try reply { _ in }, headers: ["Content-Type": "application/json"])
        XCTAssertEqual(try api().billingOffer(selection).quote?.amountCents, 1000)
        let broken: [(inout [String: Any]) -> Void] = [
            { $0["provider"] = "none" }, { $0["provider"] = "lemonsqueezy" }, { $0["merchantOfRecord"] = ["name": "", "reseller": true] },
            { $0["merchantOfRecord"] = ["name": "Pad\u{7}dle", "reseller": true] }, { $0["disclosureVersion"] = "A draft" },
            { $0["disclosureVersion"] = String(repeating: "v", count: 65) }, { $0["currency"] = "usd" },
            { var q = $0["quote"] as! [String: Any]; q["plan"] = "team"; q["seats"] = 3; $0["quote"] = q },
            { var q = $0["quote"] as! [String: Any]; q["seats"] = 2; $0["quote"] = q },
            { var q = $0["quote"] as! [String: Any]; q["amountCents"] = -1; $0["quote"] = q },
            { var q = $0["quote"] as! [String: Any]; q["currency"] = "EUR"; $0["quote"] = q },
            { var q = $0["quote"] as! [String: Any]; q["terms"] = ["Heading", "Price line"]; $0["quote"] = q },
            { var q = $0["quote"] as! [String: Any]; q["terms"] = ["Heading", "Price\nline", "- A bullet"]; $0["quote"] = q },
            { var q = $0["quote"] as! [String: Any]; q["consent"] = ""; $0["quote"] = q },
        ]
        for change in broken {
            fake.injectRaw(route: "GET /v1/billing/offer", status: 200, body: try reply(change), headers: ["Content-Type": "application/json"])
            expectDriveError(EIO) { _ = try api().billingOffer(selection) }
        }
        // A quote without a selection is not what was asked for either.
        fake.injectRaw(route: "GET /v1/billing/offer", status: 200, body: try reply { _ in }, headers: ["Content-Type": "application/json"])
        expectDriveError(EIO) { _ = try api().billingOffer() }
        // A price row too large to add up safely is skipped, like any row the app does not understand.
        fake.injectRaw(route: "GET /v1/billing/offer", status: 200, body: try reply {
            $0["prices"] = [["item": "personal_month", "kind": "plan", "plan": "personal", "interval": "month", "unitAmountCents": Int.max, "perMember": false]]
            $0["quote"] = NSNull()
        }, headers: ["Content-Type": "application/json"])
        XCTAssertFalse(try api().billingOffer().sells(.personal))
    }

    /// The box and two boxes come from the quote; text that cannot be shown that way offers no checkout.
    func testCheckoutTermsSplitTheConsentIntoTwoBoxes() {
        func quote(_ terms: [String], _ consent: String) -> ParaAirCloudBillingOffer.Quote {
            .init(plan: .personal, interval: .month, seats: 1, extraStorageTb: 0, amountCents: 1000, currency: "USD", terms: terms, consent: consent)
        }
        let terms = ParaAirCloudCheckoutTerms(quote(["Heading", "$10.00 per month plus tax.", "- One", "- Two"],
                                                    "I agree that my plan renews at $10.00 per month plus tax until I cancel. I agree to the [Terms](https://x.example/t)."))
        XCTAssertEqual(terms?.bullets, ["One", "Two"])
        XCTAssertEqual(terms?.renewalConsent, "I agree that my plan renews at $10.00 per month plus tax until I cancel.")
        XCTAssertEqual(terms?.documentsConsent, "I agree to the [Terms](https://x.example/t).")
        XCTAssertNil(ParaAirCloudCheckoutTerms(quote(["Heading", "Price", "One"], "I agree to renew. I agree to the Terms.")), "bullets need their prefix")
        XCTAssertNil(ParaAirCloudCheckoutTerms(quote(["Heading", "Price", "- One"], "I agree to renew and to the Terms.")), "two boxes need two sentences")
        XCTAssertNil(ParaAirCloudCheckoutTerms(quote(["Heading", "Price", "- One"], "You agree. I agree to the Terms.")))
    }

    // MARK: Catalog

    func testCatalogLimitsAndFormatting() {
        let catalog = ParaAirCloudBillingCatalog.self
        XCTAssertEqual(catalog.formatUSD(cents: 1_000), "$10.00")
        XCTAssertEqual(catalog.formatUSD(cents: 5), "$0.05")
        XCTAssertEqual(catalog.formatUSD(cents: 160_000), "$1,600.00")
        XCTAssertEqual(catalog.formatUSD(cents: 123_456_789), "$1,234,567.89")
        XCTAssertEqual(catalog.formatShortUSD(cents: 160_000), "$1,600")
        XCTAssertEqual(catalog.formatShortUSD(cents: 1_650), "$16.50")
        let euro = ParaAirCloudBillingOffer(provider: .paddle, merchant: .init(name: "Paddle", reseller: true), disclosureVersion: "v1",
                                            currency: "EUR", prices: [])
        XCTAssertEqual(euro.format(cents: 1_000), "10.00 EUR")
        XCTAssertEqual(euro.format(cents: 1_000, short: true), "10 EUR")
    }

    /// The fake service's catalog stands in for the service's; when its source sits beside the package (the integrated
    /// tree), or `PARAAIR_CLOUD_SOURCE` names a service checkout's `cloud` folder, the fake and the request limits must
    /// match it. The app itself keeps no prices.
    func testFakeCatalogMatchesTheServiceCatalog() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cloud = ProcessInfo.processInfo.environment["PARAAIR_CLOUD_SOURCE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? packageRoot.appendingPathComponent("cloud", isDirectory: true)
        let file = cloud.appendingPathComponent("src/billing/catalog.ts")
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("cloud/src/billing/catalog.ts is absent; this check is mandatory after integration")
        }
        let pattern = try NSRegularExpression(pattern: #"\b([a-z]+_(?:month|year)): \{[^}]*unitAmountCents: ([0-9_]+)"#)
        var amounts: [String: Int] = [:]
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let id = String(source[Range(match.range(at: 1), in: source)!])
            amounts[id] = Int(source[Range(match.range(at: 2), in: source)!].replacingOccurrences(of: "_", with: ""))
        }
        XCTAssertEqual(amounts, FakeParaAirCloud.catalog)
        XCTAssertTrue(source.contains("MAX_SEATS = \(ParaAirCloudBillingCatalog.maxSeats);"))
        XCTAssertTrue(source.contains("MAX_STORAGE_TB = \(ParaAirCloudBillingCatalog.maxStorageTb);"))
        let disclosure = try String(contentsOf: cloud.appendingPathComponent("src/billing/disclosure.ts"), encoding: .utf8)
        XCTAssertTrue(disclosure.contains("export const DISCLOSURE_VERSION = \"\(FakeParaAirCloud().disclosureVersion)\";"))
    }
}
