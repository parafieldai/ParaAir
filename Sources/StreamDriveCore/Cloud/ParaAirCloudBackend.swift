import Foundation
import CryptoKit
import Darwin

/// `StorageBackend` over the ParaAir Cloud HTTPS API. Files are lists of 4 MiB
/// content-addressed chunks; reads use cached immutable manifests plus chunk GETs
/// authorized by a short-lived read token. Locks guard only caches and counters;
/// no lock is held across network I/O.
public final class ParaAirCloudBackend: StorageBackend, @unchecked Sendable {
    public struct Options: Sendable {
        public var maxConcurrentChunkUploads = 4
        public var quotaCooldown: TimeInterval = 60
        public var maxListEntries = 500_000
        public var manifestCacheEntries = 64
        public var manifestPage = 4096
        /// How long a capacity answer is reused.
        public var capacityLifetime: TimeInterval = 60
        /// One attempt with this idle timeout: FSKit asks for capacity on its own queue.
        public var capacityTimeout: TimeInterval = 10
        /// How long one upload keeps going after the service first refused a chunk (`putChunks`), waits and further
        /// rounds of PUTs included, before it ends with the last refusal; the engine tries the file again later, and other
        /// files upload meanwhile. Each wait is for a chunk that may go again within `longestChunkWait`.
        public var chunkWaitBudget: TimeInterval = 30
        public var longestChunkWait: TimeInterval = 10
        /// The wait before a refused chunk (`chunk_busy`, throttled, a service error) goes again when the service names a
        /// shorter one or none, doubled for each refusal in a row, up to the service's chunk lease. More than zero.
        public var chunkRetryFloor: TimeInterval = 5
        /// A chunk whose PUT stopped without an answer isn't sent again for this long, unless the service lists it as
        /// stored: the service may keep it for that PUT until its lease runs out.
        public var cutOffChunkWait: TimeInterval = ParaAirCloudConfiguration.chunkLease
        public init() {}
    }

    public static func volumeIdentity(driveID: String) -> String { "paraair-cloud:v1:" + driveID }

    public let driveID: String
    /// The service, known before connecting: a refusal another drive of this process heard covers this one too.
    private let issuer: URL?
    private let options: Options
    private let makeAPI: () throws -> ParaAirCloudAPI
    private let now: () -> Date
    private let lock = NSLock()
    private var apiInstance: ParaAirCloudAPI?
    private var closed = false
    private var manifests: [String: ParaAirCloudManifestPage] = [:]
    private var manifestOrder: [String] = []
    private var token: (workspaceID: String, token: String, expiresAt: Date)?
    private var quotaBlockedUntil: Date?
    private var cachedCapacity: (value: VolumeCapacity, at: Date)?
    /// Transactions whose open upload could not be fenced yet (see `abandon`).
    private var unfenced = Set<String>()
    private var readBytes: Int64 = 0
    private var getRequests: Int64 = 0
    /// Cancelled by `close`: every call in flight stops, including uploads' waits.
    private let stopping = ParaAirCloudCancellation()
    /// The upload in flight per transaction, and the transactions `cancelCommit` stopped.
    private var commitsInFlight: [String: ParaAirCloudCancellation] = [:]
    private var cancelledCommits = Set<String>()
    /// Chunks the service didn't take, by SHA-256, and when each may be sent again (`putChunks`).
    private var holds: [String: ChunkHold] = [:]

    /// No network and no Keychain access: validates the drive id and binds the volume identity. `issuer` is the
    /// service the drive's profile names, so a refusal heard before this drive's first call counts (`updateRequired`).
    public convenience init(driveID: String, session: ParaAirCloudSession, issuer: URL? = nil, options: Options = .init(),
                            bindVolume: (String) throws -> Void) throws {
        try self.init(driveID: driveID, options: options, bindVolume: bindVolume, issuer: issuer,
                      api: { ParaAirCloudAPI(http: try session.http(), tokens: session) })
    }

