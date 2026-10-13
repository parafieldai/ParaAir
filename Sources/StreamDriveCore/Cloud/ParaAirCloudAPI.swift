import Foundation
import CryptoKit
import Darwin

/// A failed call with the service's parsed error code, for callers that react to one.
struct ParaAirCloudCallError: Error {
    var drive: DriveError
    var code: ParaAirCloudErrorCode?
    var missing: [String] = []
    var retryAfterSeconds: Int? = nil
    var requestID: String? = nil
}

/// Typed, blocking endpoint layer for spec 2.5. Retries transient failures,
/// refreshes once on 401 and validates every response before returning it.
public final class ParaAirCloudAPI: @unchecked Sendable {
    public let http: ParaAirCloudHTTP
    private let tokens: any ParaAirCloudTokenProvider
    /// Delays before the second and third attempt (±20%); tests shorten them.
    var retryDelays: [TimeInterval] = [0.25, 1]
    /// Longest `Retry-After` the client waits for before giving up with EAGAIN.
    var maximumRetryAfter: TimeInterval = 5
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// The service's clock minus this Mac's, from the latest reply's `Date` header (1 s resolution).
    /// Read-token expiry is service time (spec 2.7), so it is judged on the service's clock.
    var serviceClockOffset: TimeInterval? { clockLock.lock(); defer { clockLock.unlock() }; return clockOffset }
    private let clockLock = NSLock()
    private var clockOffset: TimeInterval?

    public init(http: ParaAirCloudHTTP, tokens: any ParaAirCloudTokenProvider) {
        self.http = http; self.tokens = tokens
    }

    enum Authorization { case access, read(String), none }
    struct Call {
        var method: String
        var path: String
        var route: String
        var query: [URLQueryItem] = []
        var body: Data? = nil
        var contentType: String? = nil
        var headers: [String: String] = [:]
        var idempotencyKey: UUID? = nil
        var authorization: Authorization = .access
        var phase: ParaAirCloudErrorMap.Phase = .other
        var maxResponseBytes = 4 << 20
        /// Attempts for transient failures (timeouts, 5xx); 1 means no retry.
        var attempts = 3
        var timeout: TimeInterval? = nil
    }

    // MARK: Endpoints

    public func me() throws -> ParaAirCloudMe {
        try unwrap { try decode(ParaAirCloudMe.self, perform(Call(method: "GET", path: "/v1/me", route: "GET /v1/me"))).validated() }
    }

    public func endSession() throws {
        try unwrap { _ = try perform(Call(method: "DELETE", path: "/v1/sessions/current", route: "DELETE /v1/sessions/current")) }
    }

    public func drives() throws -> [ParaAirCloudDrive] {
        struct Body: Decodable { var drives: [ParaAirCloudDrive] }
        return try unwrap { try decode(Body.self, perform(Call(method: "GET", path: "/v1/drives", route: "GET /v1/drives"))).drives.map { try $0.validated() } }
    }

    public func createDrive(workspaceID: String, name: String, idempotencyKey: UUID) throws -> ParaAirCloudDrive {
        struct Body: Decodable { var drive: ParaAirCloudDrive }
        guard ParaAirCloudIDs.isWorkspaceID(workspaceID) else { throw invalidRequest() }
        return try unwrap {
            let call = Call(method: "POST", path: "/v1/drives", route: "POST /v1/drives",
                            body: try json(["workspaceId": workspaceID, "name": name]), idempotencyKey: idempotencyKey)
            let drive = try decode(Body.self, perform(call)).drive.validated()
            guard drive.workspaceId == workspaceID else { throw malformed() }
            return drive
        }
    }

