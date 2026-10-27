import Foundation
import CryptoKit
import XCTest
@testable import StreamDriveCore

/// Routes `https://<id>.cloud.invalid` requests to the matching in-memory fake.
/// Bodies arrive as `httpBodyStream` once a request passes through URLSession.
final class CloudProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: WeakFake] = [:]
    private final class WeakFake { weak var value: FakeParaAirCloud? }
    private var stopped = false

    static func register(_ fake: FakeParaAirCloud) {
        lock.lock(); defer { lock.unlock() }
        let box = WeakFake(); box.value = fake; servers[fake.host] = box
    }
    static func unregister(_ host: String) { lock.lock(); servers[host] = nil; lock.unlock() }
    private static func server(_ host: String?) -> FakeParaAirCloud? {
        lock.lock(); defer { lock.unlock() }
        return host.flatMap { servers[$0]?.value }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".cloud.invalid") ?? false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        // Answer from a background queue so slow or hung routes never block other
        // requests, then deliver on the loading thread as URLProtocol requires.
        let thread = Thread.current, modes = [RunLoop.current.currentMode ?? .default].map(\.rawValue)
        let request = self.request
        DispatchQueue.global().async {
            let outcome: FakeParaAirCloud.Outcome = Self.server(request.url?.host)?.handle(request, body: body) ?? .transport(.cannotFindHost)
            if case .hang = outcome { return }
            self.perform(#selector(self.deliver(_:)), on: thread, with: OutcomeBox(outcome), waitUntilDone: false, modes: modes)
        }
    }

    private final class OutcomeBox: NSObject { let value: FakeParaAirCloud.Outcome; init(_ value: FakeParaAirCloud.Outcome) { self.value = value } }

    @objc private func deliver(_ box: OutcomeBox) {
        guard !stopped else { return }
        switch box.value {
        case .hang:
            return
        case .transport(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .redirect(let location):
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .reply(let reply):
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stopped = true }
}

/// An in-memory implementation of the ParaAir Cloud API v1 (spec section 2 and the
/// commit and mutation rules of 4.5–4.6), with fault injection and a request log.
final class FakeParaAirCloud: @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body = Data() }
    enum Outcome { case reply(Reply), transport(URLError.Code), hang, redirect(String) }
    struct LoggedRequest {
        let method: String
        let route: String
        let path: String
        let rawQuery: String?
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        var bearer: String? { headers["authorization"].map { String($0.dropFirst("Bearer ".count)) } }
    }
    struct Account { let userID: String; let workspaceID: String; let driveID: String; let email: String }

    let host = UUID().uuidString.lowercased() + ".cloud.invalid"
    var issuer: URL { URL(string: "https://" + host)! }
    var issuerString: String { "https://" + host }
    /// One configuration object, so ParaAir Cloud sessions are shared like `EngineOpenDependencies.live`.
    let configuration: URLSessionConfiguration
    let adminToken = "admin-" + UUID().uuidString
    let chunkSize: Int
    var accessTokenTTL: TimeInterval = 3600
    var readTokenTTL: TimeInterval = 300
    /// The service's clock minus this Mac's: read-token expiry and every reply's `Date` header use it.
    var clockOffset: TimeInterval = 0
    var retentionDays = 30
    /// The service's `BILLING_PROVIDER`: "none" (billing off), "stripe" or "paddle".
    var billingProvider = "none"
    /// Paddle's sandbox (`PADDLE_ENVIRONMENT=sandbox`): portal links use the sandbox host.
    var paddleSandbox = false
    /// A service from before billing: `/v1/me` has no `billing` objects.
    var omitsBilling = false
    /// Plans with configured prices; checkout for any other plan is 503 `billing_unavailable`, as with a partial price
    /// map, and the offer lists only these plans.
    var sellablePlans: Set<String> = ["personal", "team"]
    /// False: billing is set up without what checkout needs (keys, prices, notice settings): 503 `billing_unavailable`.
    var billingConfigured = true
    /// The service's `DISCLOSURE_VERSION`; a checkout naming another is 409 `disclosure_outdated`.
    var disclosureVersion = "A-draft-2026-10-27b"
    /// `BILLING_TRIAL_DAYS` on Stripe: the free trial a workspace's first checkout starts with, once per user (0: none).
    var trialDays = 0
    /// `STRIPE_MANAGED_PAYMENTS`: Link (Stripe Managed Payments) is the merchant of record instead of Parafield Inc.
    var stripeManaged = false
    /// Prices the offer lists instead of the catalog's (the server's catalog after a price change).
    var priceOverrides: [String: Int] = [:]
    /// An earlier checkout of the workspace was paid but its subscription has not arrived: a new checkout is 409 `busy`.
    var paidUnboundCheckouts: Set<String> = []
    /// Replaces the URL a checkout or portal reply carries (to test the client's host policy).
    var checkoutURLOverride: String?
    var portalURLOverride: String?

    private let lock = NSRecursiveLock()
    private var nextID: Int64 = 1
    private var faults: [Fault] = []
    private var log: [LoggedRequest] = []
    private var delays: [String: TimeInterval] = [:]
    private var inFlight: [String: Int] = [:]
    private var peak: [String: Int] = [:]
    private var users: [String: User] = [:]                 // by usr_ id
    private var workspaces: [String: Workspace] = [:]       // by ws_ id
    private var drives: [String: Drive] = [:]               // by drive id
    private var nodes: [Int64: Node] = [:]
    private var versions: [Int64: Version] = [:]
    private var chunks: [String: [String: Data]] = [:]      // workspace → sha → bytes
    private var uploads: [String: Upload] = [:]
    private var fences: Set<String> = []
    private var grants: [String: Grant] = [:]
    private var accessTokens: [String: (grant: String, expires: Date)] = [:]
    private var refreshTokens: [String: RefreshRow] = [:]
    private var readTokens: [String: (workspace: String, expires: Date, grant: String)] = [:]
    private var idempotency: [String: (hash: String, reply: Reply)] = [:]
    private var invites: Set<String> = []
    private var authRequests: [String: AuthRequest] = [:]
    private var authCodes: [String: AuthCode] = [:]
    private(set) var outbox: [(to: String, code: String, createdAt: Date)] = []
    private var billingSessions: [String: [Date]] = [:]
    /// Users who started a free trial (the service counts trial checkouts that bound a subscription; this fake, checkouts).
    private var trialledUsers: Set<String> = []
    /// Accepted checkout bodies, in order.
    private(set) var checkouts: [[String: Any]] = []
    /// Checkout URLs a later checkout of the same workspace made unpayable (Stripe expires them, Paddle cancels them).
    private(set) var closedCheckoutURLs: [String] = []
    private var openCheckouts: [String: [String]] = [:]

    /// A workspace's subscription as the service's `billing_accounts` row would describe it.
    struct BillingAccount {
        var provider = "stripe"
        var state = "active"
        var plan = "personal"
        var interval = "month"
        var quantity = 1
        var storageTb = 0
        var periodEnd: Date? = Date(timeIntervalSince1970: 1_823_040_000)
        var cancelAtPeriodEnd = false
        var graceEndsAt: Date?
        var readOnlyAt: Date?
        var deletionAt: Date?
        var hasCustomer = true
        /// In the free trial: when it ends (the service's `trial_end` while the processor says trialing).
        var trialEndsAt: Date?
    }

    private struct Fault { var route: String; var remaining: Int; var action: FaultAction }
    private enum FaultAction { case error(status: Int, code: String, retryAfter: Int?, missing: [String]?), transport(URLError.Code, after: Bool), hang, redirect(String), raw(Reply) }
    private struct User { let id: String; let email: String; let createdAt: Date; var disabled = false }
    private struct Workspace {
        let id: String; var name: String; var members: [String: String]; var status = "active"; var kind = "personal"
        var billing: BillingAccount?
        var quotaOverride: Int64?; var logical: Int64 = 0; var retained: Int64 = 0; var reserved: Int64 = 0
        var nodeCount = 0; var maxNodes = 1_000_000; var bytesIn: Int64 = 0; var bytesOut: Int64 = 0; var maxDrives = 10
        var quota: Int64 { quotaOverride ?? 1_000_000_000_000 }
    }
    private struct Drive { let id: String; let workspace: String; var name: String; let createdAt: Date; let root: Int64 }
    private struct Node {
        let id: Int64; let drive: String; var path: String; var kind: NodeKind; var size: Int64 = 0
        var mtimeUs: Int64; var mode: UInt32; var head: Int64?; var deletedAt: Date?
    }
    private struct Version {
        let id: Int64; let node: Int64; let drive: String; let transaction: String; let manifestHash: String
        let size: Int64; let mode: UInt32; let chunks: [(sha: String, size: Int)]; var supersededAt: Date?; var expiresAt: Date?
        /// Path at commit time and creation time: a committed-version entry describes them, even after a rename.
        var path: String = ""; var createdUs: Int64 = 0
    }
    private struct Upload {
        let id: String; let drive: String; let transaction: String; let path: String; let expectedVersion: String?
        let finalSize: Int64; let mode: UInt32; let chunks: [(sha: String, size: Int)]; let hash: String
        var reserved: Int64; var expiresAt: Date; var committedVersion: Int64?
        /// A same-manifest reserve revives an expired upload until this time (service: 7 days).
        var hardExpiresAt: Date = Date().addingTimeInterval(7 * 86400)
    }
    private struct Grant { let id: String; let user: String; let createdAt: Date; let expiresAt: Date; var revoked = false }
    private struct RefreshRow { let grant: String; var status: String; var rotatedAt: Date?; let successor: String }
    private struct AuthRequest {
        let id: String; let secret: String; let redirect: String; let state: String; let challenge: String
        var stage: String; var email: String?; var code: String?; var attempts = 0; var user: String?
    }
    private struct AuthCode { let user: String; let challenge: String; let redirect: String; let expires: Date; var used = false; var grant: String? }
    private struct Fail: Error { let code: String; var missing: [String]? = nil; var retryAfter: Int? = nil }

    init(chunkSize: Int = ParaAirCloudConfiguration.chunkSize) {
        self.chunkSize = chunkSize
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudProtocolStub.self]
        configuration.timeoutIntervalForRequest = 10
        self.configuration = configuration
        CloudProtocolStub.register(self)
    }
    deinit { CloudProtocolStub.unregister(host) }

    // MARK: Test controls

    func inject(route: String, status: Int, code: String, times: Int = 1, retryAfter: Int? = nil, missing: [String]? = nil) {
        locked { faults.append(Fault(route: route, remaining: times, action: .error(status: status, code: code, retryAfter: retryAfter, missing: missing))) }
    }
    /// `afterProcessing`: the request takes effect, then the reply is lost.
    func injectTransport(_ code: URLError.Code, route: String, times: Int = 1, afterProcessing: Bool = false) {
        locked { faults.append(Fault(route: route, remaining: times, action: .transport(code, after: afterProcessing))) }
    }
    func hang(route: String, times: Int = 1) { locked { faults.append(Fault(route: route, remaining: times, action: .hang)) } }
    func injectRedirect(route: String, to location: String, times: Int = 1) {
        locked { faults.append(Fault(route: route, remaining: times, action: .redirect(location))) }
    }
    func injectRaw(route: String, status: Int, body: Data, headers: [String: String] = [:], times: Int = 1) {
        locked { faults.append(Fault(route: route, remaining: times, action: .raw(Reply(status: status, headers: headers, body: body)))) }
    }
    /// Every request on `route` waits this long before it is answered (outside the fake's lock).
    func delay(route: String, seconds: TimeInterval) { locked { delays[route] = seconds } }
    /// The most requests on `route` that were in progress at once.
    func maxInFlight(_ route: String) -> Int { locked { peak[route] ?? 0 } }
    var requests: [LoggedRequest] { locked { log } }
    func requests(_ route: String) -> [LoggedRequest] { locked { log.filter { $0.route == route } } }
    func clearLog() { locked { log = [] } }

    func invite(_ email: String) { locked { _ = invites.insert(email.lowercased()) } }

    /// A user with a personal workspace and its "ParaAir Cloud" drive.
    @discardableResult
    func createAccount(email: String = "user-\(UUID().uuidString.prefix(8))@example.test") -> Account {
        locked {
            let user = User(id: "usr_" + Self.base32(), email: email.lowercased(), createdAt: Date())
            users[user.id] = user
            let workspace = Workspace(id: "ws_" + Self.base32(), name: "Personal", members: [user.id: "owner"])
            workspaces[workspace.id] = workspace
            let drive = makeDrive(workspace: workspace.id, name: "ParaAir Cloud")
            return Account(userID: user.id, workspaceID: workspace.id, driveID: drive.id, email: user.email)
        }
    }

    /// Issues a grant and tokens directly, as a completed sign-in would.
    func issueTokens(for account: Account, accessTTL: TimeInterval? = nil) -> OAuthTokens {
        locked {
            let grant = Grant(id: "grt_" + Self.base32(), user: account.userID, createdAt: Date(), expiresAt: Date().addingTimeInterval(180 * 86400))
            grants[grant.id] = grant
            let (access, refresh, ttl) = mint(grant: grant.id, accessTTL: accessTTL)
            return OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(ttl), scope: "drive offline_access")
        }
    }

    func expireAccessTokens() { locked { for key in accessTokens.keys { accessTokens[key]!.expires = Date(timeIntervalSince1970: 0) } } }
    func expireReadTokens() { locked { for key in readTokens.keys { readTokens[key]!.expires = Date(timeIntervalSince1970: 0) } } }
    func revokeRefreshTokens() { locked { for key in refreshTokens.keys { refreshTokens[key]!.status = "revoked" } } }
    func setQuotaOverride(workspaceID: String, bytes: Int64?) { locked { workspaces[workspaceID]?.quotaOverride = bytes } }
    func setStatus(workspaceID: String, _ status: String) { locked { workspaces[workspaceID]?.status = status } }
    func usedBytes(workspaceID: String) -> Int64 { locked { workspaces[workspaceID]?.logical ?? 0 } }
    func reservedBytes(workspaceID: String) -> Int64 { locked { workspaces[workspaceID]?.reserved ?? 0 } }
    func bytesIn(workspaceID: String) -> Int64 { locked { workspaces[workspaceID]?.bytesIn ?? 0 } }
    func storedChunkCount(workspaceID: String) -> Int { locked { chunks[workspaceID]?.count ?? 0 } }
    func expireUploads() { locked { for key in uploads.keys { uploads[key]!.expiresAt = Date(timeIntervalSince1970: 0) } } }
    func dropChunk(workspaceID: String, sha256: String) { locked { chunks[workspaceID]?[sha256] = nil } }
    func isFenced(driveID: String, transactionID: String) -> Bool { locked { fences.contains(driveID + "|" + transactionID.lowercased()) } }
    func liveDriveCount(workspaceID: String) -> Int { locked { drives.values.filter { $0.workspace == workspaceID }.count } }

    /// A team workspace owned by `owner`, with no drive.
    @discardableResult
    func createTeamWorkspace(owner: Account, name: String = "Studio") -> String {
        locked {
            var workspace = Workspace(id: "ws_" + Self.base32(), name: name, members: [owner.userID: "owner"])
            workspace.kind = "team"
            workspaces[workspace.id] = workspace
            return workspace.id
        }
    }
    func addMember(workspaceID: String, userID: String, role: String) { locked { workspaces[workspaceID]?.members[userID] = role } }
    func setBilling(workspaceID: String, _ account: BillingAccount?) { locked { workspaces[workspaceID]?.billing = account } }

    /// The head content of a live file, assembled from its chunks.
    func contents(driveID: String, path: String) -> Data? {
        locked {
            guard let node = live(driveID, path), node.kind == .file, let head = node.head, let version = versions[head],
                  let workspace = drives[driveID]?.workspace else { return nil }
            return version.chunks.reduce(into: Data()) { $0 += chunks[workspace]?[$1.sha] ?? Data() }
        }
    }

    /// Publishes a file directly (as another device would) and returns its entry.
    @discardableResult
    func seedFile(driveID: String, path: String, data: Data, mode: UInt32 = 0o644) -> FileEntry {
        locked {
            let drive = drives[driveID]!
            var refs: [(String, Int)] = []
            var offset = 0
            while offset < data.count {
                let piece = data[offset..<min(offset + chunkSize, data.count)]
                let sha = Self.hex(Data(piece))
                chunks[drive.workspace, default: [:]][sha] = Data(piece)
                refs.append((sha, piece.count)); offset += piece.count
            }
            let existing = live(driveID, path)
            let nodeID: Int64
            if let existing {
                nodeID = existing.id
                if let head = existing.head { versions[head]?.supersededAt = Date(); versions[head]?.expiresAt = Date().addingTimeInterval(TimeInterval(retentionDays) * 86400) }
                workspaces[drive.workspace]!.logical += Int64(data.count) - existing.size
                workspaces[drive.workspace]!.retained += existing.size
            } else {
                nodeID = makeID()
                nodes[nodeID] = Node(id: nodeID, drive: driveID, path: path, kind: .file, mtimeUs: Self.nowUs(), mode: mode, head: nil, deletedAt: nil)
                workspaces[drive.workspace]!.logical += Int64(data.count); workspaces[drive.workspace]!.nodeCount += 1
            }
            let version = Version(id: makeID(), node: nodeID, drive: driveID, transaction: UUID().uuidString.lowercased(), manifestHash: "",
                                  size: Int64(data.count), mode: mode, chunks: refs, supersededAt: nil, expiresAt: nil,
                                  path: path, createdUs: Self.nowUs())
            versions[version.id] = version
            nodes[nodeID]!.head = version.id; nodes[nodeID]!.size = Int64(data.count); nodes[nodeID]!.mtimeUs = Self.nowUs(); nodes[nodeID]!.mode = mode
            return fileEntry(nodes[nodeID]!)
        }
    }

    @discardableResult
    func seedDirectory(driveID: String, path: String) -> FileEntry {
        locked {
            let id = makeID()
            nodes[id] = Node(id: id, drive: driveID, path: path, kind: .directory, mtimeUs: Self.nowUs(), mode: 0o755, head: nil, deletedAt: nil)
            workspaces[drives[driveID]!.workspace]!.nodeCount += 1
            return fileEntry(nodes[id]!)
        }
    }

    // MARK: Dispatch

    func handle(_ request: URLRequest, body: Data) -> Outcome {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        let query = Self.parseQuery(url.query(percentEncoded: true))
        var headers: [String: String] = [:]
        for (key, value) in request.allHTTPHeaderFields ?? [:] { headers[key.lowercased()] = value }
        let route = Self.route(method: method, path: path)
        lock.lock()
        log.append(LoggedRequest(method: method, route: route, path: path, rawQuery: url.query(percentEncoded: true), query: query ?? [:],
                                 headers: headers, body: body))
        let wait = delays[route]
        inFlight[route, default: 0] += 1; peak[route] = max(peak[route] ?? 0, inFlight[route]!)
        lock.unlock()
        if let wait { Thread.sleep(forTimeInterval: wait) }
        lock.lock()
        inFlight[route, default: 1] -= 1
        var fault: FaultAction?
        if let index = faults.firstIndex(where: { $0.route == route && $0.remaining > 0 }) {
            fault = faults[index].action; faults[index].remaining -= 1
            if faults[index].remaining == 0 { faults.remove(at: index) }
        }
        lock.unlock()
        switch fault {
        case .error(let status, let code, let retryAfter, let missing)?:
            return .reply(dated(errorReply(status: status, code: code, retryAfter: retryAfter, missing: missing)))
        case .transport(let code, let after)?:
            if after { _ = dispatch(method: method, path: path, query: query, headers: headers, body: body) }
            return .transport(code)
        case .hang?: return .hang
        case .redirect(let location)?: return .redirect(location)
        case .raw(let reply)?: return .reply(reply)
        case nil: return .reply(dated(dispatch(method: method, path: path, query: query, headers: headers, body: body)))
        }
    }

    private func dispatch(method: String, path: String, query: [String: String]?, headers: [String: String], body: Data) -> Reply {
        lock.lock(); defer { lock.unlock() }
        do {
            guard let query else { throw Fail(code: "invalid_request") }
            let parts = path.split(separator: "/").map(String.init)
            let route = Self.route(method: method, path: path)
            switch route {
            case "GET /v1/health":
                return json(200, ["ok": true, "apiVersion": 1, "minClientVersion": "0.1.0"])
            case "POST /oauth/token": return token(Self.form(body))
            case "POST /oauth/revoke": return revoke(Self.form(body))
            case "GET /oauth/authorize": return authorize(query)
            case "POST /oauth/authorize/email": return authorizeEmail(Self.form(body), headers)
            case "POST /oauth/authorize/verify": return authorizeVerify(Self.form(body), headers)
            case "POST /oauth/authorize/consent": return authorizeConsent(Self.form(body), headers)
            case "GET /__dev/outbox":
                guard headers["authorization"] == "Bearer " + adminToken else { return Reply(status: 404) }
                guard let raw = query["email"], !raw.isEmpty else { throw Fail(code: "invalid_request") }
                let email = raw.lowercased()
                let messages = outbox.filter { $0.to == email }.reversed().map {
                    ["to": $0.to, "subject": "Your ParaAir Cloud code", "code": $0.code, "createdAt": Self.date($0.createdAt)]
                }
                return json(200, ["messages": messages])
            case "GET /v1/w/{w}/chunks/{sha}":
                try checkClient(headers)
                return try chunkGet(workspace: parts[2], sha: parts[4], headers: headers)
            default: break
            }
            guard parts.count >= 2, parts[0] == "v1" else { throw Fail(code: "not_found") }
            try checkClient(headers)
            let user = try authenticate(headers)
            return try authorizedRoute(route: route, parts: parts, query: query, headers: headers, body: body, user: user)
        } catch let fail as Fail {
            return errorReply(status: ParaAirCloudErrorCode(rawValue: fail.code)?.httpStatus ?? 400, code: fail.code,
                              retryAfter: fail.retryAfter, missing: fail.missing)
        } catch {
            return errorReply(status: 500, code: "internal", retryAfter: nil, missing: nil)
        }
    }

    /// `mac/<major[.minor[.patch]]>` or `mac/dev` (this fake is a dev-mode service). The client always sends
    /// the header, so the fake also requires it; the service allows it to be absent.
    private func checkClient(_ headers: [String: String]) throws {
        guard let client = headers["x-paraair-client"] else { throw Fail(code: "client_too_old") }
        guard client == "mac/dev" || client.range(of: "^mac/[0-9]{1,6}(\\.[0-9]{1,6}){0,2}$", options: .regularExpression) != nil else {
            throw Fail(code: "invalid_request")
        }
    }

    private func authorizedRoute(route: String, parts: [String], query: [String: String], headers: [String: String], body: Data,
                                 user: (id: String, grant: String)) throws -> Reply {
        switch route {
        case "GET /v1/me": return me(user)
        case "POST /v1/billing/checkout": return try billingCheckout(user: user.id, body: body, headers: headers)
        case "POST /v1/billing/portal": return try billingPortal(user: user.id, body: body, headers: headers)
        case "GET /v1/billing/offer": return try billingOffer(query, user: user.id)
        case "DELETE /v1/sessions/current":
            grants[user.grant]?.revoked = true
            return Reply(status: 204)
        case "GET /v1/drives":
            let visible = drives.values.filter { workspaces[$0.workspace]?.members[user.id] != nil }.sorted { $0.createdAt < $1.createdAt }
            return json(200, ["drives": visible.map { driveJSON($0, user: user.id) }])
        case "POST /v1/drives":
            let request = try jsonBody(body, headers)
            return try idempotent(scope: "u:" + user.id, headers: headers, body: body, path: "drives") {
                guard let workspaceID = request["workspaceId"] as? String else { throw Fail(code: "workspace_not_found") }
                let name = try Self.driveName(request["name"])
                guard let workspace = workspaces[workspaceID], let role = workspace.members[user.id] else { throw Fail(code: "workspace_not_found") }
                guard workspace.status != "suspended" else { throw Fail(code: "suspended") }
                guard role == "owner" || role == "admin" else { throw Fail(code: "forbidden") }
                guard workspace.status == "active" else { throw Fail(code: "read_only") }
                guard drives.values.filter({ $0.workspace == workspaceID }).count < workspace.maxDrives else { throw Fail(code: "drive_limit") }
                guard !drives.values.contains(where: { $0.workspace == workspaceID && $0.name == name }) else { throw Fail(code: "already_exists") }
                return json(201, ["drive": driveJSON(makeDrive(workspace: workspaceID, name: name), user: user.id)])
            }
        default: break
        }
        guard parts.count >= 3, parts[1] == "drives" else { throw Fail(code: "not_found") }
        let driveID = parts[2]
        guard let drive = drives[driveID], let workspace = workspaces[drive.workspace], let role = workspace.members[user.id] else {
            throw Fail(code: "drive_not_found")
        }
        guard workspace.status != "suspended" else { throw Fail(code: "suspended") }
        func writable() throws {
            guard role != "viewer" else { throw Fail(code: "forbidden") }
            guard workspace.status == "active" else { throw Fail(code: "read_only") }
        }
        let item = parts.count > 4 ? parts[4] : ""
        switch route {
        case "GET /v1/drives/{d}":
            return json(200, ["drive": driveJSON(drive, user: user.id), "capacity": capacityJSON(drive.workspace), "limits": [
                "chunkSize": chunkSize, "maxFileBytes": 274_877_906_944, "maxManifestChunks": 65536, "maxListPage": 5000,
                "maxMoveDescendants": 10000, "readTokenSeconds": Int(readTokenTTL)]])
        case "GET /v1/drives/{d}/stat":
            let path = try serverPath(query["path"])
            guard let node = live(driveID, path) else { throw Fail(code: "not_found") }
            return json(200, ["entry": entryJSON(node)])
        case "GET /v1/drives/{d}/list":
            return try list(drive, query)
        case "POST /v1/drives/{d}/mkdir":
            try writable()
            let request = try jsonBody(body, headers)
            return try idempotent(scope: "d:" + driveID, headers: headers, body: body, path: "mkdir") {
                let path = try serverPath(request["path"] as? String)
                guard path != "/" else { throw Fail(code: "already_exists") }
                let parent = try parentDirectory(driveID, path, missing: "parent_not_found")
                _ = parent
                guard workspaces[drive.workspace]!.nodeCount + 1 <= workspace.maxNodes else { throw Fail(code: "node_limit") }
                guard live(driveID, path) == nil, !nfcSiblingExists(driveID, path) else { throw Fail(code: "already_exists") }
                let id = makeID()
                nodes[id] = Node(id: id, drive: driveID, path: path, kind: .directory, mtimeUs: Self.nowUs(), mode: 0o755, head: nil, deletedAt: nil)
                workspaces[drive.workspace]!.nodeCount += 1
                return json(201, ["entry": entryJSON(nodes[id]!)])
            }
        case "POST /v1/drives/{d}/move":
            try writable()
            let request = try jsonBody(body, headers)
            return try idempotent(scope: "d:" + driveID, headers: headers, body: body, path: "move") {
                try move(drive, from: try serverPath(request["from"] as? String), to: try serverPath(request["to"] as? String))
            }
        case "POST /v1/drives/{d}/remove":
            try writable()
            let request = try jsonBody(body, headers)
            return try idempotent(scope: "d:" + driveID, headers: headers, body: body, path: "remove") {
                try remove(drive, path: try serverPath(request["path"] as? String), directory: request["directory"] as? Bool ?? false)
            }
        case "GET /v1/drives/{d}/manifest":
            return try manifest(drive, query, grant: user.grant)
        case "POST /v1/drives/{d}/read-token":
            let (token, expires) = mintReadToken(drive.workspace, grant: user.grant)
            return json(200, ["workspaceId": drive.workspace, "readToken": token, "expiresAt": Self.date(expires)])
        case "POST /v1/drives/{d}/uploads":
            guard role != "viewer" else { throw Fail(code: "forbidden") }
            return try reserve(drive, try jsonBody(body, headers))
        case "PUT /v1/drives/{d}/chunks/{sha}":
            try writable()
            return try putChunk(drive, sha: item, upload: query["upload"], body: body)
        case "POST /v1/drives/{d}/uploads/{u}/commit":
            guard role != "viewer" else { throw Fail(code: "forbidden") }
            return try commit(drive, uploadID: item)
        case "POST /v1/drives/{d}/transactions/{tx}/fence":
            guard role != "viewer" else { throw Fail(code: "forbidden") }
            guard let uuid = UUID(uuidString: item) else { throw Fail(code: "invalid_request") }
            let tx = uuid.uuidString.lowercased()
            if let version = versions.values.first(where: { $0.drive == driveID && $0.transaction == tx }) {
                return json(200, ["state": "committed", "entry": versionEntry(version)])
            }
            fences.insert(driveID + "|" + tx)
            for (id, upload) in uploads where upload.drive == driveID && upload.transaction == tx && upload.committedVersion == nil {
                workspaces[drive.workspace]!.reserved -= upload.reserved; uploads[id] = nil
            }
            return json(200, ["state": "fenced"])
        case "GET /v1/drives/{d}/trash":
            return try trash(drive, query)
        case "POST /v1/drives/{d}/trash/{n}/restore":
            try writable()
            let request = try jsonBody(body, headers)
            return try idempotent(scope: "d:" + driveID, headers: headers, body: body, path: "restore/" + item) {
                try restore(drive, nodeID: Int64(item) ?? -1, to: request["to"] as? String)
            }
        default:
            throw Fail(code: "not_found")
        }
    }

    // MARK: OAuth

    private func mint(grant: String, accessTTL: TimeInterval? = nil) -> (String, String, TimeInterval) {
        let ttl = accessTTL ?? accessTokenTTL
        let access = "pca_" + Self.token43()
        accessTokens[access] = (grant, Date().addingTimeInterval(ttl))
        let refresh = "pcr_" + Self.token43()
        refreshTokens[refresh] = RefreshRow(grant: grant, status: "active", rotatedAt: nil, successor: Self.successor(refresh))
        return (access, refresh, ttl)
    }

    private func tokenReply(access: String, refresh: String) -> Reply {
        var reply = json(200, ["access_token": access, "token_type": "Bearer", "expires_in": Int(accessTokenTTL), "refresh_token": refresh,
                               "scope": "drive offline_access"])
        reply.headers["Pragma"] = "no-cache"
        return reply
    }

    private func oauthError(_ status: Int, _ code: String) -> Reply { json(status, ["error": code, "error_description": "Request rejected."]) }

    private func token(_ form: [String: String]) -> Reply {
        guard form["client_id"] == ParaAirCloudConfiguration.clientID else { return oauthError(401, "invalid_client") }
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], var row = authCodes[code], let verifier = form["code_verifier"],
                  verifier.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil else { return oauthError(400, "invalid_grant") }
            if row.used {
                if let grant = row.grant { revokeGrant(grant) }
                return oauthError(400, "invalid_grant")
            }
            guard row.expires > Date(), row.redirect == form["redirect_uri"],
                  Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8)))) == row.challenge else { return oauthError(400, "invalid_grant") }
            let grant = Grant(id: "grt_" + Self.base32(), user: row.user, createdAt: Date(), expiresAt: Date().addingTimeInterval(180 * 86400))
            grants[grant.id] = grant
            row.used = true; row.grant = grant.id; authCodes[code] = row
            let (access, refresh, _) = mint(grant: grant.id)
            return tokenReply(access: access, refresh: refresh)
        case "refresh_token":
            guard let token = form["refresh_token"], var row = refreshTokens[token], let grant = grants[row.grant], !grant.revoked,
                  grant.expiresAt > Date(), users[grant.user]?.disabled == false else { return oauthError(400, "invalid_grant") }
            let access = "pca_" + Self.token43()
            if row.status == "active" {
                row.status = "rotated"; row.rotatedAt = Date(); refreshTokens[token] = row
                if refreshTokens[row.successor] == nil {
                    refreshTokens[row.successor] = RefreshRow(grant: row.grant, status: "active", rotatedAt: nil, successor: Self.successor(row.successor))
                }
                accessTokens[access] = (row.grant, Date().addingTimeInterval(accessTokenTTL))
                return tokenReply(access: access, refresh: row.successor)
            }
            if row.status == "rotated", refreshTokens[row.successor]?.status == "active",
               let rotated = row.rotatedAt, Date().timeIntervalSince(rotated) <= 86400 {
                accessTokens[access] = (row.grant, Date().addingTimeInterval(accessTokenTTL))
                return tokenReply(access: access, refresh: row.successor)
            }
            revokeGrant(row.grant)
            return oauthError(400, "invalid_grant")
        default:
            return oauthError(400, "unsupported_grant_type")
        }
    }

    private func revokeGrant(_ id: String) {
        grants[id]?.revoked = true
        accessTokens = accessTokens.filter { $0.value.grant != id }
        for key in refreshTokens.keys where refreshTokens[key]!.grant == id { refreshTokens[key]!.status = "revoked" }
    }

    private func revoke(_ form: [String: String]) -> Reply {
        if let token = form["token"] {
            if let row = refreshTokens[token] { revokeGrant(row.grant) }
            else if let row = accessTokens[token] { revokeGrant(row.grant) }
        }
        return json(200, [String: String]())
    }

    private func html(_ body: String, cookie: String? = nil) -> Reply {
        var headers = ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Frame-Options": "DENY"]
        if let cookie { headers["Set-Cookie"] = cookie }
        return Reply(status: 200, headers: headers, body: Data(("<!doctype html><html><body>" + body + "</body></html>").utf8))
    }

    private func authorize(_ query: [String: String]) -> Reply {
        guard query["client_id"] == ParaAirCloudConfiguration.clientID, let redirect = query["redirect_uri"],
              redirect.range(of: "^http://127\\.0\\.0\\.1:[1-9][0-9]{3,4}/oauth/callback$", options: .regularExpression) != nil,
              let port = URLComponents(string: redirect)?.port, (1024...65535).contains(port) else {
            return Reply(status: 400, headers: ["Content-Type": "text/html"], body: Data("Invalid sign-in request".utf8))
        }
        let state = query["state"] ?? ""
        let validState = (1...512).contains(state.utf8.count) && state.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
        func failure(_ code: String) -> Reply {
            let carried = validState ? "&state=" + ParaAirCloudHTTP.encodeComponent(state) : ""
            return Reply(status: 302, headers: ["Location": redirect + "?error=" + code + carried + "&iss=" + ParaAirCloudHTTP.encodeComponent(issuerString)])
        }
        guard query["response_type"] == "code" else { return failure("unsupported_response_type") }
        guard validState, query["code_challenge_method"] == "S256",
              let challenge = query["code_challenge"], challenge.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            return failure("invalid_request")
        }
        guard Set((query["scope"] ?? "drive offline_access").split(separator: " ").map(String.init)).isSubset(of: ["drive", "offline_access"]) else {
            return failure("invalid_scope")
        }
        let request = AuthRequest(id: "ar_" + Self.base32(), secret: Self.token43(), redirect: redirect, state: state, challenge: challenge, stage: "email")
        authRequests[request.id] = request
        return html("<form method=\"post\" action=\"/oauth/authorize/email\"><input type=\"hidden\" name=\"ar\" value=\"\(request.id)\"><input type=\"email\" name=\"email\"><button>Continue</button></form>",
                    cookie: "__Host-pa_ar=\(request.id).\(request.secret); HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=900")
    }

    private func boundRequest(_ form: [String: String], _ headers: [String: String]) -> AuthRequest? {
        guard let id = form["ar"], let request = authRequests[id], let cookie = headers["cookie"],
              cookie.contains("pa_ar=\(request.id).\(request.secret)") else { return nil }
        return request
    }

    private func authorizeEmail(_ form: [String: String], _ headers: [String: String]) -> Reply {
        guard var request = boundRequest(form, headers), request.stage == "email" || request.stage == "code",
              let email = form["email"]?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return Reply(status: 400, headers: ["Content-Type": "text/html"], body: Data("Start sign-in again".utf8))
        }
        let code = String(format: "%08d", Int.random(in: 0..<100_000_000))
        if invites.contains(email) || users.values.contains(where: { $0.email == email && !$0.disabled }) {
            outbox.append((email, code, Date()))
            request.code = code
        } else { request.code = nil }
        request.email = email; request.stage = "code"; request.attempts = 0
        authRequests[request.id] = request
        return html("<p>Enter the code we sent.</p><form method=\"post\" action=\"/oauth/authorize/verify\"><input type=\"hidden\" name=\"ar\" value=\"\(request.id)\"><input name=\"code\" inputmode=\"numeric\"><button>Verify</button></form>")
    }

    private func authorizeVerify(_ form: [String: String], _ headers: [String: String]) -> Reply {
        guard var request = boundRequest(form, headers), request.stage == "code", let email = request.email else {
            return Reply(status: 400, headers: ["Content-Type": "text/html"], body: Data("Start sign-in again".utf8))
        }
        request.attempts += 1
        guard request.attempts <= 5, let expected = request.code, form["code"] == expected else {
            authRequests[request.id] = request
            return html("<p>That code did not work.</p><form method=\"post\" action=\"/oauth/authorize/verify\"><input type=\"hidden\" name=\"ar\" value=\"\(request.id)\"><input name=\"code\"></form>")
        }
        var user = users.values.first { $0.email == email }
        if user == nil {
            invites.remove(email)
            let account = createAccount(email: email)
            user = users[account.userID]
        }
        request.user = user!.id; request.stage = "consent"
        authRequests[request.id] = request
        return html("<p>ParaAir for Mac wants read and write access to your ParaAir Cloud drives as \(email).</p><form method=\"post\" action=\"/oauth/authorize/consent\"><input type=\"hidden\" name=\"ar\" value=\"\(request.id)\"><button name=\"decision\" value=\"allow\">Allow</button><button name=\"decision\" value=\"deny\">Deny</button></form>")
    }

    private func authorizeConsent(_ form: [String: String], _ headers: [String: String]) -> Reply {
        guard var request = boundRequest(form, headers), request.stage == "consent", let user = request.user else {
            return Reply(status: 400, headers: ["Content-Type": "text/html"], body: Data("Start sign-in again".utf8))
        }
        request.stage = "done"; authRequests[request.id] = request
        let iss = "&iss=" + ParaAirCloudHTTP.encodeComponent(issuerString)
        let state = "&state=" + ParaAirCloudHTTP.encodeComponent(request.state)
        let clear = "__Host-pa_ar=; Secure; Path=/; Max-Age=0"
        guard form["decision"] == "allow" else {
            return Reply(status: 302, headers: ["Location": request.redirect + "?error=access_denied" + state + iss, "Set-Cookie": clear])
        }
        let code = "pcc_" + Self.token43()
        authCodes[code] = AuthCode(user: user, challenge: request.challenge, redirect: request.redirect, expires: Date().addingTimeInterval(60))
        return Reply(status: 302, headers: ["Location": request.redirect + "?code=" + code + state + iss, "Set-Cookie": clear])
    }

    private func authenticate(_ headers: [String: String]) throws -> (id: String, grant: String) {
        guard let header = headers["authorization"], header.hasPrefix("Bearer "),
              let row = accessTokens[String(header.dropFirst(7))], row.expires > Date(),
              let grant = grants[row.grant], !grant.revoked, users[grant.user]?.disabled == false else { throw Fail(code: "unauthorized") }
        return (grant.user, grant.id)
    }

    private func me(_ user: (id: String, grant: String)) -> Reply {
        let record = users[user.id]!, grant = grants[user.grant]!
        let memberships = workspaces.values.filter { $0.members[user.id] != nil }.sorted { $0.id < $1.id }
        return json(200, [
            "user": ["id": record.id, "email": record.email, "createdAt": Self.date(record.createdAt)],
            "session": ["id": grant.id, "clientId": ParaAirCloudConfiguration.clientID, "createdAt": Self.date(grant.createdAt), "expiresAt": Self.date(grant.expiresAt)],
            "workspaces": memberships.map { workspace -> [String: Any] in
                var object: [String: Any] = [
                    "id": workspace.id, "name": workspace.name, "kind": workspace.kind, "role": workspace.members[user.id]!, "status": workspace.status,
                    "plan": ["id": "beta", "name": "Beta", "storageLimitBytes": workspace.quota, "transferAllowanceBytes": workspace.quota * 3,
                             "retentionDays": retentionDays, "retentionCapBytes": workspace.quota * 15 / 100, "seats": 1, "manageUrl": NSNull()],
                    "usage": ["storedBytes": workspace.logical, "retainedBytes": workspace.retained, "reservedBytes": workspace.reserved,
                              "transferBytes": workspace.bytesOut, "uploadedBytes": workspace.bytesIn,
                              "periodStart": "2026-10-01T00:00:00.000Z", "periodEnd": "2026-11-01T00:00:00.000Z", "throttled": false, "reconciledAt": NSNull()]]
                if !omitsBilling { object["billing"] = billingView(workspace, role: workspace.members[user.id]!, user: user.id) }
                return object
            }])
    }

    // MARK: Billing (the service's src/billing/api.ts, with in-memory processors)

    private static let liveBillingStates: Set<String> = ["active", "past_due", "deleting"]

    /// `trialDaysOf` of the service: Stripe, a workspace never subscribed, a user who has not had a trial.
    private func offeredTrial(_ workspace: Workspace?, user: String) -> Int {
        billingProvider == "stripe" && workspace?.billing == nil && !trialledUsers.contains(user) ? trialDays : 0
    }

    /// `billingView` of the service: the subscription's processor else the configured one, owner-only actions.
    private func billingView(_ workspace: Workspace, role: String, user: String) -> [String: Any] {
        let configured = billingProvider == "none" ? nil : billingProvider
        let account = workspace.billing
        let owner = role == "owner"
        var checkout = false, portal = false
        if let configured, owner, workspace.status != "suspended" {
            checkout = billingConfigured && sellablePlans.contains(workspace.kind)
                && !(account.map { Self.liveBillingStates.contains($0.state) } ?? false)
            portal = account.map { $0.provider == configured && $0.hasCustomer && $0.state != "deleting" && $0.state != "deleted" } ?? false
        }
        func date(_ value: Date?) -> Any { value.map(Self.date) ?? NSNull() }
        let trial = checkout ? offeredTrial(workspace, user: user) : 0
        guard let account else {
            return ["provider": configured ?? "none", "status": "none", "plan": NSNull(), "interval": NSNull(), "seats": NSNull(),
                    "extraStorageTb": 0, "currentPeriodEnd": NSNull(), "cancelAtPeriodEnd": false, "graceEndsAt": NSNull(),
                    "readOnlyAt": NSNull(), "deletionAt": NSNull(), "checkoutAvailable": checkout, "portalAvailable": portal,
                    "trialDays": trial > 0 ? trial : NSNull(), "trialEndsAt": NSNull()]
        }
        return ["provider": account.provider, "status": account.state, "plan": account.plan, "interval": account.interval,
                "seats": account.quantity, "extraStorageTb": account.storageTb, "currentPeriodEnd": date(account.periodEnd),
                "cancelAtPeriodEnd": account.cancelAtPeriodEnd, "graceEndsAt": account.state == "past_due" ? date(account.graceEndsAt) : NSNull(),
                "readOnlyAt": date(account.readOnlyAt), "deletionAt": date(account.deletionAt),
                "checkoutAvailable": checkout, "portalAvailable": portal, "trialDays": NSNull(),
                "trialEndsAt": account.state == "active" ? date(account.trialEndsAt) : NSNull()]
    }

    /// `ownerOf`: 404 for non-members (existence never leaks), then suspended, then owner only, then 20 sessions an hour.
    private func billingOwner(user: String, _ value: Any?) throws -> Workspace {
        guard let id = value as? String, id.range(of: "^ws_[0-9A-Z]{26}$", options: .regularExpression) != nil,
              let workspace = workspaces[id], let role = workspace.members[user] else { throw Fail(code: "workspace_not_found") }
        guard workspace.status != "suspended" else { throw Fail(code: "suspended") }
        guard role == "owner" else { throw Fail(code: "forbidden") }
        let now = Date(), recent = (billingSessions[id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < 20 else {
            throw Fail(code: "rate_limited", retryAfter: Int((3600 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)).rounded(.up)))
        }
        billingSessions[id] = recent + [now]
        return workspace
    }

    private func billingCheckout(user: String, body: Data, headers: [String: String]) throws -> Reply {
        guard billingProvider != "none" else { throw Fail(code: "not_found") }
        let request = try jsonBody(body, headers)
        guard let plan = request["plan"] as? String, ["personal", "team"].contains(plan),
              let interval = request["interval"] as? String, ["month", "year"].contains(interval) else { throw Fail(code: "invalid_request") }
        func integer(_ key: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let raw = request[key] else { return nil }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue),
                  range.contains(number.intValue) else { throw Fail(code: "invalid_request") }
            return number.intValue
        }
        _ = try integer("extraStorageTb", 0...100)
        // consentFrom: both or neither; a version of printable ASCII and both boxes ticked.
        var agreed: String?
        if request["disclosureVersion"] != nil || request["consent"] != nil {
            guard let version = request["disclosureVersion"] as? String, (1...64).contains(version.utf8.count),
                  version.utf8.allSatisfy({ (0x21...0x7e).contains($0) }), let consent = request["consent"] as? [String: Any],
                  (consent["autoRenew"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true,
                  (consent["terms"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else {
                throw Fail(code: "invalid_request")
            }
            agreed = version
        }
        let workspace = try billingOwner(user: user, request["workspaceId"])
        guard workspace.kind == plan else { throw Fail(code: "invalid_request") }
        var seats = 1
        if plan == "team" {
            seats = try integer("seats", 1...1000) ?? max(1, workspace.members.count)
            guard seats >= workspace.members.count else { throw Fail(code: "invalid_request") }
        } else if let given = try integer("seats", 1...1000), given != 1 {
            throw Fail(code: "invalid_request")
        }
        guard billingConfigured, sellablePlans.contains(plan) else { throw Fail(code: "billing_unavailable") }
        if let agreed, agreed != disclosureVersion { throw Fail(code: "disclosure_outdated") }
        if let account = workspace.billing, Self.liveBillingStates.contains(account.state) { throw Fail(code: "busy") }
        // The trial the app showed (absent: none) must be the one this checkout starts.
        let trial = offeredTrial(workspace, user: user)
        guard (try integer("trialDays", 0...365) ?? 0) == trial else { throw Fail(code: "disclosure_outdated") }
        // closeEarlierCheckouts: a paid one refuses the new checkout; unpaid ones stop being payable.
        guard !paidUnboundCheckouts.contains(workspace.id) else { throw Fail(code: "busy") }
        closedCheckoutURLs += openCheckouts[workspace.id] ?? []
        checkouts.append(request)
        if trial > 0 { trialledUsers.insert(user) }
        let url: String
        if billingProvider == "paddle" {
            url = issuerString + "/billing/pay?_ptxn=txn_" + Self.base32().lowercased()
        } else {
            url = "https://checkout.stripe.com/c/pay/cs_test_" + Self.base32() + "#fidkdWxOYHwnPyd1blpxYHZxWjA0SDdPUW5JbmFMck1wMmx9N2BLZjFE"
        }
        let reply = checkoutURLOverride ?? url
        openCheckouts[workspace.id] = [reply]
        return json(200, ["url": reply])
    }

    /// The service's catalog (cloud/src/billing/catalog.ts), keyed by catalog id; `testFakeCatalogMatchesTheService`
    /// compares it with catalog.ts when the service source is available.
    static let catalog: [String: Int] = [
        "personal_month": 1_000, "personal_year": 10_000, "team_month": 1_600, "team_year": 16_000,
        "storage_month": 1_000, "storage_year": 12_000,
    ]

    /// B3 `GET /v1/billing/offer`: the price map's items, the merchant of record and, with a plan and an interval, the
    /// quote with the disclosure text (cloud/src/billing/disclosure.ts) in dev mode, so its links are the dev pages.
    private func billingOffer(_ query: [String: String], user: String) throws -> Reply {
        guard billingProvider != "none" else { throw Fail(code: "not_found") }
        guard billingConfigured else { throw Fail(code: "billing_unavailable") }
        // With workspaceId (one the caller belongs to), the quote includes the free trial its checkout starts with.
        var target: Workspace?
        if let id = query["workspaceId"] {
            guard id.range(of: "^ws_[0-9A-Z]{26}$", options: .regularExpression) != nil, let workspace = workspaces[id], workspace.members[user] != nil else {
                throw Fail(code: "workspace_not_found")
            }
            target = workspace
        }
        let trial = offeredTrial(target, user: user)
        let seller = billingProvider == "paddle" ? "paddle" : stripeManaged ? "link" : "parafield"
        func amount(_ id: String) -> Int { priceOverrides[id] ?? Self.catalog[id]! }
        let sold = ["personal_month", "personal_year", "team_month", "team_year", "storage_month", "storage_year"].filter {
            $0.hasPrefix("storage") || sellablePlans.contains(String($0.split(separator: "_")[0]))
        }
        let prices: [[String: Any]] = sold.map { id in
            let parts = id.split(separator: "_").map(String.init)
            let storage = parts[0] == "storage"
            return ["item": id, "kind": storage ? "storage" : "plan", "plan": storage ? NSNull() : parts[0], "interval": parts[1],
                    "unitAmountCents": amount(id), "perMember": parts[0] == "team"]
        }
        var quote: Any = NSNull()
        if query["plan"] != nil || query["interval"] != nil {
            guard let plan = query["plan"], ["personal", "team"].contains(plan), let interval = query["interval"], ["month", "year"].contains(interval) else {
                throw Fail(code: "invalid_request")
            }
            func quantity(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) throws -> Int {
                guard let raw = query[key] else { return fallback }
                guard raw.range(of: "^[0-9]{1,6}$", options: .regularExpression) != nil, let value = Int(raw), range.contains(value) else {
                    throw Fail(code: "invalid_request")
                }
                return value
            }
            let seats = try quantity("seats", plan == "team" ? 1...1000 : 1...1, 1)
            let storage = try quantity("extraStorageTb", 0...100, 0)
            if sellablePlans.contains(plan) {
                let unit = amount("\(plan)_\(interval)"), block = amount("storage_\(interval)")
                let total = unit * (plan == "team" ? seats : 1) + block * storage
                let now = Date()
                let text = Self.disclosure(plan: plan, interval: interval, seats: seats, storageTb: storage, unit: unit, block: block, total: total,
                                           now: now, accountURL: issuerString + "/billing/account", seller: seller, trialDays: trial,
                                           termsURL: issuerString + "/legal/terms", policyURL: issuerString + "/legal/subscription-policy")
                quote = ["plan": plan, "interval": interval, "seats": seats, "extraStorageTb": storage, "amountCents": total, "currency": "USD",
                         "trialDays": trial > 0 ? trial : NSNull(), "firstChargeAt": Self.date(now.addingTimeInterval(Double(trial) * 86_400)),
                         "summary": text.summary, "terms": text.terms, "consent": text.consent]
            }
        }
        let merchant: [String: Any] = seller == "paddle" ? ["name": "Paddle", "reseller": true]
            : seller == "link" ? ["name": "Link", "reseller": true] : ["name": "Parafield Inc.", "reseller": false]
        return json(200, ["provider": billingProvider, "merchantOfRecord": merchant, "disclosureVersion": disclosureVersion, "currency": "USD",
                          "prices": prices, "quote": quote])
    }

    /// disclosure.ts with refund Option A, word for word. `seller`: "paddle", "link" (Stripe Managed Payments) or "parafield".
    static func disclosure(plan: String, interval: String, seats: Int, storageTb: Int, unit unitCents: Int, block: Int, total totalCents: Int,
                           now: Date, accountURL: String, seller: String, trialDays: Int = 0, termsURL: String?, policyURL: String?)
        -> (terms: [String], summary: [String], consent: String) {
        let team = plan == "team", yearly = interval == "year"
        let unit = ParaAirCloudBillingCatalog.formatUSD(cents: unitCents), total = ParaAirCloudBillingCatalog.formatUSD(cents: totalCents)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        // With a trial the first charge, and every renewal date after it, falls on the day the trial ends.
        let trial = trialDays > 0, first = now.addingTimeInterval(Double(trialDays) * 86_400)
        let day = calendar.component(.day, from: first), month = months[calendar.component(.month, from: first) - 1]
        // A deadline with its UTC time, as disclosure.ts gives it.
        let firstDay = "\(month) \(day), \(calendar.component(.year, from: first)) at "
            + String(format: "%02d:%02d UTC", calendar.component(.hour, from: first), calendar.component(.minute, from: first))
        let tens = day % 100, ones = day % 10
        let ordinal = "\(day)" + ((11...13).contains(tens) ? "th" : ones == 1 ? "st" : ones == 2 ? "nd" : ones == 3 ? "rd" : "th")
        let when = yearly ? "every year on \(month) \(day)" : "on the \(ordinal) of every month"
        let period = yearly ? "year" : "month"
        let charger = seller == "paddle" ? "Paddle, our reseller, charges" : seller == "link" ? "Link, our reseller, charges" : "we charge"
        var terms = ["ParaAir Cloud \(team ? "Team" : "Personal"), billed \(yearly ? "yearly" : "monthly")",
                     "\(unit) \(team ? "per member " : "")per \(period) plus tax\(trial ? " after a \(trialDays)-day free trial" : ""). "
                        + "Renews automatically every \(period) until you cancel."]
        var bullets: [String] = []
        if team { bullets.append("You are buying \(seats) member seats\(storageTb > 0 ? " and added storage" : ""): \(total) per \(period) plus tax.") }
        bullets.append(trial ? "Today you pay nothing. Your free trial ends on \(firstDay)." : "Today you pay \(total) plus any tax, which is shown before you pay.")
        if storageTb > 0 {
            bullets.append("This includes \(storageTb) TB of added storage at \(ParaAirCloudBillingCatalog.formatUSD(cents: block)) per TB per \(period) plus tax.")
        }
        let starting = trial ? "on \(firstDay) and " : ""
        bullets.append(team ? "Then \(charger) for the current number of members, at \(unit) per member plus tax\(storageTb > 0 ? ", plus added storage" : ""), \(starting)\(when)."
                            : "Then \(charger) \(total) plus tax \(starting)\(when).")
        if trial {
            bullets.append("Cancel before \(firstDay) and you pay nothing. If that first payment fails, the plan stops at once: "
                + "your files become read-only for 30 days, then are deleted.")
        }
        if team {
            bullets.append("Your \(yearly ? "yearly" : "monthly") charge changes when you add or remove members. Adding a member charges a prorated amount "
                + "\(yearly ? "for the rest of the year " : "")right away. Removing a member lowers the charge from your next \(yearly ? "yearly " : "")renewal; "
                + "the seat stays paid until then.")
            bullets.append("Includes 1 TB of storage per member, shared by the team, and up to 3 TB of full-speed transfer per member each month, shared. "
                + "No overage charges.")
        } else {
            bullets.append(storageTb > 0
                ? "Includes \(1 + storageTb) TB of storage and up to \(3 * (1 + storageTb)) TB of full-speed transfer each month. No overage charges."
                : "Includes 1 TB of storage and up to 3 TB of full-speed transfer each month. No overage charges.")
        }
        if yearly {
            bullets.append(team ? "We will email the owner and billing admins 25 to 30 days before each yearly renewal."
                           : "We will email you 25 to 30 days before each yearly renewal.")
        }
        bullets.append(team
            ? "The owner, or an admin with billing access, can cancel any time online in the ParaAir app (Storage Settings > Manage Plan) or at \(accountURL). "
                + "Cancel before your renewal date to avoid the next charge."
            : "Cancel any time online: in the ParaAir app (Storage Settings > Manage Plan) or at \(accountURL). Cancel before your renewal date "
                + "to avoid the next charge. You keep access until the end of the \(period) you paid for.")
        bullets.append("Full refund if you ask within 14 days of \(trial ? "your" : "this") first payment\(yearly ? " or within 14 days of any yearly renewal charge" : "").")
        bullets.append("We will email you at least 14 days before any price change, and you can cancel first.")
        terms += bullets.map { "- " + $0 }
        func link(_ label: String, _ url: String?) -> String { url.map { "[\(label)](\($0))" } ?? label }
        let after = trial ? " after the \(trialDays)-day free trial" : ""
        let renewal = team
            ? "I agree that this ParaAir Cloud Team plan renews automatically\(after) at \(unit) per member per \(period) plus tax, for the number of members at each renewal, until I cancel."
            : "I agree that my ParaAir Cloud Personal plan renews automatically\(after) at \(total) per \(period) plus tax until I cancel."
        let documents = "I agree to the \(link("Terms of Service", termsURL)) and the \(link("Subscription, Cancellation and Refund Policy", policyURL))"
            + "\(team ? ", and I am authorized to agree for this team" : "")."
        // The short screen's lines (disclosure.ts, A-draft-2026-10-27b).
        let price = team ? "\(unit) per member per \(period) plus tax (\(total) for \(seats) member\(seats == 1 ? "" : "s")"
            + "\(storageTb > 0 ? " and \(storageTb) TB added storage" : ""))" : "\(total) per \(period) plus tax"
        let place = "in ParaAir (Storage Settings > Manage Plan) or at \(accountURL)"
        let who = team ? "The owner or a billing admin can cancel" : "Cancel"
        var summary = [trial ? "Free for \(trialDays) days, then \(price), renewing automatically every \(period) until you cancel."
                             : "\(price), charged today and renewing automatically every \(period) until you cancel.",
                       trial ? "\(who) online before \(firstDay) to pay nothing: \(place)."
                             : "\(who) online any time: \(place). Access lasts until the end of the \(period) paid for.",
                       "Full refund if you ask within 14 days of \(trial ? "your" : "this") first payment\(yearly ? " or of any yearly renewal charge" : "")."]
        if trial { summary.append("If that first payment fails, the plan stops at once: your files become read-only for 30 days, then are deleted.") }
        return (terms, summary, renewal + " " + documents)
    }

    private func billingPortal(user: String, body: Data, headers: [String: String]) throws -> Reply {
        guard billingProvider != "none" else { throw Fail(code: "not_found") }
        let workspace = try billingOwner(user: user, try jsonBody(body, headers)["workspaceId"])
        guard let account = workspace.billing, account.provider == billingProvider, account.hasCustomer else { throw Fail(code: "not_found") }
        let url = billingProvider == "paddle"
            ? "https://\(paddleSandbox ? "sandbox-" : "")customer-portal.paddle.com/cpl_01j7zbyqs3vah3aafp4jf62qaw?action=overview&token=pga_" + Self.token43()
            : "https://billing.stripe.com/p/session?secret=test_" + Self.token43()
        return json(200, ["url": portalURLOverride ?? url])
    }

    // MARK: Files

    private func live(_ drive: String, _ path: String) -> Node? {
        nodes.values.first { $0.drive == drive && $0.path == path && $0.deletedAt == nil }
    }
    private func nfcSiblingExists(_ drive: String, _ path: String) -> Bool {
        let parent = Self.parent(path), name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        return nodes.values.contains { $0.drive == drive && $0.deletedAt == nil && $0.path != path && Self.parent($0.path) == parent
            && ($0.path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping == name }
    }
    private func parentDirectory(_ drive: String, _ path: String, missing: String) throws -> Node {
        guard let parent = live(drive, Self.parent(path)) else { throw Fail(code: missing) }
        guard parent.kind == .directory else { throw Fail(code: "not_directory") }
        return parent
    }

    private func list(_ drive: Drive, _ query: [String: String]) throws -> Reply {
        let path = try serverPath(query["path"])
        guard let node = live(drive.id, path) else { throw Fail(code: "not_found") }
        guard node.kind == .directory else { throw Fail(code: "not_directory") }
        let limit = Int(query["limit"] ?? "1000") ?? 0
        guard (1...5000).contains(limit) else { throw Fail(code: "invalid_request") }
        var children = nodes.values.filter { $0.drive == drive.id && $0.deletedAt == nil && $0.path != "/" && Self.parent($0.path) == path }
            .sorted { Array(($0.path as NSString).lastPathComponent.utf8).lexicographicallyPrecedes(($1.path as NSString).lastPathComponent.utf8) }
        if let cursor = query["cursor"] {
            guard let after = Data(base64Encoded: cursor).map({ String(decoding: $0, as: UTF8.self) }) else { throw Fail(code: "invalid_request") }
            children = children.filter { Array(($0.path as NSString).lastPathComponent.utf8).lexicographicallyPrecedes(after.utf8) == false && ($0.path as NSString).lastPathComponent != after }
        }
        let page = Array(children.prefix(limit))
        let next: Any = children.count > limit ? Data((page.last!.path as NSString).lastPathComponent.utf8).base64EncodedString() : NSNull()
        return json(200, ["entries": page.map(entryJSON), "nextCursor": next])
    }

    private func move(_ drive: Drive, from: String, to: String) throws -> Reply {
        guard let source = live(drive.id, from) else { throw Fail(code: "not_found") }
        if from == to { return json(200, ["entry": entryJSON(source)]) }
        guard from != "/", to != "/", !to.hasPrefix(from + "/") else { throw Fail(code: "invalid_move") }
        _ = try parentDirectory(drive.id, to, missing: "parent_not_found")
        let descendants = nodes.values.filter { $0.drive == drive.id && $0.deletedAt == nil && $0.path.hasPrefix(from + "/") }
        guard descendants.count <= 10000 else { throw Fail(code: "move_too_large") }
        if live(drive.id, to) == nil, nfcSiblingExists(drive.id, to) { throw Fail(code: "already_exists") }
        if let destination = live(drive.id, to) {
            switch (source.kind, destination.kind) {
            case (.file, .directory): throw Fail(code: "is_directory")
            case (.directory, .file): throw Fail(code: "not_directory")
            case (.directory, .directory):
                guard !nodes.values.contains(where: { $0.drive == drive.id && $0.deletedAt == nil && $0.path.hasPrefix(to + "/") }) else { throw Fail(code: "not_empty") }
                nodes[destination.id] = nil; workspaces[drive.workspace]!.nodeCount -= 1
            case (.file, .file):
                softDelete(destination, workspace: drive.workspace)
            }
        }
        for node in descendants { nodes[node.id]!.path = to + node.path.dropFirst(from.count) }
        nodes[source.id]!.path = to
        return json(200, ["entry": entryJSON(nodes[source.id]!)])
    }

    private func softDelete(_ node: Node, workspace: String) {
        if let head = node.head {
            versions[head]?.supersededAt = Date(); versions[head]?.expiresAt = Date().addingTimeInterval(TimeInterval(retentionDays) * 86400)
        }
        workspaces[workspace]!.logical -= node.size; workspaces[workspace]!.retained += node.size; workspaces[workspace]!.nodeCount -= 1
        nodes[node.id]!.deletedAt = Date()
    }

    private func remove(_ drive: Drive, path: String, directory: Bool) throws -> Reply {
        guard path != "/" else { throw Fail(code: "busy") }
        guard let node = live(drive.id, path) else { throw Fail(code: "not_found") }
        switch (node.kind, directory) {
        case (.file, true): throw Fail(code: "not_directory")
        case (.directory, false): throw Fail(code: "is_directory")
        case (.directory, true):
            guard !nodes.values.contains(where: { $0.drive == drive.id && $0.deletedAt == nil && $0.path.hasPrefix(path + "/") }) else { throw Fail(code: "not_empty") }
            nodes[node.id] = nil; workspaces[drive.workspace]!.nodeCount -= 1
        case (.file, false):
            softDelete(node, workspace: drive.workspace)
        }
        return Reply(status: 204)
    }

    private func trash(_ drive: Drive, _ query: [String: String]) throws -> Reply {
        let limit = Int(query["limit"] ?? "1000") ?? 0
        guard (1...5000).contains(limit) else { throw Fail(code: "invalid_request") }
        let items = nodes.values.filter { node in
            guard node.drive == drive.id, node.kind == .file, node.deletedAt != nil, let head = node.head, let version = versions[head] else { return false }
            return (version.expiresAt ?? .distantFuture) > Date()
        }.sorted { ($0.deletedAt!, $0.id) > ($1.deletedAt!, $1.id) }
        let start = Int(query["cursor"] ?? "0") ?? 0
        let page = Array(items.dropFirst(start).prefix(limit))
        let next: Any = start + page.count < items.count ? String(start + page.count) : NSNull()
        return json(200, ["items": page.map { node -> [String: Any] in
            ["nodeId": node.id, "path": node.path, "size": node.size, "version": "pv:\(node.head!)", "deletedAt": Self.date(node.deletedAt!),
             "expiresAt": Self.date(versions[node.head!]!.expiresAt!)]
        }, "nextCursor": next])
    }

    private func restore(_ drive: Drive, nodeID: Int64, to: String?) throws -> Reply {
        guard let node = nodes[nodeID], node.drive == drive.id, node.deletedAt != nil, let head = node.head, let version = versions[head] else {
            throw Fail(code: "not_found")
        }
        guard (version.expiresAt ?? .distantFuture) > Date() else { throw Fail(code: "version_not_found") }
        let destination = try to.map { try serverPath($0) } ?? node.path
        guard live(drive.id, destination) == nil else { throw Fail(code: "already_exists") }
        _ = try parentDirectory(drive.id, destination, missing: "parent_not_found")
        let workspace = workspaces[drive.workspace]!
        guard node.size <= 0 || workspace.logical + node.size <= workspace.quota else { throw Fail(code: "quota_exceeded") }
        guard workspace.nodeCount + 1 <= workspace.maxNodes else { throw Fail(code: "node_limit") }
        nodes[nodeID]!.deletedAt = nil; nodes[nodeID]!.path = destination; nodes[nodeID]!.mtimeUs = Self.nowUs()
        versions[head]!.supersededAt = nil; versions[head]!.expiresAt = nil
        workspaces[drive.workspace]!.logical += node.size
        workspaces[drive.workspace]!.retained = max(0, workspace.retained - node.size)
        workspaces[drive.workspace]!.nodeCount += 1
        return json(200, ["entry": entryJSON(nodes[nodeID]!)])
    }

    // MARK: Read path

    private func manifest(_ drive: Drive, _ query: [String: String], grant: String) throws -> Reply {
        guard let raw = query["version"], raw.range(of: "^p[vd]:[1-9][0-9]{0,15}$", options: .regularExpression) != nil else { throw Fail(code: "invalid_version") }
        if raw.hasPrefix("pd:") { throw Fail(code: "is_directory") }
        guard let id = Int64(raw.dropFirst(3)), let version = versions[id], version.drive == drive.id,
              (version.expiresAt ?? .distantFuture) > Date() else { throw Fail(code: "version_not_found") }
        let start = Int(query["start"] ?? "0") ?? -1, limit = Int(query["limit"] ?? "4096") ?? 0
        guard start >= 0, (1...4096).contains(limit) else { throw Fail(code: "invalid_request") }
        let slice = Array(version.chunks.enumerated().dropFirst(start).prefix(limit))
        let next: Any = start + slice.count < version.chunks.count ? start + slice.count : NSNull()
        let (token, expires) = mintReadToken(drive.workspace, grant: grant)
        return json(200, ["version": raw, "size": version.size, "chunkSize": chunkSize, "chunkCount": version.chunks.count, "start": start,
                          "chunks": slice.map { ["index": $0.offset, "sha256": $0.element.sha, "size": $0.element.size] },
                          "nextStart": next, "workspaceId": drive.workspace, "readToken": token, "readTokenExpiresAt": Self.date(expires)])
    }

    private func mintReadToken(_ workspace: String, grant: String) -> (String, Date) {
        let token = "prt1." + Self.token43() + "." + Self.token43()
        let expires = Date().addingTimeInterval(clockOffset + readTokenTTL)
        readTokens[token] = (workspace, expires, grant)
        return (token, expires)
    }

    private func chunkGet(workspace: String, sha: String, headers: [String: String]) throws -> Reply {
        guard let header = headers["authorization"], header.hasPrefix("Bearer "), let row = readTokens[String(header.dropFirst(7))],
              row.expires > Date().addingTimeInterval(clockOffset), row.workspace == workspace else { throw Fail(code: "unauthorized") }
        guard let bytes = chunks[workspace]?[sha] else { throw Fail(code: "chunk_not_found") }
        var reply = Reply(status: 200, headers: ["Content-Type": "application/octet-stream", "ETag": "\"sha256:\(sha)\"",
                                                 "Cache-Control": "private, no-store, no-transform", "X-Request-Id": "req_" + Self.base32()])
        if let range = headers["range"] {
            guard let match = range.range(of: "^bytes=[0-9]+-[0-9]+$", options: .regularExpression), match.lowerBound == range.startIndex else { throw Fail(code: "invalid_range") }
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2, bounds[0] <= bounds[1] else { throw Fail(code: "invalid_range") }
            guard bounds[0] < bytes.count else { return Reply(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"]) }
            let end = min(bounds[1], bytes.count - 1)
            reply.status = 206; reply.body = bytes.subdata(in: bounds[0]..<end + 1)
            reply.headers["Content-Range"] = "bytes \(bounds[0])-\(end)/\(bytes.count)"
        } else { reply.body = bytes }
        reply.headers["Content-Length"] = String(reply.body.count)
        workspaces[workspace]?.bytesOut += Int64(reply.body.count)
        return reply
    }

    // MARK: Upload path (spec 2.6, 4.4, 4.5)

    private func fence(_ drive: String, _ transaction: String, _ code: String) -> Fail {
        fences.insert(drive + "|" + transaction)
        return Fail(code: code)
    }

    private func reserve(_ drive: Drive, _ request: [String: Any]) throws -> Reply {
        guard let rawTransaction = request["transactionId"] as? String, let uuid = UUID(uuidString: rawTransaction) else { throw Fail(code: "invalid_request") }
        let transaction = uuid.uuidString.lowercased()
        let key = drive.id + "|" + transaction
        guard !fences.contains(key) else { throw Fail(code: "transaction_fenced") }
        var parsed: (path: String, expected: String?, finalSize: Int64, masked: UInt32, list: [(sha: String, size: Int)], hash: String)?
        var invalid: Fail?
        do { parsed = try parseReserve(request) } catch let fail as Fail { invalid = fail }
        // An acknowledged transaction is replayed (or refused) before anything else about the request is judged.
        if let version = versions.values.first(where: { $0.drive == drive.id && $0.transaction == transaction }) {
            guard let parsed, version.manifestHash == parsed.hash else { throw Fail(code: "transaction_committed") }
            return json(200, ["state": "committed", "entry": versionEntry(version)])
        }
        if let invalid { throw fence(drive.id, transaction, invalid.code) }
        guard workspaces[drive.workspace]!.status == "active" else { throw fence(drive.id, transaction, "read_only") }
        let (path, expected, finalSize, masked, list, hash) = parsed!
        if let found = uploads.first(where: { $0.value.drive == drive.id && $0.value.transaction == transaction && $0.value.committedVersion == nil }) {
            let (id, open) = (found.key, found.value)
            // The same manifest revives the upload (sliding expiry) until its hard expiry.
            if open.hash == hash, open.hardExpiresAt > Date() {
                uploads[id]!.expiresAt = min(open.hardExpiresAt, max(open.expiresAt, Date().addingTimeInterval(12 * 3600)))
                return openReply(uploads[id]!, workspace: drive.workspace, status: 200)
            }
            workspaces[drive.workspace]!.reserved -= open.reserved; uploads[id] = nil
        }
        let existing = live(drive.id, path)
        if let expected {
            guard let existing, existing.kind == .file, existing.head.map({ "pv:\($0)" }) == expected else {
                throw fence(drive.id, transaction, existing?.kind == .directory ? "is_directory" : "version_conflict")
            }
        } else if let existing {
            throw fence(drive.id, transaction, existing.kind == .directory ? "is_directory" : "version_conflict")
        }
        do { _ = try parentDirectory(drive.id, path, missing: "parent_not_found") } catch let fail as Fail { throw fence(drive.id, transaction, fail.code) }
        let workspace = workspaces[drive.workspace]!
        let delta = finalSize - (existing?.size ?? 0)
        guard workspace.logical + workspace.reserved + max(0, delta) <= workspace.quota else { throw fence(drive.id, transaction, "quota_exceeded") }
        guard existing != nil || workspace.nodeCount + 1 <= workspace.maxNodes else { throw fence(drive.id, transaction, "node_limit") }
        let active = uploads.values.filter { drives[$0.drive]?.workspace == drive.workspace && $0.committedVersion == nil && $0.expiresAt > Date() }
        guard active.count < 512 else { throw Fail(code: "too_many_uploads") }
        let upload = Upload(id: "upl_" + Self.base32(), drive: drive.id, transaction: transaction, path: path, expectedVersion: expected,
                            finalSize: finalSize, mode: masked, chunks: list, hash: hash, reserved: max(0, delta),
                            expiresAt: Date().addingTimeInterval(12 * 3600), committedVersion: nil)
        uploads[upload.id] = upload
        workspaces[drive.workspace]!.reserved += upload.reserved
        return openReply(upload, workspace: drive.workspace, status: 201)
    }

    private func parseReserve(_ request: [String: Any]) throws -> (path: String, expected: String?, finalSize: Int64, masked: UInt32,
                                                                   list: [(sha: String, size: Int)], hash: String) {
        let path = try serverPath(request["path"] as? String)
        let expected = request["expectedVersion"] as? String
        guard request.keys.contains("expectedVersion"), expected == nil || expected!.range(of: "^pv:[1-9][0-9]{0,15}$", options: .regularExpression) != nil else {
            throw Fail(code: "invalid_version")
        }
        guard let finalSize = (request["finalSize"] as? NSNumber)?.int64Value, finalSize >= 0, let mode = (request["mode"] as? NSNumber)?.uint32Value,
              let declared = request["chunks"] as? [[String: Any]], (request["chunkSize"] as? NSNumber)?.intValue == chunkSize else {
            throw Fail(code: "invalid_manifest")
        }
        guard finalSize <= 274_877_906_944 else { throw Fail(code: "file_too_large") }
        let count = finalSize == 0 ? 0 : Int((finalSize - 1) / Int64(chunkSize)) + 1
        var list: [(sha: String, size: Int)] = []
        for (index, chunk) in declared.enumerated() {
            let expectedSize = Int(min(Int64(chunkSize), finalSize - Int64(index) * Int64(chunkSize)))
            guard let sha = chunk["sha256"] as? String, ParaAirCloudErrorMap.isSHA256(sha), (chunk["size"] as? NSNumber)?.intValue == expectedSize else {
                throw Fail(code: "invalid_manifest")
            }
            list.append((sha, expectedSize))
        }
        guard list.count == count, count <= 65536 else { throw Fail(code: "invalid_manifest") }
        let masked = mode & 0o7777
        let hash = Self.hex(Data((path + "\n" + (expected ?? "") + "\n" + String(finalSize) + "\n" + String(masked) + "\n"
                                  + list.map { $0.sha + ":" + String($0.size) }.joined(separator: ",")).utf8))
        return (path, expected, finalSize, masked, list, hash)
    }

    private func openReply(_ upload: Upload, workspace: String, status: Int) -> Reply {
        var seen = Set<String>(), missing: [String] = [], bytes: Int64 = 0
        for chunk in upload.chunks where chunks[workspace]?[chunk.sha] == nil && seen.insert(chunk.sha).inserted {
            missing.append(chunk.sha); bytes += Int64(chunk.size)
        }
        return json(status, ["uploadId": upload.id, "state": "open", "expiresAt": Self.date(upload.expiresAt), "chunkSize": chunkSize,
                             "missing": missing, "missingBytes": bytes])
    }

    private func putChunk(_ drive: Drive, sha: String, upload id: String?, body: Data) throws -> Reply {
        guard let id else { throw Fail(code: "invalid_request") }
        guard let upload = uploads[id], upload.drive == drive.id, upload.committedVersion == nil else { throw Fail(code: "upload_not_found") }
        guard upload.expiresAt > Date() else { throw Fail(code: "upload_expired") }
        guard let declared = upload.chunks.first(where: { $0.sha == sha }) else { throw Fail(code: "chunk_not_in_upload") }
        guard body.count == declared.size else { throw Fail(code: "size_mismatch") }
        if chunks[drive.workspace]?[sha] != nil { return json(200, ["stored": false]) }
        guard Self.hex(body) == sha else { throw Fail(code: "chunk_hash_mismatch") }
        chunks[drive.workspace, default: [:]][sha] = body
        workspaces[drive.workspace]!.bytesIn += Int64(body.count)
        uploads[id]!.expiresAt = Date().addingTimeInterval(12 * 3600)
        return json(201, ["sha256": sha, "size": body.count, "stored": true])
    }

    private func commit(_ drive: Drive, uploadID: String) throws -> Reply {
        var workspace = workspaces[drive.workspace]!
        guard let upload = uploads[uploadID], upload.drive == drive.id else { throw Fail(code: "upload_not_found") }
        let key = drive.id + "|" + upload.transaction
        func fenced(_ code: String) -> Fail {
            fences.insert(key); workspaces[drive.workspace]!.reserved -= upload.reserved; uploads[uploadID] = nil
            return Fail(code: code)
        }
        if let committed = upload.committedVersion {
            guard let version = versions[committed] else { throw Fail(code: "upload_not_found") }
            return json(200, ["entry": versionEntry(version), "capacity": capacityJSON(drive.workspace)])
        }
        if versions.values.contains(where: { $0.drive == drive.id && $0.transaction == upload.transaction }) { throw Fail(code: "transaction_committed") }
        guard workspace.status == "active" else { throw fenced("read_only") }
        guard !fences.contains(key) else { throw Fail(code: "transaction_fenced") }
        guard upload.expiresAt > Date() else { throw Fail(code: "upload_expired") }
        var seen = Set<String>(), missing: [String] = []
        for chunk in upload.chunks where chunks[drive.workspace]?[chunk.sha] == nil && seen.insert(chunk.sha).inserted { missing.append(chunk.sha) }
        guard missing.isEmpty else { throw Fail(code: "chunks_missing", missing: missing) }
        let existing = live(drive.id, upload.path)
        if let expected = upload.expectedVersion {
            guard let existing, existing.kind == .file, "pv:\(existing.head ?? 0)" == expected else {
                throw fenced(existing?.kind == .directory ? "is_directory" : "version_conflict")
            }
        } else if let existing { throw fenced(existing.kind == .directory ? "is_directory" : "version_conflict") }
        do { _ = try parentDirectory(drive.id, upload.path, missing: "parent_not_found") } catch let fail as Fail { throw fenced(fail.code) }
        let delta = upload.finalSize - (existing?.size ?? 0)
        guard delta <= 0 || workspace.logical + delta <= workspace.quota else { throw fenced("quota_exceeded") }
        guard existing != nil || workspace.nodeCount + 1 <= workspace.maxNodes else { throw fenced("node_limit") }
        guard existing != nil || !nfcSiblingExists(drive.id, upload.path) else { throw fenced("already_exists") }
        let nodeID: Int64
        if let existing {
            nodeID = existing.id
            if let head = existing.head {
                versions[head]!.supersededAt = Date(); versions[head]!.expiresAt = Date().addingTimeInterval(TimeInterval(retentionDays) * 86400)
            }
            workspace.retained += existing.size
        } else {
            nodeID = makeID()
            nodes[nodeID] = Node(id: nodeID, drive: drive.id, path: upload.path, kind: .file, mtimeUs: Self.nowUs(), mode: upload.mode, head: nil, deletedAt: nil)
            workspace.nodeCount += 1
        }
        let now = Self.nowUs()
        let version = Version(id: makeID(), node: nodeID, drive: drive.id, transaction: upload.transaction, manifestHash: upload.hash,
                              size: upload.finalSize, mode: upload.mode, chunks: upload.chunks, supersededAt: nil, expiresAt: nil,
                              path: upload.path, createdUs: now)
        versions[version.id] = version
        nodes[nodeID]!.head = version.id; nodes[nodeID]!.size = upload.finalSize; nodes[nodeID]!.mode = upload.mode; nodes[nodeID]!.mtimeUs = now
        workspace.logical += delta; workspace.reserved = max(0, workspace.reserved - upload.reserved)
        workspaces[drive.workspace] = workspace
        uploads[uploadID]!.committedVersion = version.id
        return json(200, ["entry": entryJSON(nodes[nodeID]!), "capacity": capacityJSON(drive.workspace)])
    }

    // MARK: Helpers

    private func idempotent(scope: String, headers: [String: String], body: Data, path: String, _ action: () throws -> Reply) throws -> Reply {
        guard let key = headers["idempotency-key"], UUID(uuidString: key) != nil else { throw Fail(code: "invalid_request") }
        let hash = Self.hex(Data((path + "\n").utf8) + body)
        if let stored = idempotency[scope + "|" + key] {
            guard stored.hash == hash else { throw Fail(code: "idempotency_mismatch") }
            return stored.reply
        }
        let reply = try action()
        if (200...299).contains(reply.status) { idempotency[scope + "|" + key] = (hash, reply) }
        return reply
    }

    private func jsonBody(_ body: Data, _ headers: [String: String]) throws -> [String: Any] {
        guard headers["content-type"]?.hasPrefix("application/json") == true else { throw Fail(code: "unsupported_media_type") }
        guard body.count <= 8 << 20, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw Fail(code: "invalid_request") }
        return object
    }

    /// The server path rules of `contract/paraair-cloud-v1/paths.json`.
    private func serverPath(_ value: String?) throws -> String {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { throw Fail(code: "invalid_path") }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(".."), !parts.contains("."), parts.first != ".streamdrive" else { throw Fail(code: "escaping_path") }
        guard parts.allSatisfy({ $0.utf8.count <= 255 }) else { throw Fail(code: "name_too_long") }
        guard !parts.contains(where: { [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.unicodeScalars.first?.properties.generalCategory) }) else { throw Fail(code: "invalid_path") }
        let path = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        guard path.utf8.count <= 1024 else { throw Fail(code: "name_too_long") }
        return path
    }

    private func makeID() -> Int64 { defer { nextID += 1 }; return nextID }
    private func makeDrive(workspace: String, name: String) -> Drive {
        let root = makeID()
        let drive = Drive(id: UUID().uuidString.lowercased(), workspace: workspace, name: name, createdAt: Date(), root: root)
        nodes[root] = Node(id: root, drive: drive.id, path: "/", kind: .directory, mtimeUs: Self.nowUs(), mode: 0o755, head: nil, deletedAt: nil)
        drives[drive.id] = drive
        return drive
    }
    private func driveJSON(_ drive: Drive, user: String) -> [String: Any] {
        let workspace = workspaces[drive.workspace]!
        let role = workspace.members[user] ?? "viewer"
        return ["id": drive.id, "workspaceId": drive.workspace, "name": drive.name, "role": role,
                "writable": workspace.status == "active" && role != "viewer", "chunkSize": chunkSize, "createdAt": Self.date(drive.createdAt)]
    }
    /// The service's drive-name rule: NFC, 1-255 UTF-8 bytes, no control or format characters, no "/", no surrounding spaces.
    static func driveName(_ value: Any?) throws -> String {
        guard let raw = value as? String else { throw Fail(code: "invalid_name") }
        let name = raw.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.trimmingCharacters(in: .whitespacesAndNewlines) == name, name.utf8.count <= 255, !name.contains("/"),
              !name.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) }) else { throw Fail(code: "invalid_name") }
        return name
    }
    private func capacityJSON(_ id: String) -> [String: Any] {
        let workspace = workspaces[id]!
        return ["quotaBytes": workspace.quota, "usedBytes": workspace.logical, "retainedBytes": workspace.retained,
                "reservedBytes": workspace.reserved, "availableBytes": max(0, workspace.quota - workspace.logical - workspace.reserved)]
    }
    private func entryJSON(_ node: Node) -> [String: Any] {
        ["id": node.id, "path": node.path, "kind": node.kind.rawValue, "size": node.kind == .file ? node.size : 0,
         "mtimeNs": node.mtimeUs == 0 ? "0" : "\(node.mtimeUs)000",
         "version": node.kind == .file ? "pv:\(node.head ?? 0)" : "pd:\(node.id)", "mode": node.kind == .file ? Int(node.mode) : 493]
    }
    private func fileEntry(_ node: Node) -> FileEntry {
        FileEntry(id: UInt64(node.id), path: node.path, kind: node.kind, size: node.kind == .file ? node.size : 0,
                  modifiedNanoseconds: node.mtimeUs * 1000, version: node.kind == .file ? "pv:\(node.head ?? 0)" : "pd:\(node.id)",
                  mode: node.kind == .file ? node.mode : 0o755)
    }
    /// The entry of a committed version, even when it is no longer the head: its path at commit time and its creation time.
    private func versionEntry(_ version: Version) -> [String: Any] {
        ["id": version.node, "path": version.path, "kind": "file", "size": version.size,
         "mtimeNs": version.createdUs == 0 ? "0" : "\(version.createdUs)000", "version": "pv:\(version.id)", "mode": Int(version.mode)]
    }

    private func json(_ status: Int, _ object: Any) -> Reply {
        let body = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Reply(status: status, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
                                               "X-Content-Type-Options": "nosniff", "X-Request-Id": "req_" + Self.base32()], body: body)
    }
    private func errorReply(status: Int, code: String, retryAfter: Int?, missing: [String]?) -> Reply {
        let requestID = "req_" + Self.base32()
        var error: [String: Any] = ["code": code, "message": "Request failed.", "requestId": requestID]
        if let missing { error["missing"] = missing }
        if let retryAfter { error["retryAfterSeconds"] = retryAfter }
        var reply = json(status, ["error": error])
        reply.headers["X-Request-Id"] = requestID
        if let retryAfter { reply.headers["Retry-After"] = String(retryAfter) }
        if status == 401 { reply.headers["WWW-Authenticate"] = "Bearer realm=\"paraair\", error=\"invalid_token\"" }
        return reply
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    /// Like any HTTP server, the service dates its replies (RFC 9110 6.6.1), on its own clock.
    private func dated(_ reply: Reply) -> Reply {
        var reply = reply
        reply.headers["Date"] = Self.httpDate.string(from: Date().addingTimeInterval(clockOffset))
        return reply
    }
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func route(method: String, path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "v1" else { return method + " " + path }
        var template = ["v1"]
        switch parts[1] {
        case "w": template += parts.count == 5 ? ["w", "{w}", "chunks", "{sha}"] : Array(parts.dropFirst())
        case "drives" where parts.count >= 3:
            template += ["drives", "{d}"]
            let rest = Array(parts.dropFirst(3))
            switch rest.count {
            case 2 where rest[0] == "chunks": template += ["chunks", "{sha}"]
            case 3 where rest[0] == "uploads": template += ["uploads", "{u}", "commit"]
            case 3 where rest[0] == "transactions": template += ["transactions", "{tx}", "fence"]
            case 3 where rest[0] == "trash": template += ["trash", "{n}", "restore"]
            default: template += rest
            }
        default: template += Array(parts.dropFirst())
        }
        return method + " /" + template.joined(separator: "/")
    }

    /// The service's strict parser: split on "&" and the first "=", percent-decode, keep "+", reject duplicates.
    static func parseQuery(_ query: String?) -> [String: String]? {
        guard let query, !query.isEmpty else { return [:] }
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let name = String(parts[0]).removingPercentEncoding, let value = String(parts[1]).removingPercentEncoding,
                  values[name] == nil else { return nil }
            values[name] = value
        }
        return values
    }
    static func form(_ body: Data) -> [String: String] {
        parseQuery(String(decoding: body, as: UTF8.self)) ?? [:]
    }
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func token43() -> String { b64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
    static func successor(_ token: String) -> String { "pcr_" + b64url(Data(SHA256.hash(data: Data(("successor:" + token).utf8)))) }
    static func base32() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return String((0..<26).map { _ in alphabet[Int.random(in: 0..<32)] })
    }
    static func nowUs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000) }
    static func date(_ date: Date) -> String { ParaAirCloudJSON.formatDate(date) }
    static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}