    init(driveID: String, options: Options = .init(), bindVolume: (String) throws -> Void, issuer: URL? = nil,
         api: @escaping () throws -> ParaAirCloudAPI, now: @escaping () -> Date = { Date() }) throws {
        guard ParaAirCloudIDs.isDriveID(driveID) else { throw DriveError(EINVAL, "Invalid ParaAir Cloud drive identifier") }
        guard options.maxConcurrentChunkUploads > 0, options.manifestCacheEntries > 0, (1...4096).contains(options.manifestPage),
              options.maxListEntries > 0, options.chunkRetryFloor > 0, options.cutOffChunkWait >= 0, options.longestChunkWait >= 0,
              options.chunkWaitBudget >= 0 else { throw DriveError(EINVAL, "Invalid ParaAir Cloud backend options") }
        self.driveID = driveID; self.issuer = issuer; self.options = options; self.makeAPI = api; self.now = now
        try bindVolume(Self.volumeIdentity(driveID: driveID))
    }

    private func api() throws -> ParaAirCloudAPI {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw DriveError(EBADF, "ParaAir Cloud drive is closed", disposition: .attemptNotDispatched) }
        if let apiInstance { return apiInstance }
        let created = try makeAPI()
        created.cancellation = stopping
        apiInstance = created
        return created
    }

    public func stat(_ path: String) throws -> FileEntry {
        try api().stat(driveID: driveID, path: canonicalPath(path))
    }

    /// The service refused this version for its file calls (ParaAirCloudVersionGate), as this process last heard:
    /// through this drive's own client, or, before it has one, through any drive of the same service. No I/O.
    public func updateRequired() -> Bool {
        if let api = lock.withLock({ apiInstance }) { return api.http.versionGate.refusal(for: api.http.baseURL) == .service }
        return issuer.map { ParaAirCloudVersionGate.shared.refusal(for: $0) == .service } ?? false
    }

    /// Every page, deduplicated by path (the last one wins).
    public func list(_ path: String) throws -> [FileEntry] {
        let path = try canonicalPath(path), api = try api()
        var cursor: String?, seen = Set<String>(), byPath: [String: FileEntry] = [:], order: [String] = []
        repeat {
            let page = try api.listPage(driveID: driveID, path: path, cursor: cursor, limit: 5000)
            for entry in page.entries {
                if byPath.updateValue(entry, forKey: entry.path) == nil { order.append(entry.path) }
            }
            guard byPath.count <= options.maxListEntries else { throw DriveError(EIO, "This folder has too many items to list") }
            cursor = page.nextCursor
            if let cursor { guard seen.insert(cursor).inserted else { throw DriveError(EIO, "ParaAir Cloud returned a repeating listing") } }
        } while cursor != nil
        return order.map { byPath[$0]! }
    }

    public func read(_ path: String, offset: Int64, length: Int) throws -> Data {
        let entry = try stat(path)
        guard entry.kind == .file else { throw DriveError(EISDIR, "Cannot read a directory") }
        return try readSnapshot(entry.path, version: entry.version, offset: offset, length: length)
    }

    public func readSnapshot(_ path: String, version: String, offset: Int64, length: Int) throws -> Data {
        _ = try canonicalPath(path)
        guard offset >= 0, length >= 0, offset <= Int64.max - Int64(length) else { throw DriveError(EINVAL, "Invalid read range") }
        if version.hasPrefix("pd:") { throw DriveError(EISDIR, "Cannot read a directory") }
        let api = try api()
        let first = try page(api, version: version, start: 0)
        guard length > 0, offset < first.size else { return Data() }
        let end = min(offset + Int64(length), first.size)
        let chunkSize = Int64(first.chunkSize)
        var result = Data(capacity: Int(end - offset))
        var index = offset / chunkSize
        while index * chunkSize < end {
            let ref = try chunkRef(api, version: version, index: Int(index))
            let start = index * chunkSize, stop = start + Int64(ref.size)
            let lower = max(offset, start) - start, upper = min(end, stop) - start
            let whole = lower == 0 && upper == Int64(ref.size)
            result.append(try fetchChunk(api, workspaceID: first.workspaceId, sha256: ref.sha256,
                                         range: whole ? nil : Int(lower)..<Int(upper), length: Int(upper - lower)))
            index += 1
        }
        return result
    }

    public func commit(_ commit: FileCommit) throws -> FileEntry {
        let api = try api()
        lock.lock(); let blocked = quotaBlockedUntil.map { now() < $0 } ?? false; lock.unlock()
        if blocked { throw DriveError(EDQUOT, "Your ParaAir Cloud storage is full", disposition: .attemptNotDispatched) }
        guard (try? canonicalPath(commit.path)) == commit.path, commit.path != "/" else {
            throw DriveError(EINVAL, "Invalid file path", disposition: .attemptNotDispatched)
        }
        fenceAbandoned(except: commit.transactionID.lowercased(), api: api)
        do {
            return try publish(commit, api: api)
        } catch let error as DriveError {
            if error.code == EDQUOT {
                // The rejection proves the cached capacity wrong; the volume's next ask goes to the service.
                lock.lock(); quotaBlockedUntil = now().addingTimeInterval(options.quotaCooldown); cachedCapacity = nil; lock.unlock()
            }
            throw error
        }
    }

    public func commitStatus(transactionID: String, path: String, expectedVersion: String?) throws -> CommitStatus {
        switch try api().fence(driveID: driveID, transactionID: transactionID) {
        case .fenced: return .absent
        case .committed(let entry): return .applied(entry)
        }
    }

    public func createDirectory(_ path: String) throws -> FileEntry {
        try api().mkdir(driveID: driveID, path: canonicalPath(path), idempotencyKey: UUID())
    }

    public func move(_ source: String, to destination: String) throws {
        _ = try api().move(driveID: driveID, from: canonicalPath(source), to: canonicalPath(destination), idempotencyKey: UUID())
    }

    public func remove(_ path: String, directory: Bool) throws {
        try api().remove(driveID: driveID, path: canonicalPath(path), directory: directory, idempotencyKey: UUID())
        lock.lock(); quotaBlockedUntil = nil; cachedCapacity = nil; lock.unlock()
    }

    /// Quota-style size from `GET /v1/drives/{id}`, reused for `capacityLifetime`.
    /// One attempt bounded by `capacityTimeout`: the volume asks at activation and every 60 s.
    public func capacity() throws -> VolumeCapacity? {
        lock.lock()
        if let cached = cachedCapacity, now().timeIntervalSince(cached.at) < options.capacityLifetime { lock.unlock(); return cached.value }
        lock.unlock()
        let detail = try api().drive(driveID, attempts: 1, timeout: options.capacityTimeout)
        return remember(detail.capacity)
    }

    public func transferMetrics() throws -> TransferMetrics? {
        lock.lock(); defer { lock.unlock() }
        return TransferMetrics(objectReadBytes: readBytes, objectGetRequests: getRequests)
    }

    /// Also stops what is in flight: requests end with ECANCELED and an upload stops where it is (the engine keeps its
    /// change), so an unmounted drive's extension doesn't keep uploading.
    public func close() throws {
        lock.lock(); closed = true; manifests = [:]; manifestOrder = []; token = nil; lock.unlock()
        stopping.cancel()
    }

    public func cancelCommit(transactionID: String, cancelled: Bool) {
        let transaction = transactionID.lowercased()
        lock.lock()
        if cancelled {
            // Each entry is a deleted file's change, which never uploads again; the set only has to outlive the delete.
            if cancelledCommits.count >= 1024 { cancelledCommits.removeAll() }
            cancelledCommits.insert(transaction)
        } else {
            cancelledCommits.remove(transaction)
        }
        let running = cancelled ? commitsInFlight[transaction] : nil
        lock.unlock()
        running?.cancel()
    }

    public func collaboration() throws -> DriveCollaboration? { self }

    /// A write the drive's folder rules or the member's role refuse (403 `forbidden`) is a refused change that waits
    /// for a decision, like one on a read-only drive (EPERM, `UploadRecord.needsDecision`), not a sign-in problem (EACCES).
    static let refusedWriteMessage = "Your ParaAir Cloud access doesn’t allow this change"
    static func writeError(_ error: ParaAirCloudCallError) -> DriveError {
        guard error.code == .forbidden else { return error.drive }
        let suffix = error.requestID.flatMap(ParaAirCloudErrorMap.validRequestID).map { " (request \($0))" } ?? ""
        return DriveError(EPERM, refusedWriteMessage + suffix, disposition: error.drive.disposition)
    }

    // MARK: Reads

    @discardableResult
    private func remember(_ capacity: ParaAirCloudCapacity) -> VolumeCapacity {
        let value = VolumeCapacity(totalBytes: max(0, capacity.quotaBytes), availableBytes: max(0, capacity.availableBytes))
        lock.lock(); cachedCapacity = (value, now()); lock.unlock()
        return value
    }

    private func page(_ api: ParaAirCloudAPI, version: String, containing index: Int64) throws -> ParaAirCloudManifestPage {
        let pageSize = Int64(options.manifestPage)
        return try page(api, version: version, start: Int(index / pageSize * pageSize))
    }

    /// Manifest pages are immutable per (version, start), so they are cached without expiry.
    private func page(_ api: ParaAirCloudAPI, version: String, start: Int) throws -> ParaAirCloudManifestPage {
        let key = version + "@" + String(start)
        lock.lock()
        if let cached = manifests[key] {
            manifestOrder.removeAll { $0 == key }; manifestOrder.append(key)
            lock.unlock(); return cached
        }
        lock.unlock()
        let fetched: ParaAirCloudManifestPage
        do { fetched = try api.rawManifest(driveID: driveID, version: version, start: start, limit: options.manifestPage) }
        catch let error as ParaAirCloudCallError { throw error.drive }
        lock.lock(); defer { lock.unlock() }
        if manifests.updateValue(fetched, forKey: key) == nil { manifestOrder.append(key) }
        while manifestOrder.count > options.manifestCacheEntries { manifests[manifestOrder.removeFirst()] = nil }
        if token.map({ $0.expiresAt < fetched.readTokenExpiresAt }) ?? true {
            token = (fetched.workspaceId, fetched.readToken, fetched.readTokenExpiresAt)
        }
        return fetched
    }

    private func chunkRef(_ api: ParaAirCloudAPI, version: String, index: Int) throws -> ParaAirCloudManifestPage.ChunkRef {
        var current = try page(api, version: version, containing: Int64(index))
        while index >= current.start + current.chunks.count {
            guard let next = current.nextStart, next > current.start else { throw DriveError(EIO, "ParaAir Cloud returned an incomplete file manifest") }
            current = try page(api, version: version, start: next)
        }
        guard index >= current.start else { throw DriveError(EIO, "ParaAir Cloud returned an incomplete file manifest") }
        return current.chunks[index - current.start]
    }

    /// Every chunk of a version, for building the next one.
    private func allChunks(_ api: ParaAirCloudAPI, version: String) throws -> (refs: [ParaAirCloudManifestPage.ChunkRef], workspaceID: String) {
        var current = try page(api, version: version, start: 0)
        var refs = current.chunks
        while let next = current.nextStart {
            guard next == refs.count else { throw DriveError(EIO, "ParaAir Cloud returned an incomplete file manifest") }
            current = try page(api, version: version, start: next)
            refs += current.chunks
        }
        guard refs.count == current.chunkCount else { throw DriveError(EIO, "ParaAir Cloud returned an incomplete file manifest") }
        return (refs, current.workspaceId)
    }

    private func readToken(_ api: ParaAirCloudAPI, workspaceID: String, renew: Bool) throws -> String {
        // Expiry is the service's time, so a fast or slow Mac clock must not shift it.
        let serviceNow = now().addingTimeInterval(api.serviceClockOffset ?? 0)
        lock.lock()
        if !renew, let token, token.workspaceID == workspaceID, token.expiresAt.timeIntervalSince(serviceNow) >= 30 {
            lock.unlock(); return token.token
        }
        lock.unlock()
        let fresh: ParaAirCloudReadToken
        do { fresh = try api.readToken(driveID: driveID) }
        guard fresh.workspaceId == workspaceID else { throw DriveError(EIO, "ParaAir Cloud returned a read token for another workspace") }
        lock.lock(); token = (fresh.workspaceId, fresh.readToken, fresh.expiresAt); lock.unlock()
        return fresh.readToken
    }

    /// One GET per chunk (range or whole); an expired or revoked read token is renewed once.
    private func fetchChunk(_ api: ParaAirCloudAPI, workspaceID: String, sha256: String, range: Range<Int>?, length: Int) throws -> Data {
        var renewed = false
        while true {
            let bearer = try readToken(api, workspaceID: workspaceID, renew: renewed)
            do {
                let data = try api.rawChunk(workspaceID: workspaceID, sha256: sha256, range: range, readToken: bearer, expectedLength: length)
                lock.lock(); readBytes += Int64(data.count); getRequests += 1; lock.unlock()
                return data
            } catch let error as ParaAirCloudCallError {
                lock.lock(); getRequests += 1; lock.unlock()
                if error.code == .unauthorized, !renewed { renewed = true; continue }
                throw error.drive
            }
        }
    }

    // MARK: Commit

    private struct UploadFailure: Error { var error: ParaAirCloudCallError }

    /// A chunk the service didn't take: when it may be sent again, how many refusals in a row, and the latest.
    private struct ChunkHold {
        var until: Date
        var streak: Int
        var error: ParaAirCloudCallError
    }
    /// The chunks a round of `putChunks` left for later: when the first may go again, the latest refusal, and when the
    /// round met its first refusal (a chunk held from before counts from the round's start).
    private struct Deferred {
        var earliest: Date
        var error: ParaAirCloudCallError
        var firstRefusal: Date
    }
    /// How a refused chunk PUT is tried again.
    enum ChunkRefusal: Equatable {
        /// `chunk_busy`: another PUT holds this chunk. After the service's Retry-After; the other chunks go on.
        case busy
        /// Throttled (`rate_limited`): after the service's Retry-After.
        case throttled
        /// The service answered with an error of its own (it frees the chunk first): after a growing wait.
        case serviceError
        /// No answer: a timeout, a lost connection, or a 5xx the service didn't write (Cloudflare's own page when it
        /// stopped the Worker). The PUT may have reached the service, which then keeps the chunk until its lease runs out.
        case cutOff
        /// Every refusal but `busy` is about the service, not the chunk: no further chunks are sent into it this round.
        var stopsOtherChunks: Bool { self != .busy }
    }

    /// Nil for a failure that ends the upload: refused for good (quota, access, upload expired), offline (nothing was
    /// sent; the client fails fast for a while), or stopped on purpose (ECANCELED, a closed client).
    static func chunkRefusal(_ error: ParaAirCloudCallError) -> ChunkRefusal? {
        switch error.code {
        case .chunkBusy?: return .busy
        case .rateLimited?: return .throttled
        case .internal?, .unavailable?, .storageUnavailable?: return .serviceError
        case nil where error.drive.disposition == .ambiguous && error.drive.code != ECANCELED && error.drive.code != EBADF:
            return .cutOff
        default: return nil
        }
    }

    /// The most times one upload asks again which chunks the service lacks after a refusal.
    static let maxChunkRounds = 8

    /// Registers the upload of `transaction` so `cancelCommit` and `close` can stop it.
    private func beginCommit(_ transaction: String) throws -> ParaAirCloudCancellation {
        lock.lock(); defer { lock.unlock() }
        guard !cancelledCommits.contains(transaction) else { throw ParaAirCloudCancellation.stopped(disposition: .attemptNotDispatched) }
        let running = stopping.child()
        commitsInFlight[transaction] = running
        return running
    }
    private func endCommit(_ transaction: String, _ running: ParaAirCloudCancellation) {
        lock.lock(); if commitsInFlight[transaction] === running { commitsInFlight[transaction] = nil }; lock.unlock()
    }

    /// Records that the service didn't take `sha`, and returns when it may be sent again.
    private func hold(_ sha: String, after error: ParaAirCloudCallError, as refusal: ChunkRefusal) -> Date {
        let at = now()
        lock.lock(); defer { lock.unlock() }
        // A refusal long after the last one starts a new streak.
        let previous = holds[sha].flatMap { at.timeIntervalSince($0.until) < ParaAirCloudConfiguration.chunkLease ? $0 : nil }
        let streak = (previous?.streak ?? 0) + 1
        let growing = min(options.chunkRetryFloor * pow(2, Double(min(streak - 1, 16))), ParaAirCloudConfiguration.chunkLease)
        let wait: TimeInterval
        switch refusal {
        case .cutOff: wait = options.cutOffChunkWait
        case .busy, .throttled, .serviceError: wait = max(TimeInterval(error.retryAfterSeconds ?? 0), growing)
        }
        let until = at.addingTimeInterval(wait)
        holds[sha] = ChunkHold(until: until, streak: streak, error: error)
        // Only holds that ended long ago go: few chunks are refused at once, since a refusal of the service stops the
        // round (`ChunkRefusal.stopsOtherChunks`).
        if holds.count > 4096 { holds = holds.filter { at.timeIntervalSince($0.value.until) < ParaAirCloudConfiguration.chunkLease } }
        return until
    }

    /// Spec 2.4: failures before the commit POST is handed to URLSession are
    /// `.attemptNotDispatched`; fencing codes are `.transactionAbsent`; a 5xx or
    /// transport failure of the commit POST itself stays `.ambiguous`.
    private func publish(_ commit: FileCommit, api: ParaAirCloudAPI) throws -> FileEntry {
        func notDispatched(_ error: Error) -> DriveError {
            let drive = (error as? ParaAirCloudCallError).map(Self.writeError) ?? (error as? DriveError) ?? DriveError(EIO, "ParaAir Cloud upload failed")
            return drive.disposition == .transactionAbsent ? drive : drive.with(.attemptNotDispatched)
        }
        let transaction = commit.transactionID.lowercased()
        let running = try beginCommit(transaction)
        defer { endCommit(transaction, running) }
        var base: (refs: [ParaAirCloudManifestPage.ChunkRef], workspaceID: String)?
        let plan: ParaAirCloudChunkPlan
        var hashes: [String] = []
        do {
            if let expected = commit.expectedVersion {
                guard expected.range(of: "^pv:[1-9][0-9]{0,15}$", options: .regularExpression) != nil else {
                    throw DriveError(ESTALE, "The file changed on the server")
                }
                base = try allChunks(api, version: expected)
            }
            plan = try ParaAirCloudChunkPlan.make(commit, base: base?.refs, chunkSize: ParaAirCloudConfiguration.chunkSize)
            for chunk in plan.chunks {
                if case .reuse(let sha) = chunk.source { hashes.append(sha); continue }
                hashes.append(ParaAirCloudAPI.hex(SHA256.hash(data: try build(chunk, api: api, base: base))))
            }
        } catch { throw notDispatched(error) }
        let request = ParaAirCloudReserveRequest(transactionId: transaction, path: commit.path, expectedVersion: commit.expectedVersion,
                                                 finalSize: commit.finalSize, mode: commit.mode & 0o7777,
                                                 chunks: zip(plan.chunks, hashes).map { .init(sha256: $1, size: Int($0.range.count)) })
        var revived = false, missingRetried = false
        // Whether the service may hold an open upload, and its quota reservation, for this transaction.
        var opened = false
        var upload: (id: String, missing: [String])
        func reserve() throws -> FileEntry? {
            let result: ParaAirCloudReserveResult
            // A malformed acknowledgement (a plain DriveError) keeps its ambiguous disposition.
            do { result = try api.rawReserve(driveID: driveID, request, cancellation: running) }
            catch let error as ParaAirCloudCallError {
                if error.drive.disposition == .ambiguous { opened = true }
                throw notDispatched(error)
            }
            switch result {
            case .committed(let entry): return try validated(entry, for: commit)
            case .open(let id, let missing, _, _): upload = (id, missing); opened = true; return nil
            }
        }
        upload = ("", [])
        // When the service first refused a chunk, and rounds since (`Options.chunkWaitBudget`, `maxChunkRounds`): rounds of
        // slow PUTs count too, so a service that keeps cutting PUTs off can't hold the upload forever.
        var firstRefusal: Date?, rounds = 0
        do {
            if let replayed = try reserve() { return replayed }
            while true {
                let left: Deferred?
                do {
                    left = try putChunks(upload.missing, upload: upload.id, plan: plan, hashes: hashes, api: api, base: base, cancellation: running)
                } catch let failure as UploadFailure {
                    if [.uploadExpired, .uploadNotFound].contains(failure.error.code), !revived {
                        revived = true
                        if let replayed = try reserve() { return replayed }
                        continue
                    }
                    throw notDispatched(failure.error)
                } catch { throw notDispatched(error) }
                if let left {
                    // Some chunks wait. If the first may go again soon, wait for it, then ask the service which chunks it
                    // still lacks (a reserve of the same transaction, no bodies): a held chunk another PUT finished meanwhile
                    // is never sent again. Otherwise the upload ends here and the engine tries the file later.
                    // Counted from the refusal itself, so other chunks uploading in that round don't hide the time.
                    let at = now()
                    let since = min(firstRefusal ?? left.firstRefusal, left.firstRefusal)
                    firstRefusal = since; rounds += 1
                    let delay = max(0, left.earliest.timeIntervalSince(at))
                    guard delay <= options.longestChunkWait, at.timeIntervalSince(since) + delay <= options.chunkWaitBudget,
                          rounds <= Self.maxChunkRounds else { throw notDispatched(left.error) }
                    guard running.wait(delay) else { throw ParaAirCloudCancellation.stopped(disposition: .attemptNotDispatched) }
                    if let replayed = try reserve() { return replayed }
                    continue
                }
                do {
                    let result = try api.rawCommit(driveID: driveID, uploadID: upload.id, path: commit.path, cancellation: running)
                    remember(result.capacity)
                    return try validated(result.entry, for: commit)
                } catch let error as ParaAirCloudCallError {
                    if error.code == .chunksMissing, !missingRetried, !error.missing.isEmpty {
                        missingRetried = true; upload.missing = error.missing; continue
                    }
                    if [.uploadExpired, .uploadNotFound].contains(error.code), !revived {
                        revived = true
                        if let replayed = try reserve() { return replayed }
                        continue
                    }
                    throw Self.writeError(error)
                }
            }
        } catch let error as DriveError where opened && error.disposition == .attemptNotDispatched {
            return try abandon(transaction, after: error, for: commit, api: api)
        }
    }

    /// Spec 2.6 U4: fencing a transaction deletes its open upload and releases the upload's quota
    /// reservation. The engine may retry under a new transaction id, and the service matches open
    /// uploads only by id, so an attempt that ends before its commit POST fences now (or, if the
    /// service is unreachable, before the next commit) instead of holding the quota until the
    /// upload expires (12 h). Uploaded chunks stay stored, so a new attempt sends only the rest.
    private func abandon(_ transaction: String, after failure: DriveError, for commit: FileCommit, api: ParaAirCloudAPI) throws -> FileEntry {
        let state: ParaAirCloudFenceResult
        do { state = try api.rawFence(driveID: driveID, transactionID: transaction, path: nil) }
        catch { lock.lock(); unfenced.insert(transaction); lock.unlock(); throw failure }
        // An earlier attempt of this transaction was published after all.
        if case .committed(let entry) = state { return try validated(entry, for: commit) }
        throw failure
    }

    /// Fences transactions `abandon` could not, stopping at the first failure. `current` is being
    /// retried under the same identity: reserve resumes its upload instead.
    private func fenceAbandoned(except current: String, api: ParaAirCloudAPI) {
        lock.lock(); unfenced.remove(current); let waiting = unfenced; lock.unlock()
        for transaction in waiting {
            guard (try? api.rawFence(driveID: driveID, transactionID: transaction, path: nil)) != nil else { return }
            lock.lock(); unfenced.remove(transaction); lock.unlock()
        }
    }

    private func validated(_ entry: FileEntry, for commit: FileCommit) throws -> FileEntry {
        guard entry.path == commit.path, entry.kind == .file, entry.size == commit.finalSize else {
            throw DriveError(EIO, "ParaAir Cloud acknowledged a different file", disposition: .ambiguous)
        }
        return entry
    }

    /// Builds one chunk; base bytes come from the base version's chunk (a ranged GET when partial).
    private func build(_ chunk: ParaAirCloudChunkPlan.Chunk, api: ParaAirCloudAPI,
                       base: (refs: [ParaAirCloudManifestPage.ChunkRef], workspaceID: String)?) throws -> Data {
        try ParaAirCloudChunkPlan.bytes(chunk) { range in
            guard let base, chunk.index < base.refs.count else { throw DriveError(EIO, "Base content is unavailable") }
            let ref = base.refs[chunk.index]
            let lower = Int(range.lowerBound - chunk.range.lowerBound), upper = Int(range.upperBound - chunk.range.lowerBound)
            guard lower >= 0, upper <= ref.size, lower < upper else { throw DriveError(EIO, "Base content is unavailable") }
            let whole = lower == 0 && upper == ref.size
            return try fetchChunk(api, workspaceID: base.workspaceID, sha256: ref.sha256, range: whole ? nil : lower..<upper, length: upper - lower)
        }
    }

    /// Uploads the missing chunks, at most `maxConcurrentChunkUploads` at a time, each built just before its PUT so at
    /// most that many chunks are resident. A chunk the service refuses for now (`chunkRefusal`) is held (`hold`) and left
    /// for later, and so is one still held from an earlier refusal, whose body isn't sent at all. A busy chunk doesn't
    /// stop the others; a refusal of the service (throttled, its own error, a cut-off) stops sending further chunks this
    /// round, and those not sent wait unheld for the next round. Returns what was left, or nil when the service has
    /// every chunk. Any other failure stops the upload.
    private func putChunks(_ missing: [String], upload: String, plan: ParaAirCloudChunkPlan, hashes: [String], api: ParaAirCloudAPI,
                           base: (refs: [ParaAirCloudManifestPage.ChunkRef], workspaceID: String)?,
                           cancellation: ParaAirCloudCancellation) throws -> Deferred? {
        var firstIndex: [String: Int] = [:]
        for (index, sha) in hashes.enumerated() where firstIndex[sha] == nil { firstIndex[sha] = index }
        let indices = try missing.map { sha -> Int in
            guard let index = firstIndex[sha] else { throw DriveError(EIO, "ParaAir Cloud asked for unknown data") }
            return index
        }
        var left: Deferred?
        func leave(_ until: Date, _ error: ParaAirCloudCallError, at refused: Date) {
            left = Deferred(earliest: min(left?.earliest ?? until, until), error: error, firstRefusal: min(left?.firstRefusal ?? refused, refused))
        }
        let started = now()
        var work: [Int] = []
        lock.lock()
        for index in indices {
            if let held = holds[hashes[index]], held.until > started { leave(held.until, held.error, at: started) } else { work.append(index) }
        }
        lock.unlock()
        guard !work.isEmpty else { return left }
        let state = NSLock()
        var next = 0
        var failure: Error?
        var serviceRefused = false
        DispatchQueue.concurrentPerform(iterations: min(options.maxConcurrentChunkUploads, work.count)) { _ in
            while true {
                state.lock()
                guard failure == nil, !serviceRefused, next < work.count else { state.unlock(); return }
                if cancellation.isCancelled {
                    failure = ParaAirCloudCancellation.stopped(disposition: .attemptNotDispatched); state.unlock(); return
                }
                let index = work[next]; next += 1
                state.unlock()
                do {
                    var resent = false
                    while true {
                        let chunk = plan.chunks[index]
                        let bytes = try build(chunk, api: api, base: base)
                        guard ParaAirCloudAPI.hex(SHA256.hash(data: bytes)) == hashes[index] else {
                            throw DriveError(EIO, "Pending local data changed during upload")
                        }
                        do {
                            try api.rawPutChunk(driveID: driveID, uploadID: upload, sha256: hashes[index], body: bytes, cancellation: cancellation)
                            lock.lock(); holds[hashes[index]] = nil; lock.unlock()
                            break
                        } catch let error as ParaAirCloudCallError {
                            if [.sizeMismatch, .chunkHashMismatch].contains(error.code), !resent { resent = true; continue }
                            guard let refusal = Self.chunkRefusal(error) else { throw UploadFailure(error: error) }
                            let refused = now(), until = hold(hashes[index], after: error, as: refusal)
                            state.lock(); leave(until, error, at: refused); if refusal.stopsOtherChunks { serviceRefused = true }; state.unlock()
                            break
                        }
                    }
                } catch {
                    state.lock(); if failure == nil { failure = error }; state.unlock()
                    return
                }
            }
        }
        if let failure { throw failure }
        return left
    }
}

extension ParaAirCloudBackend: DriveCollaboration {
    public func changes(since: Int64?, limit: Int) throws -> ParaAirCloudChangePage {
        try api().changes(driveID: driveID, since: since, limit: limit)
    }
    public func recordConflictCopy(_ record: ParaAirCloudConflictRecord) throws {
        try api().recordConflictCopy(driveID: driveID, record)
    }
    public func conflictCopy(at path: String) throws -> ParaAirCloudConflictRecord? {
        try api().conflictCopy(driveID: driveID, path: canonicalPath(path))
    }
    public func changeStream(_ handler: @escaping @Sendable (ParaAirCloudChangeStream.Event) -> Void) throws -> ParaAirCloudChangeStream? {
        try api().changeStream(driveID: driveID, handler: handler)
    }
}