    public func drive(_ driveID: String) throws -> ParaAirCloudDriveDetail {
        try drive(driveID, attempts: 3, timeout: nil)
    }
    /// `attempts: 1` and a short timeout bound callers on the file system's queues (capacity).
    func drive(_ driveID: String, attempts: Int, timeout: TimeInterval?) throws -> ParaAirCloudDriveDetail {
        try unwrap {
            var call = Call(method: "GET", path: "/v1/drives/" + (try checkedDrive(driveID)), route: "GET /v1/drives/{d}")
            call.attempts = attempts; call.timeout = timeout
            let detail = try decode(ParaAirCloudDriveDetail.self, perform(call))
            guard try detail.drive.validated().id == driveID else { throw malformed() }
            return detail
        }
    }

    public func stat(driveID: String, path: String) throws -> FileEntry {
        try unwrap { try rawStat(driveID: driveID, path: path) }
    }
    func rawStat(driveID: String, path: String) throws -> FileEntry {
        struct Body: Decodable { var entry: WireEntry }
        let call = Call(method: "GET", path: "/v1/drives/\(try checkedDrive(driveID))/stat", route: "GET /v1/drives/{d}/stat",
                        query: [URLQueryItem(name: "path", value: path)])
        return try decode(Body.self, perform(call)).entry.fileEntry(expectingPath: path)
    }