/// Shared setup for tests that run the client against the fake.
extension FakeParaAirCloud {
    func dependencies(vault: any ConnectionVault, options: ParaAirCloudSession.Options = .init()) -> EngineOpenDependencies {
        EngineOpenDependencies(cloudVault: vault, cloudConfiguration: configuration, cloudPolicy: .init(allowsLoopbackHTTP: false),
                               cloudSessionOptions: options)
    }

    /// Signs `account` in under `root` with freshly issued tokens and returns the saved record.
    @discardableResult
    func saveAccount(_ account: Account, root: URL, vault: any ConnectionVault, accessTTL: TimeInterval? = nil,
                     id: String = UUID().uuidString.lowercased()) throws -> CloudAccount {
        let record = CloudAccount(id: id, issuer: issuerString, userID: account.userID, email: account.email)
        try CloudAccountStore(root: root).signIn(record, tokens: issueTokens(for: account, accessTTL: accessTTL), vault: vault)
        return try CloudAccountStore(root: root).load(id)
    }

    var tokenRequests: Int { requests("POST /oauth/token").count }
}

/// A unique scratch folder under the package's `.runtime/tests`, removed after the test.
func cloudTestRoot(_ test: XCTestCase) throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".runtime/tests/cloud-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
}

/// Deterministic pseudo-random bytes for content checks.
func seededBytes(_ count: Int, seed: UInt64) -> Data {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for index in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    return data
}

func expectDriveError(_ code: Int32, disposition: CommitDisposition? = nil, file: StaticString = #filePath, line: UInt = #line,
                      _ action: () throws -> Void) {
    XCTAssertThrowsError(try action(), file: file, line: line) { error in
        let drive = error as? DriveError
        XCTAssertEqual(drive?.code, code, "\(error)", file: file, line: line)
        if let disposition { XCTAssertEqual(drive?.disposition, disposition, "\(error)", file: file, line: line) }
    }
}

final class CloudTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}
