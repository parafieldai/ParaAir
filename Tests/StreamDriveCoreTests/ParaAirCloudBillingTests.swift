import XCTest
import Darwin
@testable import StreamDriveCore

/// Billing on the client: the `/v1/me` billing object, the browser-link host policy, checkout and portal calls
/// against the fake service, the mirrored plan catalog and the checkout disclosure text.
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
            valid.replacingOccurrences(of: #""seats":1"#, with: #""seats":0"#),
            valid.replacingOccurrences(of: #""seats":1"#, with: #""seats":1001"#),
            valid.replacingOccurrences(of: #""extraStorageTb":0"#, with: #""extraStorageTb":101"#),
            valid.replacingOccurrences(of: #""plan":"personal""#, with: #""plan":null"#),
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
        expectBillingError(EBUSY, "This workspace already has a paid plan. Use Manage Plan to change it") {
            _ = try api().billingCheckout(ParaAirCloudCheckoutRequest(workspaceID: account.workspaceID, plan: .personal, interval: .month))
        }
        fake.setStatus(workspaceID: account.workspaceID, "suspended")
        expectBillingError(EACCES, "This ParaAir Cloud workspace is suspended") { _ = try api().billingPortal(workspaceID: account.workspaceID) }
        fake.setStatus(workspaceID: account.workspaceID, "active")

        fake.sellablePlans = ["personal"]
        expectBillingError(EIO, "Payments can’t be reached right now. Try again in a few minutes") {
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

    // MARK: Catalog

    func testCatalogAmounts() {
        let catalog = ParaAirCloudBillingCatalog.self
        XCTAssertEqual(catalog.unitAmountCents(.personal, .month), 1_000)
        XCTAssertEqual(catalog.unitAmountCents(.personal, .year), 10_000)
        XCTAssertEqual(catalog.unitAmountCents(.team, .month), 1_600)
        XCTAssertEqual(catalog.unitAmountCents(.team, .year), 16_000)
        XCTAssertEqual(catalog.storageUnitAmountCents(.month), 1_000)
        XCTAssertEqual(catalog.storageUnitAmountCents(.year), 12_000)
        XCTAssertEqual(catalog.amountCents(plan: .team, interval: .year, seats: 3, storageTb: 2), 72_000)
        XCTAssertEqual(catalog.amountCents(plan: .personal, interval: .month, seats: 9, storageTb: 1), 2_000, "Personal is one seat")
        XCTAssertEqual(catalog.yearlySavingsCents(.personal), 2_000)
        XCTAssertEqual(catalog.yearlySavingsCents(.team), 3_200)
        XCTAssertEqual(catalog.formatUSD(cents: 1_000), "$10.00")
        XCTAssertEqual(catalog.formatUSD(cents: 5), "$0.05")
        XCTAssertEqual(catalog.formatUSD(cents: 160_000), "$1,600.00")
        XCTAssertEqual(catalog.formatUSD(cents: 123_456_789), "$1,234,567.89")
        XCTAssertEqual(catalog.formatShortUSD(cents: 160_000), "$1,600")
        XCTAssertEqual(catalog.formatShortUSD(cents: 1_650), "$16.50")
    }

    /// The service's catalog is the source of truth; when its source sits beside the package (the integrated tree),
    /// or `PARAAIR_CLOUD_SOURCE` names a service checkout's `cloud` folder, every amount here must match it.
    func testCatalogMatchesTheServiceCatalog() throws {
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
        XCTAssertEqual(amounts, ParaAirCloudBillingCatalog.unitAmounts)
        XCTAssertTrue(source.contains("MAX_SEATS = \(ParaAirCloudBillingCatalog.maxSeats);"))
        XCTAssertTrue(source.contains("MAX_STORAGE_TB = \(ParaAirCloudBillingCatalog.maxStorageTb);"))
    }

    // MARK: Disclosure

    func testPersonalDisclosureFollowsAppendixA1() throws {
        let now = try XCTUnwrap(ParaAirCloudJSON.parseDate("2026-10-12T23:30:00Z"))
        let paddle = ParaAirCloudCheckoutDisclosure.make(plan: .personal, interval: .month, seats: 1, storageTb: 0, now: now, seller: .paddle)
        XCTAssertEqual(paddle.heading, "ParaAir Cloud Personal, billed monthly")
        XCTAssertEqual(paddle.priceLine, "$10.00 per month plus tax. Renews automatically every month until you cancel.")
        XCTAssertEqual(paddle.bullets, [
            "Today you pay $10.00 plus any tax, which is shown before you pay.",
            "Then Paddle, our reseller, charges $10.00 plus tax on the 12th of every month.",
            "Includes 1 TB of storage and up to 3 TB of full-speed transfer each month. No overage charges.",
            "Cancel any time online in the ParaAir app (Storage Settings > ParaAir Cloud > Manage Plan). Cancel before your renewal date to avoid the next charge. You keep access until the end of the month you paid for.",
            "Full refund if you ask within 14 days of this first payment.",
            "We will email you at least 14 days before any price change, and you can cancel first.",
        ])
        XCTAssertEqual(paddle.renewalConsent, "I agree that my ParaAir Cloud Personal plan renews automatically at $10.00 per month plus tax until I cancel.")
        XCTAssertEqual(paddle.documentsConsent, "I agree to the Terms of Service and the Subscription, Cancellation and Refund Policy.")
        let stripe = ParaAirCloudCheckoutDisclosure.make(plan: .personal, interval: .year, seats: 1, storageTb: 2, now: now, seller: .stripe)
        XCTAssertTrue(stripe.bullets.contains("Then we charge $340.00 plus tax every year on October 12."), "\(stripe.bullets)")
        XCTAssertTrue(stripe.bullets.contains("This includes 2 TB of added storage at $120.00 per TB per year plus tax."))
        XCTAssertTrue(stripe.bullets.contains("Includes 3 TB of storage and up to 9 TB of full-speed transfer each month. No overage charges."))
        XCTAssertTrue(stripe.bullets.contains("We will email you 25 to 30 days before each yearly renewal."))
        XCTAssertTrue(stripe.bullets.contains("Full refund if you ask within 14 days of this first payment or within 14 days of any yearly renewal charge."))
        let copy = ([stripe.heading, stripe.priceLine, stripe.renewalConsent, stripe.documentsConsent] + stripe.bullets).joined()
        XCTAssertFalse(copy.contains("\u{2014}"), "no em dashes")
        XCTAssertFalse(copy.contains("Paddle"))
    }

    func testTeamDisclosureFollowsAppendixA4() throws {
        let now = try XCTUnwrap(ParaAirCloudJSON.parseDate("2027-03-01T08:00:00Z"))
        let team = ParaAirCloudCheckoutDisclosure.make(plan: .team, interval: .year, seats: 3, storageTb: 0, now: now, seller: .paddle)
        XCTAssertEqual(team.heading, "ParaAir Cloud Team, billed yearly")
        XCTAssertEqual(team.priceLine, "$160.00 per member per year plus tax. Renews automatically every year until you cancel.")
        XCTAssertEqual(Array(team.bullets.prefix(3)), [
            "You are buying 3 member seats: $480.00 per year plus tax.",
            "Today you pay $480.00 plus any tax, which is shown before you pay.",
            "Then Paddle, our reseller, charges for the current number of members, at $160.00 per member plus tax, every year on March 1.",
        ])
        XCTAssertTrue(team.bullets.contains("We will email the owner and billing admins 25 to 30 days before each yearly renewal."))
        XCTAssertEqual(team.renewalConsent,
                       "I agree that this ParaAir Cloud Team plan renews automatically at $160.00 per member per year plus tax, for the number of members at each renewal, until I cancel.")
        XCTAssertEqual(team.documentsConsent,
                       "I agree to the Terms of Service and the Subscription, Cancellation and Refund Policy, and I am authorized to agree for this team.")
        let ordinals = [1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 11: "11th", 12: "12th", 13: "13th", 21: "21st", 22: "22nd", 23: "23rd", 31: "31st"]
        for (day, text) in ordinals { XCTAssertEqual(ParaAirCloudCheckoutDisclosure.ordinal(day), text) }
    }
}