    public func listPage(driveID: String, path: String, cursor: String?, limit: Int) throws -> (entries: [FileEntry], nextCursor: String?) {
        struct Body: Decodable { var entries: [WireEntry]; var nextCursor: String? }
        return try unwrap {
            guard (1...5000).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else { throw invalidRequest() }
            var query = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "limit", value: String(limit))]
            if let cursor { query.insert(URLQueryItem(name: "cursor", value: cursor), at: 1) }
            let body = try decode(Body.self, perform(Call(method: "GET", path: "/v1/drives/\(try checkedDrive(driveID))/list",
                                                          route: "GET /v1/drives/{d}/list", query: query)))
            let entries = try body.entries.map { try $0.fileEntry(expectingPath: nil) }
            guard entries.allSatisfy({ Self.parent(of: $0.path) == path && $0.path != "/" }), entries.count <= limit,
                  body.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else { throw malformed() }
            return (entries, body.nextCursor)
        }
    }

    public func mkdir(driveID: String, path: String, idempotencyKey: UUID) throws -> FileEntry {
        struct Body: Decodable { var entry: WireEntry }
        return try unwrap {
            let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/mkdir", route: "POST /v1/drives/{d}/mkdir",
                            body: try json(["path": path]), idempotencyKey: idempotencyKey)
            let entry = try decode(Body.self, perform(call)).entry.fileEntry(expectingPath: path)
            guard entry.kind == .directory else { throw malformed() }
            return entry
        }
    }

    public func move(driveID: String, from: String, to: String, idempotencyKey: UUID) throws -> FileEntry {
        struct Body: Decodable { var entry: WireEntry }
        return try unwrap {
            let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/move", route: "POST /v1/drives/{d}/move",
                            body: try json(["from": from, "to": to]), idempotencyKey: idempotencyKey)
            return try decode(Body.self, perform(call)).entry.fileEntry(expectingPath: to)
        }
    }

    public func remove(driveID: String, path: String, directory: Bool, idempotencyKey: UUID) throws {
        struct Request: Encodable { var path: String; var directory: Bool }
        try unwrap {
            let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/remove", route: "POST /v1/drives/{d}/remove",
                            body: try ParaAirCloudJSON.encoder().encode(Request(path: path, directory: directory)), idempotencyKey: idempotencyKey)
            _ = try perform(call)
        }
    }

    public func manifest(driveID: String, version: String, start: Int, limit: Int) throws -> ParaAirCloudManifestPage {
        try unwrap { try rawManifest(driveID: driveID, version: version, start: start, limit: limit) }
    }
    func rawManifest(driveID: String, version: String, start: Int, limit: Int) throws -> ParaAirCloudManifestPage {
        guard version.range(of: "^p[vd]:[1-9][0-9]{0,15}$", options: .regularExpression) != nil, start >= 0, (1...4096).contains(limit) else {
            throw ParaAirCloudCallError(drive: DriveError(ESTALE, "The file changed on the server", disposition: .attemptNotDispatched), code: .invalidVersion)
        }
        let call = Call(method: "GET", path: "/v1/drives/\(try checkedDrive(driveID))/manifest", route: "GET /v1/drives/{d}/manifest",
                        query: [URLQueryItem(name: "version", value: version), URLQueryItem(name: "start", value: String(start)),
                                URLQueryItem(name: "limit", value: String(limit))])
        let page = try decode(ParaAirCloudManifestPage.self, perform(call)).validated(version: version, start: start)
        guard page.chunks.count <= limit else { throw malformed() }
        return page
    }

    public func readToken(driveID: String) throws -> ParaAirCloudReadToken {
        try unwrap {
            let token = try decode(ParaAirCloudReadToken.self, perform(Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/read-token",
                                                                             route: "POST /v1/drives/{d}/read-token", body: Data("{}".utf8))))
            guard ParaAirCloudIDs.isWorkspaceID(token.workspaceId), ParaAirCloudReadToken.isToken(token.readToken) else { throw malformed() }
            return token
        }
    }

    /// Exactly `expectedLength` bytes: 206 starting at `range.lowerBound`, or 200 for a whole
    /// chunk, which is SHA-256 verified. Authorized by the read token, never the access token.
    public func chunk(workspaceID: String, sha256: String, range: Range<Int>?, readToken: String, expectedLength: Int) throws -> Data {
        try unwrap { try rawChunk(workspaceID: workspaceID, sha256: sha256, range: range, readToken: readToken, expectedLength: expectedLength) }
    }
    func rawChunk(workspaceID: String, sha256: String, range: Range<Int>?, readToken: String, expectedLength: Int) throws -> Data {
        guard ParaAirCloudIDs.isWorkspaceID(workspaceID), ParaAirCloudErrorMap.isSHA256(sha256), expectedLength > 0,
              expectedLength <= ParaAirCloudConfiguration.chunkSize, range.map({ $0.lowerBound >= 0 && $0.count == expectedLength }) ?? true else {
            throw ParaAirCloudCallError(drive: DriveError(EINVAL, "Invalid ParaAir Cloud read", disposition: .attemptNotDispatched), code: nil)
        }
        // Room for an error envelope; a successful body must still be exactly `expectedLength`.
        var call = Call(method: "GET", path: "/v1/w/\(workspaceID)/chunks/\(sha256)", route: "GET /v1/w/{w}/chunks/{sha}",
                        authorization: .read(readToken), maxResponseBytes: max(expectedLength, 64 << 10))
        if let range { call.headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }
        let response = try perform(call)
        guard response.body.count == expectedLength else { throw ParaAirCloudCallError(drive: DriveError(EIO, "ParaAir Cloud returned a short read"), code: nil) }
        if let range {
            let pattern = "^bytes \(range.lowerBound)-\(range.upperBound - 1)/[0-9]+$"
            guard response.status == 206, response.headers["content-range"]?.range(of: pattern, options: .regularExpression) != nil else {
                throw ParaAirCloudCallError(drive: DriveError(EIO, "ParaAir Cloud returned the wrong byte range"), code: nil)
            }
        } else {
            guard response.status == 200, Self.hex(SHA256.hash(data: response.body)) == sha256 else {
                throw ParaAirCloudCallError(drive: DriveError(EIO, "Downloaded data did not match its checksum"), code: nil)
            }
        }
        return response.body
    }

    public func reserve(driveID: String, _ request: ParaAirCloudReserveRequest) throws -> ParaAirCloudReserveResult {
        try unwrap { try rawReserve(driveID: driveID, request) }
    }
    func rawReserve(driveID: String, _ request: ParaAirCloudReserveRequest) throws -> ParaAirCloudReserveResult {
        struct Body: Decodable {
            var state: String; var entry: WireEntry?; var uploadId: String?; var missing: [String]?
            var missingBytes: Int64?; var expiresAt: Date?; var chunkSize: Int?
        }
        guard UUID(uuidString: request.transactionId) != nil, request.transactionId == request.transactionId.lowercased() else {
            throw ParaAirCloudCallError(drive: DriveError(EINVAL, "Invalid upload transaction", disposition: .attemptNotDispatched), code: nil)
        }
        let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/uploads", route: "POST /v1/drives/{d}/uploads",
                        body: try ParaAirCloudJSON.encoder().encode(request), phase: .reserveOrCommit, maxResponseBytes: 8 << 20)
        let body = try decode(Body.self, perform(call))
        switch body.state {
        case "committed":
            guard let entry = body.entry else { throw malformed() }
            return .committed(try entry.fileEntry(expectingPath: request.path))
        case "open":
            let declared = Set(request.chunks.map(\.sha256))
            guard let upload = body.uploadId, ParaAirCloudIDs.isUploadID(upload), let missing = body.missing,
                  missing.allSatisfy({ declared.contains($0) }), Set(missing).count == missing.count,
                  let bytes = body.missingBytes, bytes >= 0, let expires = body.expiresAt,
                  body.chunkSize.map({ $0 == request.chunkSize }) ?? true else { throw malformed() }
            return .open(uploadID: upload, missing: missing, missingBytes: bytes, expiresAt: expires)
        default: throw malformed()
        }
    }

    public func putChunk(driveID: String, uploadID: String, sha256: String, body: Data) throws {
        try unwrap { try rawPutChunk(driveID: driveID, uploadID: uploadID, sha256: sha256, body: body) }
    }
    func rawPutChunk(driveID: String, uploadID: String, sha256: String, body: Data) throws {
        guard ParaAirCloudIDs.isUploadID(uploadID), ParaAirCloudErrorMap.isSHA256(sha256),
              body.count <= ParaAirCloudConfiguration.chunkSize else {
            throw ParaAirCloudCallError(drive: DriveError(EINVAL, "Invalid upload chunk", disposition: .attemptNotDispatched), code: nil)
        }
        let call = Call(method: "PUT", path: "/v1/drives/\(try checkedDrive(driveID))/chunks/\(sha256)", route: "PUT /v1/drives/{d}/chunks/{sha}",
                        query: [URLQueryItem(name: "upload", value: uploadID)], body: body, contentType: "application/octet-stream",
                        maxResponseBytes: 64 << 10)
        _ = try perform(call)
    }

    public func commitUpload(driveID: String, uploadID: String) throws -> ParaAirCloudCommitResult {
        try unwrap { try rawCommit(driveID: driveID, uploadID: uploadID, path: nil) }
    }
    func rawCommit(driveID: String, uploadID: String, path: String?) throws -> ParaAirCloudCommitResult {
        struct Body: Decodable { var entry: WireEntry; var capacity: ParaAirCloudCapacity }
        guard ParaAirCloudIDs.isUploadID(uploadID) else {
            throw ParaAirCloudCallError(drive: DriveError(EINVAL, "Invalid upload", disposition: .attemptNotDispatched), code: nil)
        }
        let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/uploads/\(uploadID)/commit",
                        route: "POST /v1/drives/{d}/uploads/{u}/commit", body: Data("{}".utf8), phase: .reserveOrCommit)
        let body = try decode(Body.self, perform(call))
        return ParaAirCloudCommitResult(entry: try body.entry.fileEntry(expectingPath: path), capacity: body.capacity)
    }

    public func fence(driveID: String, transactionID: String) throws -> ParaAirCloudFenceResult {
        try unwrap { try rawFence(driveID: driveID, transactionID: transactionID, path: nil) }
    }
    func rawFence(driveID: String, transactionID: String, path: String?) throws -> ParaAirCloudFenceResult {
        struct Body: Decodable { var state: String; var entry: WireEntry? }
        guard let uuid = UUID(uuidString: transactionID) else {
            throw ParaAirCloudCallError(drive: DriveError(EINVAL, "Invalid upload transaction", disposition: .attemptNotDispatched), code: nil)
        }
        let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/transactions/\(uuid.uuidString.lowercased())/fence",
                        route: "POST /v1/drives/{d}/transactions/{tx}/fence", body: Data("{}".utf8))
        let body = try decode(Body.self, perform(call))
        switch (body.state, body.entry) {
        case ("fenced", nil): return .fenced
        case ("committed", let entry?): return .committed(try entry.fileEntry(expectingPath: path))
        default: throw malformed()
        }
    }

    public func trash(driveID: String, cursor: String?, limit: Int) throws -> ParaAirCloudTrashPage {
        try unwrap {
            guard (1...5000).contains(limit), cursor.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else { throw invalidRequest() }
            var query = [URLQueryItem(name: "limit", value: String(limit))]
            if let cursor { query.insert(URLQueryItem(name: "cursor", value: cursor), at: 0) }
            let page = try decode(ParaAirCloudTrashPage.self, perform(Call(method: "GET", path: "/v1/drives/\(try checkedDrive(driveID))/trash",
                                                                            route: "GET /v1/drives/{d}/trash", query: query)))
            guard page.items.allSatisfy({ $0.nodeId > 0 && (try? canonicalPath($0.path)) == $0.path && $0.size >= 0 }) else { throw malformed() }
            return page
        }
    }

    public func restore(driveID: String, nodeID: Int64, to: String?, idempotencyKey: UUID) throws -> FileEntry {
        struct Body: Decodable { var entry: WireEntry }
        return try unwrap {
            guard nodeID > 0, nodeID <= WireEntry.maxID else { throw invalidRequest() }
            let fields: [String: String] = to.map { ["to": $0] } ?? [:]
            let call = Call(method: "POST", path: "/v1/drives/\(try checkedDrive(driveID))/trash/\(nodeID)/restore",
                            route: "POST /v1/drives/{d}/trash/{n}/restore", body: try json(fields), idempotencyKey: idempotencyKey)
            return try decode(Body.self, perform(call)).entry.fileEntry(expectingPath: to)
        }
    }

    // MARK: Billing

    /// `GET /v1/billing/offer`: what the service sells, who charges, the current disclosure version and, for
    /// `selection`, the quote whose text the plan sheet shows before checkout (contract README). A quote that does
    /// not answer the selection is malformed; a nil quote means that plan is not sold.
    public func billingOffer(_ selection: ParaAirCloudOfferRequest? = nil) throws -> ParaAirCloudBillingOffer {
        try billing(.offer) {
            guard selection?.isValid ?? true else { throw invalidRequest() }
            let call = Call(method: "GET", path: "/v1/billing/offer", route: "GET /v1/billing/offer", query: selection?.query ?? [],
                            maxResponseBytes: 256 << 10)
            let offer = try decode(ParaAirCloudBillingOffer.self, perform(call))
            if let quote = offer.quote { guard let selection, selection.matches(quote) else { throw malformed() } }
            return offer
        }
    }

    /// `POST /v1/billing/checkout`: the page where the owner pays, already checked by `ParaAirCloudBillingLink`. One
    /// attempt only: every call is a processor session counted against the workspace's hourly limit, and the user can
    /// simply try again. The plan changes when the processor's webhook arrives; reload `/v1/me` afterwards.
    public func billingCheckout(_ request: ParaAirCloudCheckoutRequest) throws -> URL {
        try billing(.checkout) {
            guard request.isValid else { throw invalidRequest() }
            var call = Call(method: "POST", path: "/v1/billing/checkout", route: "POST /v1/billing/checkout", body: try request.body(),
                            maxResponseBytes: 64 << 10)
            call.attempts = 1
            return try link(perform(call), kind: .checkout)
        }
    }

    /// `POST /v1/billing/portal`: the processor's customer portal (payment method, cancel, resume, invoices).
    public func billingPortal(workspaceID: String) throws -> URL {
        try billing(.portal) {
            guard ParaAirCloudIDs.isWorkspaceID(workspaceID) else { throw invalidRequest() }
            var call = Call(method: "POST", path: "/v1/billing/portal", route: "POST /v1/billing/portal",
                            body: try json(["workspaceId": workspaceID]), maxResponseBytes: 64 << 10)
            call.attempts = 1
            return try link(perform(call), kind: .portal)
        }
    }

    private func link(_ response: ParaAirCloudHTTP.Response, kind: ParaAirCloudBillingLink.Kind) throws -> URL {
        struct Body: Decodable { var url: String }
        let body = try decode(Body.self, response)
        do { return try ParaAirCloudBillingLink.validate(body.url, kind: kind, issuer: http.baseURL) }
        catch let error as DriveError { throw ParaAirCloudCallError(drive: error, code: nil) }
    }

    enum BillingCall { case offer, checkout, portal }

    /// Billing answers reuse the error table (contract README "Billing"), whose fixed messages describe files; these
    /// say what the code means for a plan. The errno and disposition stay those of the table.
    private func billing<T>(_ kind: BillingCall, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as ParaAirCloudCallError { throw Self.billingError(error, kind) }
    }

    static func billingError(_ error: ParaAirCloudCallError, _ kind: BillingCall) -> DriveError {
        let text: String
        switch error.code {
        case .notFound?:
            text = kind == .portal ? "This workspace has no paid plan to manage" : "Paid plans aren’t available for this workspace right now"
        case .forbidden?: text = "Only the workspace owner can change its plan"
        case .busy?:
            // A live subscription, or an earlier checkout that was paid while its subscription has not arrived yet.
            text = "This workspace already has a paid plan or a payment that is still going through. Check again in a few minutes, or use Manage Plan"
        case .invalidRequest?: text = "ParaAir Cloud didn’t accept that plan. For Team, choose at least one seat per member"
        case .disclosureOutdated?: text = "The plan terms changed. Read them again and agree to continue"
        case .billingUnavailable?: text = "Paid plans can’t be bought right now. Try again later"
        case .rateLimited?:
            // retryAfterSeconds is clamped when parsed; this division cannot overflow either way.
            let minutes = error.retryAfterSeconds.map { max(1, $0 / 60 + ($0 % 60 == 0 ? 0 : 1)) }
            text = "Too many payment pages were opened for this workspace. "
                + (minutes.map { "Try again in \($0) minute\($0 == 1 ? "" : "s")" } ?? "Try again later")
        case .unavailable?, .internal?, .storageUnavailable?:
            text = "Payments can’t be reached right now. Try again in a few minutes"
        default:
            return error.drive
        }
        let suffix = error.requestID.flatMap(ParaAirCloudErrorMap.validRequestID).map { " (request \($0))" } ?? ""
        return DriveError(error.drive.code, text + suffix, disposition: error.drive.disposition)
    }

    // MARK: Transport

    /// Returns a 2xx response or throws `ParaAirCloudCallError`.
    func perform(_ call: Call) throws -> ParaAirCloudHTTP.Response {
        var request = ParaAirCloudHTTP.Request(method: call.method, path: call.path, query: call.query, headers: call.headers,
                                               body: call.body, maxResponseBytes: call.maxResponseBytes, route: call.route)
        request.timeout = call.timeout
        if call.body != nil { request.headers["Content-Type"] = call.contentType ?? "application/json" }
        if let key = call.idempotencyKey { request.headers["Idempotency-Key"] = key.uuidString.lowercased() }
        var attempt = 0, refreshed = false, retryAfterWaits = 0
        // Once an attempt may have reached the service, a later attempt that never left
        // this Mac cannot prove the request was not applied.
        var maybeApplied = false
        func unsent(_ error: DriveError) -> ParaAirCloudCallError {
            ParaAirCloudCallError(drive: maybeApplied && error.disposition == .attemptNotDispatched ? error.with(.ambiguous) : error, code: nil)
        }
        while true {
            attempt += 1
            let bearer: String?
            switch call.authorization {
            case .access:
                do { bearer = try tokens.accessToken() }
                catch let error as DriveError { throw unsent(error.with(.attemptNotDispatched)) }
            case .read(let token): bearer = token
            case .none: bearer = nil
            }
            let response: ParaAirCloudHTTP.Response
            do { response = try http.sendSync(request, bearer: bearer) }
            catch let error as DriveError {
                if error.disposition == .ambiguous { maybeApplied = true }
                // Connection-level failures put the client in offline backoff; retrying would only fail fast.
                guard error.code != EBADF, error.code != EINVAL, !http.inOfflineBackoff, attempt < call.attempts else { throw unsent(error) }
                pause(attempt); continue
            }
            if let header = response.headers["date"], let date = Self.httpDate.date(from: header) {
                clockLock.lock(); clockOffset = date.timeIntervalSinceNow; clockLock.unlock()
            }
            if (200...299).contains(response.status) { return response }
            let failure = ParaAirCloudErrorMap.parse(status: response.status, body: response.body, headers: response.headers)
            let mapped = ParaAirCloudErrorMap.error(failure, requestID: response.requestID, phase: call.phase)
            if response.status >= 500, mapped.disposition == .ambiguous { maybeApplied = true }
            if response.status == 401, case .access = call.authorization, !refreshed, let bearer {
                refreshed = true; attempt -= 1
                tokens.tokenRejected(bearer)
                continue
            }
            switch failure.code {
            case .rateLimited?, .chunkBusy?:
                let limit = failure.code == .chunkBusy ? 3 : 1
                if let wait = failure.retryAfterSeconds, TimeInterval(wait) <= maximumRetryAfter, retryAfterWaits < limit {
                    retryAfterWaits += 1; attempt -= 1
                    sleep(TimeInterval(wait)); continue
                }
            case nil where response.status >= 500 && response.status != 501 && response.status != 507,
                 .internal?, .storageUnavailable?, .unavailable?:
                if attempt < call.attempts {
                    if let wait = failure.retryAfterSeconds, TimeInterval(wait) <= maximumRetryAfter { sleep(TimeInterval(wait)) } else { pause(attempt) }
                    continue
                }
            default: break
            }
            throw ParaAirCloudCallError(drive: mapped, code: failure.code, missing: failure.missing,
                                        retryAfterSeconds: failure.retryAfterSeconds, requestID: response.requestID)
        }
    }

    /// RFC 9110 IMF-fixdate, the only form a current server sends.
    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private func pause(_ attempt: Int) {
        guard !retryDelays.isEmpty else { return }
        let base = retryDelays[min(attempt - 1, retryDelays.count - 1)]
        sleep(base * Double.random(in: 0.8...1.2))
    }

    private func unwrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as ParaAirCloudCallError { throw error.drive }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ response: ParaAirCloudHTTP.Response) throws -> T {
        do { return try ParaAirCloudJSON.decode(T.self, from: response.body) }
        catch let error as DriveError { throw ParaAirCloudCallError(drive: error, code: nil) }
    }
    private func json(_ fields: [String: String]) throws -> Data { try ParaAirCloudJSON.encoder().encode(fields) }
    private func malformed() -> ParaAirCloudCallError {
        ParaAirCloudCallError(drive: DriveError(EIO, "ParaAir Cloud returned a malformed response", disposition: .ambiguous), code: nil)
    }
    private func invalidRequest() -> ParaAirCloudCallError {
        ParaAirCloudCallError(drive: DriveError(EINVAL, "Invalid ParaAir Cloud request", disposition: .attemptNotDispatched), code: nil)
    }
    private func checkedDrive(_ id: String) throws -> String {
        guard ParaAirCloudIDs.isDriveID(id) else { throw ParaAirCloudCallError(drive: DriveError(ENXIO, "Invalid ParaAir Cloud drive", disposition: .attemptNotDispatched), code: nil) }
        return id
    }
    static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}
