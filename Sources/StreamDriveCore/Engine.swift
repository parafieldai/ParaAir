import Foundation
import CryptoKit
import Darwin

public struct UploadRecord: Codable, Sendable {
    public var transactionID: String
    public var path: String
    public var logicalSize: Int64
    public var pendingBytes: Int64
    public var state: String
    public var lastError: String?
    public var lastErrno: Int32?
    /// Failed upload attempts since the file last changed identity or published.
    public var failures = 0
    /// Wall-clock nanoseconds of the first failure in the current run of failures.
    public var failingSinceNanoseconds: Int64?
    /// Wall-clock nanoseconds of the oldest change waiting in this file, and of the latest.
    public var pendingSinceNanoseconds: Int64?
    public var modifiedNanoseconds: Int64?
    public init(transactionID: String, path: String, logicalSize: Int64, pendingBytes: Int64, state: String, lastError: String?,
                lastErrno: Int32?, failures: Int = 0, failingSinceNanoseconds: Int64? = nil, pendingSinceNanoseconds: Int64? = nil,
                modifiedNanoseconds: Int64? = nil) {
        self.transactionID = transactionID; self.path = path; self.logicalSize = logicalSize; self.pendingBytes = pendingBytes
        self.state = state; self.lastError = lastError; self.lastErrno = lastErrno; self.failures = failures
        self.failingSinceNanoseconds = failingSinceNanoseconds; self.pendingSinceNanoseconds = pendingSinceNanoseconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// Sequential prefetch window; `maxBlocks == 0` disables readahead.
public struct ReadaheadPolicy: Sendable, Equatable {
    public var maxBlocks: Int
    public var maxConcurrent: Int
    public init(maxBlocks: Int, maxConcurrent: Int) { self.maxBlocks = maxBlocks; self.maxConcurrent = maxConcurrent }
    public static let disabled = ReadaheadPolicy(maxBlocks: 0, maxConcurrent: 0)
    public static let standard = ReadaheadPolicy(maxBlocks: 8, maxConcurrent: 2)
}

/// Per-backend engine behaviour. `.byo` matches the engine's historical defaults.
public struct EngineTuning: Sendable, Equatable {
    public var readahead: ReadaheadPolicy
    public var metadataLifetimeNanoseconds: Int64
    public init(readahead: ReadaheadPolicy = .disabled, metadataLifetimeNanoseconds: Int64 = 1_000_000_000) {
        self.readahead = readahead; self.metadataLifetimeNanoseconds = metadataLifetimeNanoseconds
    }
    public static let byo = EngineTuning()
    public static let paraairCloud = EngineTuning(readahead: .standard, metadataLifetimeNanoseconds: 5_000_000_000)
}

/// Which pending files one flush may publish. `.background` uploads only files that
/// are closed and idle, or every file once the journal is under pressure, and
/// honours each file's retry backoff. `.immediate` publishes everything now.
public struct UploadPolicy: Sendable, Equatable {
    public var closedIdleNanoseconds: Int64
    public var openIdleNanoseconds: Int64
    /// Journal use, as a fraction of its limit, at which recent and open files upload too.
    public var pressureFraction: Double
    public var respectsBackoff: Bool
    public init(closedIdleNanoseconds: Int64, openIdleNanoseconds: Int64, pressureFraction: Double, respectsBackoff: Bool) {
        self.closedIdleNanoseconds = closedIdleNanoseconds; self.openIdleNanoseconds = openIdleNanoseconds
        self.pressureFraction = pressureFraction; self.respectsBackoff = respectsBackoff
    }
    public static let immediate = UploadPolicy(closedIdleNanoseconds: 0, openIdleNanoseconds: 0, pressureFraction: 0, respectsBackoff: false)
    public static let background = UploadPolicy(closedIdleNanoseconds: 2_000_000_000, openIdleNanoseconds: 30_000_000_000,
                                               pressureFraction: 0.5, respectsBackoff: true)
}

/// When a drive whose index lives only on this Mac backs that index up into its own
/// storage: once changes have been quiet for a while, or soon after the first change
/// when they keep coming, and never sooner than `minIntervalNanoseconds` after the last
/// backup. The hour matches JuiceFS's default, which its rotation (every dump of the
/// last two days is kept) assumes. Failures retry after `retryNanoseconds`, doubling to
/// an hour; an index too large for its storage (EFBIG) retries after a day.
public struct IndexBackupPolicy: Sendable, Equatable {
    public var quietNanoseconds: Int64
    public var maxDelayNanoseconds: Int64
    public var minIntervalNanoseconds: Int64
    public var retryNanoseconds: Int64
    public init(quietNanoseconds: Int64, maxDelayNanoseconds: Int64, minIntervalNanoseconds: Int64, retryNanoseconds: Int64) {
        self.quietNanoseconds = quietNanoseconds; self.maxDelayNanoseconds = maxDelayNanoseconds
        self.minIntervalNanoseconds = minIntervalNanoseconds; self.retryNanoseconds = retryNanoseconds
    }
    public static let standard = IndexBackupPolicy(quietNanoseconds: 120_000_000_000, maxDelayNanoseconds: 900_000_000_000,
                                                   minIntervalNanoseconds: 3_600_000_000_000, retryNanoseconds: 300_000_000_000)
    public static let immediate = IndexBackupPolicy(quietNanoseconds: 0, maxDelayNanoseconds: 0, minIntervalNanoseconds: 0, retryNanoseconds: 0)
}

/// Another Mac recovered this drive and owns it now: this Mac reads it but refuses new
/// changes, because they could never upload.
public struct OwnedElsewhere: Codable, Sendable, Equatable {
    public var ownerName: String?
    /// Wall-clock nanoseconds when this Mac learned it.
    public var seenNanoseconds: Int64
}

/// The last index backup of a drive whose index lives only on this Mac.
public struct IndexBackupStatus: Codable, Sendable, Equatable {
    /// Wall-clock nanoseconds of the last successful backup.
    public var lastBackupNanoseconds: Int64?
    /// Set while changes that reached storage are not in a backup yet.
    public var pendingSinceNanoseconds: Int64?
    public var lastError: String?
    public var lastErrno: Int32?
    public init(lastBackupNanoseconds: Int64? = nil, pendingSinceNanoseconds: Int64? = nil, lastError: String? = nil, lastErrno: Int32? = nil) {
        self.lastBackupNanoseconds = lastBackupNanoseconds; self.pendingSinceNanoseconds = pendingSinceNanoseconds
        self.lastError = lastError; self.lastErrno = lastErrno
    }
}

public struct PinStatus: Codable, Sendable {
    public var path: String
    public var complete: Bool
    public var fileCount: Int
    public var lastError: String?
}

public struct DriveStatus: Codable, Sendable {
    public var cacheBytes: Int64
    public var pinnedBytes: Int64
    public var pendingWriteBytes: Int64
    public var stateBytes: Int64
    public var totalAllocatedBytes: Int64
    public var cacheLimitBytes: Int64
    public var maxJournalBytes: Int64
    public var minFreeBytes: Int64
    public var availableBytes: Int64
    public var pendingUploads: Int
    public var conflictedUploads: Int
    public var pins: [PinStatus]
    public var offline: Bool
    /// Cumulative object payload bytes/GETs observed by this client state.
    /// Excludes metadata traffic and transport overhead; not a NIC counter.
    public var objectReadBytes: Int64
    public var objectGetRequests: Int64
    /// Nil for drives whose index is not on this Mac (ParaAir Cloud, local folders).
    public var indexBackup: IndexBackupStatus? = nil
    /// Set once another Mac owns the drive.
    public var ownedElsewhere: OwnedElsewhere? = nil
    /// Files whose uploads keep failing (UploadFailurePolicy.standard).
    public var failingUploads: UploadFailureSummary? = nil
}

private struct Segment: Codable { var offset: Int64; var length: Int64; var blob: String }
private struct Journal: Codable {
    var transactionID: String
    var path: String
    var base: FileEntry?
    var size: Int64
    var baseVisibleSize: Int64
    var modified: Int64
    var id: UInt64
    var mode: UInt32
    var segments: [Segment]
    var accessed: Int64? = nil
    // Once a transaction has reached the backend, its identity and contents
    // must stay fixed until its outcome is reconciled after an ambiguous error.
    var sealed: Bool = false
    var state: String = "pending"
    var lastError: String?
    var lastErrno: Int32?
    // Optional so older binaries' journals decode; they drop these on re-encode,
    // and nil reads as the safe value. nil means "may have applied".
    var mayHaveApplied: Bool? = nil
    var failures: Int? = nil
    /// Wall-clock nanoseconds before which background flushes skip this file.
    var nextAttemptAt: Int64? = nil
    /// Wall-clock nanoseconds of the first change, and of the first failure in the current
    /// run of failed uploads. Nil in journals written before they were recorded.
    var createdAt: Int64? = nil
    var failingSince: Int64? = nil
    var pendingLength: Int64 { segments.reduce(0) { $0 + $1.length } }
    var entry: FileEntry {
        FileEntry(id: id, path: path, kind: .file, size: size, modifiedNanoseconds: modified,
                  version: "local:" + transactionID + ":" + String(modified), mode: mode,
                  accessedNanoseconds: accessed ?? base?.accessedNanoseconds ?? base?.modifiedNanoseconds ?? modified)
    }
}
private struct Block: Codable {
    var key: String
    var path: String
    var version: String
    var offset: Int64
    var length: Int
    var accessed: Int64
}
private struct Metadata: Codable { var entry: FileEntry; var verified: Int64 }
/// Stored as record ("index", "backup"). `notNeeded` once storage reports that the
/// index is not local, so no further changes are tracked.
private struct IndexBackupState: Codable {
    var changedAt: Int64?
    var firstChangeAt: Int64?
    var lastBackupAt: Int64?
    var lastAttemptAt: Int64?
    var lastKey: String?
    var lastError: String?
    var lastErrno: Int32?
    var failures = 0
    var notNeeded = false
}

/// One in-progress block fetch. Readers of the same block wait for it instead of
/// fetching again. It stays registered until the fetched block is published, so
/// a reader arriving later finds the block in the cache.
private final class BlockFlight: @unchecked Sendable {
    let isPrefetch: Bool
    private let group = DispatchGroup()
    private var outcome: Result<Data, Error>?
    init(isPrefetch: Bool) { self.isPrefetch = isPrefetch; group.enter() }
    func finish(_ result: Result<Data, Error>) { outcome = result; group.leave() }
    func wait() -> Result<Data, Error> { group.wait(); return outcome! }
}

/// Sequential-read detection for one path.
private struct ReadStream {
    /// Offset just past the previous read; the next read continues the stream if it starts here.
    var next: Int64
    /// Readahead window in blocks; zero until the stream is known to be sequential.
    var window = 0
    /// Prefetches are queued up to this offset (exclusive).
    var scheduled: Int64 = 0
    /// Queued prefetches of an older generation skip their fetch.
    var generation: UInt64
    var lastUse: UInt64
}

/// What one read needs after the state lock is released: the overlay is already
/// filled in; `fetches` lists base blocks to copy from, cached or not.
private struct ReadPlan {
    struct Fetch { var offset: Int64; var key: String; var cachedLength: Int?; var ranges: [Range<Int64>] }
    var base: FileEntry?
    var result: Data
    var fetches: [Fetch]
    var hasJournal: Bool
    var end: Int64
}

/// The same durable state is shared by the CLI and FSKit process. A process
/// lock covers database changes and filesystem publication; WAL + FULL sync
/// acknowledges writes only after the immutable payload and journal are durable.
///
/// Lock order: legacyUploadLock (shared) -> per-path upload lock -> state lock -> memory.
/// Network calls never run under `memory`; uploads never run under the state lock.
public final class Engine {
    private let backend: StorageBackend
    private let publisher: StorageBackend
    private let root: URL
    private let cache: URL
    private let journal: URL
    private let db: Database
    private let lock: StateLock
    /// `upload.lock`, taken shared by every upload-lock holder. Older binaries take
    /// it exclusively, which keeps mixed versions mutually exclusive.
    private let legacyUploadLock: SharedStateLock
    private let uploadLocks: URL
    /// Guards the in-memory maps below; never held across I/O.
    private let memory = NSLock()
    private var pathLocks: [String: StateLock] = [:]
    /// Uptime of each path's last local write, for idle detection without wall-clock jumps.
    private var lastWrite: [String: UInt64] = [:]
    private var lastProbe: UInt64?
    private var indexBackupRunning = false
    /// The last ownership answer and its uptime, for 10 s.
    private var ownershipChecked: (uptime: UInt64, value: OwnedElsewhere?)?
    private let cacheLimit: Int64
    private let reserve: Int64
    private let blockSize: Int
    private let journalLimit: Int64
    private var offline = false
    /// Bumped under the state lock by create, move, remove and publication. A listing
    /// fetched across a change is returned but not recorded; so is an entry whose
    /// metadata a move or remove may have cleared meanwhile.
    private var namespaceEpoch: UInt64 = 0
    private let tuning: EngineTuning
    private var metadataLifetime: Int64 { tuning.metadataLifetimeNanoseconds }
    // Guarded by `memory`.
    private var flights: [String: BlockFlight] = [:]
    private var trafficSeen: [ObjectIdentifier: TransferMetrics] = [:]
    private var unrecordedTraffic = TransferMetrics()
    private var streams: [String: ReadStream] = [:]
    private var streamGenerations: UInt64 = 0
    /// Sequential readahead; idle unless `tuning.readahead.maxBlocks > 0`.
    private let prefetchQueue = OperationQueue()

    public init(backend: StorageBackend, stateDirectory: URL,
                cacheLimitBytes: Int64 = 1_073_741_824, minFreeBytes: Int64 = 5_368_709_120,
                blockSize: Int = 1_048_576, maxJournalBytes: Int64 = 4_294_967_296,
                publishingBackend: StorageBackend? = nil, tuning: EngineTuning = .byo) throws {
        guard stateDirectory.isFileURL, cacheLimitBytes >= 0, minFreeBytes >= 0,
              blockSize >= 4096, blockSize <= 8 * 1024 * 1024,
              maxJournalBytes >= 0 else { throw DriveError(EINVAL, "Invalid drive cache or journal configuration") }
        guard tuning.metadataLifetimeNanoseconds >= 0, tuning.readahead.maxBlocks >= 0,
              tuning.readahead.maxConcurrent >= 0 else { throw DriveError(EINVAL, "Invalid drive engine tuning") }
        self.backend = backend; publisher = publishingBackend ?? backend; root = stateDirectory; self.tuning = tuning
        prefetchQueue.name = "dev.streamdrive.engine.readahead"
        prefetchQueue.qualityOfService = .utility
        prefetchQueue.maxConcurrentOperationCount = max(1, tuning.readahead.maxConcurrent)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        cacheLimit = cacheLimitBytes; reserve = minFreeBytes; self.blockSize = blockSize; journalLimit = maxJournalBytes
        try DurableIO.directory(root)
        lock = try StateLock(root.appendingPathComponent("state.lock"))
        legacyUploadLock = try SharedStateLock(root.appendingPathComponent("upload.lock"))
        uploadLocks = root.appendingPathComponent("uploads", isDirectory: true)
        db = try lock.withLock { [cache, journal, uploadLocks, root] in
            try DurableIO.directory(cache); try DurableIO.directory(journal); try DurableIO.directory(uploadLocks)
            return try Database(root.appendingPathComponent("state.sqlite3"))
        }
        try lock.withLock { try reconcileBlockSize(); try recoverOrphans(); try trimCache(to: cacheLimit) }
    }
    deinit { prefetchQueue.cancelAllOperations() }

    /// Cached blocks and offline pin snapshots are cut at one block size. When a
    /// profile's size changes, release both and record the new size.
    private func reconcileBlockSize() throws {
        let marker = root.appendingPathComponent("block.size"), wanted = String(blockSize)
        var info = Darwin.stat()
        if lstat(marker.path, &info) == 0 {
            if info.st_mode & S_IFMT == S_IFREG, info.st_size <= 32,
               let stored = try? String(contentsOf: marker, encoding: .utf8),
               stored.trimmingCharacters(in: .whitespacesAndNewlines) == wanted { return }
            try db.transaction {
                try db.clear("block")
                let pins: [PinStatus] = try db.all("pin")
                for var pin in pins {
                    pin.complete = false; pin.lastError = "Block size changed; pin again to refresh the offline snapshot"
                    try db.put("pin", pin.path, pin)
                }
            }
            // recoverOrphans, run next, deletes the cache files these rows owned.
        } else if errno != ENOENT { throw DriveError(errno, "Cannot read the drive block size") }
        try DurableIO.write(Data(wanted.utf8), to: marker)
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000_000_000) }
    private func contains(_ parent: String, _ path: String) -> Bool {
        parent == "/" || path == parent || path.hasPrefix(parent + "/")
    }
    private func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent }
    private func isOfflineError(_ error: Error) -> Bool {
        guard let code = (error as? DriveError)?.code else { return false }
        return [EIO, ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNRESET, ECONNREFUSED, ETIMEDOUT, ENOTCONN].contains(code)
    }
    /// Records metadata learned from a publication or namespace change.
    private func record(_ entry: FileEntry) throws {
        if let previous: Metadata = try db.get("metadata", entry.path), previous.entry.version != entry.version {
            try invalidatePins(under: entry.path)
        }
        try db.put("metadata", entry.path, Metadata(entry: entry, verified: now()))
    }
    /// Records metadata fetched by a request that started at `started`, unless
    /// newer metadata was recorded meanwhile or the path has a journal, whose base
    /// must not move. A pin refreshing its own files passes itself as `exceptPin`.
    private func recordFetched(_ entry: FileEntry, started: Int64, exceptPin: String? = nil) throws {
        if let _: Journal = try db.get("journal", entry.path) { return }
        if let previous: Metadata = try db.get("metadata", entry.path) {
            if previous.verified > started { return }
            if previous.entry.version != entry.version { try invalidatePins(under: entry.path, except: exceptPin) }
        }
        try db.put("metadata", entry.path, Metadata(entry: entry, verified: now()))
    }
    /// Under the state lock: whether a single-entry refresh that began at `epoch` may
    /// record what it found. Move and remove clear all metadata, so if `path` has
    /// metadata now, either neither ran since, or it was recorded after the request
    /// began and recordFetched keeps it. Other changes are per path, as recordFetched checks.
    private func unchanged(_ path: String, since epoch: UInt64) throws -> Bool {
        if namespaceEpoch == epoch { return true }
        return (try db.get("metadata", path) as Metadata?) != nil
    }
    /// Refreshes `path`'s metadata when it is older than the metadata lifetime, with
    /// the network call outside the state lock. Returns the entry it fetched; nil when
    /// a journal or fresh metadata answers, or when offline with metadata to fall back on.
    @discardableResult
    private func refreshMetadataIfNeeded(_ path: String, force: Bool = false, exceptPin: String? = nil) throws -> FileEntry? {
        // Housekeeping files exist only in the local journal; storage is never asked.
        if Housekeeping.staysLocal(path) {
            guard try lock.withLock(timeout: 10, { (try db.get("journal", path) as Journal?) != nil }) else {
                throw DriveError(ENOENT, "No such file")
            }
            return nil
        }
        let (needed, epoch, hasCache) = try lock.withLock(timeout: 10) { () -> (Bool, UInt64, Bool) in
            if let _: Journal = try db.get("journal", path) { return (false, namespaceEpoch, true) }
            let cached: Metadata? = try db.get("metadata", path)
            if !force, let cached, now() - cached.verified < metadataLifetime { return (false, namespaceEpoch, true) }
            return (true, namespaceEpoch, cached != nil)
        }
        guard needed else { return nil }
        let started = now()
        do {
            let entry = try backend.stat(path)
            try lock.withLock(timeout: 10) {
                offline = false
                if try unchanged(path, since: epoch) { try recordFetched(entry, started: started, exceptPin: exceptPin) }
            }
            return entry
        } catch {
            if isOfflineError(error), hasCache { try lock.withLock(timeout: 10) { offline = true }; return nil }
            if (error as? DriveError)?.code == ENOENT {
                try lock.withLock(timeout: 10) {
                    guard try unchanged(path, since: epoch), (try db.get("journal", path) as Journal?) == nil else { return }
                    if let stored: Metadata = try db.get("metadata", path), stored.verified > started { return }
                    try db.delete("metadata", path); try invalidatePins(under: path, except: exceptPin)
                }
            }
            throw error
        }
    }
    /// The current entry, refreshed outside the lock and answered under it.
    private func currentEntry(_ path: String) throws -> FileEntry {
        for attempt in 0..<3 {
            let fetched = try refreshMetadataIfNeeded(path, force: attempt > 0)
            let answer: FileEntry? = try lock.withLock(timeout: 10) {
                if let pending: Journal = try db.get("journal", path) { return pending.entry }
                if let cached: Metadata = try db.get("metadata", path) { return cached.entry }
                return fetched
            }
            if let answer { return answer }
        }
        throw DriveError(EBUSY, "The drive namespace is changing; retry")
    }
    public func stat(_ value: String) throws -> FileEntry {
        try currentEntry(canonicalPath(value))
    }
    public func list(_ value: String) throws -> [FileEntry] {
        try list(canonicalPath(value), exceptPin: nil)
    }
    /// Lists outside the state lock and records the result under it, unless the
    /// namespace changed meanwhile.
    private func list(_ path: String, exceptPin: String?) throws -> [FileEntry] {
        if Housekeeping.staysLocal(path) {
            _ = try currentEntry(path) // ENOENT when absent
            throw DriveError(ENOTDIR, "Not a directory")
        }
        let (started, epoch) = try lock.withLock(timeout: 10) { (now(), namespaceEpoch) }
        var entries: [FileEntry]
        do {
            entries = try backend.list(path).filter { !Housekeeping.hides($0) }
            try lock.withLock(timeout: 10) {
                offline = false
                guard namespaceEpoch == epoch else { return }
                try db.transaction {
                    if let previous: [FileEntry] = try db.get("listing", path), Set(previous.map(\.path)) != Set(entries.map(\.path)) {
                        try invalidatePins(under: path, except: exceptPin)
                    }
                    for entry in entries { try recordFetched(entry, started: started, exceptPin: exceptPin) }
                    try db.put("listing", path, entries)
                }
            }
        } catch {
            guard isOfflineError(error), let saved: [FileEntry] = try lock.withLock(timeout: 10, { try db.get("listing", path) }) else { throw error }
            try lock.withLock(timeout: 10) { offline = true }
            // Listings saved by earlier versions may still name housekeeping files.
            entries = saved.filter { !Housekeeping.hides($0) }
        }
        return try lock.withLock(timeout: 10) {
            let pending: [Journal] = try db.all("journal")
            var byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            for item in pending where parent(item.path) == path { byPath[item.path] = item.entry }
            return byPath.values.sorted { $0.name < $1.name }
        }
    }

    /// Reads plan under the state lock with local I/O only, fetch base blocks
    /// outside it, and retry from fresh metadata when the remote file changes.
    public func read(_ value: String, offset: Int64, length: Int) throws -> Data {
        let path = try canonicalPath(value)
        guard offset >= 0, length >= 0, length <= 64 * 1024 * 1024,
              offset <= Int64.max - Int64(length) else { throw DriveError(EINVAL, "Invalid read range (maximum 64 MiB per call)") }
        var attempt = 0
        while true {
            attempt += 1
            let fetched = try refreshMetadataIfNeeded(path, force: attempt > 1)
            guard let plan = try lock.withLock(timeout: 10, { try planRead(path, offset: offset, length: length, fetched: fetched) }) else {
                // The metadata vanished between the refresh and the plan.
                if attempt < 3 { continue }
                throw DriveError(EBUSY, "The drive namespace is changing; retry")
            }
            if let base = plan.base { readahead(path, entry: base, offset: offset, end: plan.end, hasJournal: plan.hasJournal) }
            do { return try assemble(plan, offset: offset) }
            catch where (error as? DriveError)?.code == ESTALE && attempt < 3 {}
        }
    }
    /// Under the state lock. Fills in journal bytes now, because publication deletes
    /// their blobs, and lists the base blocks to copy. Nil when no metadata is known.
    private func planRead(_ path: String, offset: Int64, length: Int, fetched: FileEntry?) throws -> ReadPlan? {
        let pending: Journal? = try db.get("journal", path)
        let stored: Metadata? = pending == nil ? try db.get("metadata", path) : nil
        guard let entry = pending?.entry ?? stored?.entry ?? fetched else { return nil }
        guard entry.kind == .file else { throw DriveError(EISDIR, "Cannot read a directory") }
        if offset >= entry.size || length == 0 { return ReadPlan(base: nil, result: Data(), fetches: [], hasJournal: pending != nil, end: offset) }
        let count = Int(min(Int64(length), entry.size - offset))
        var result = Data(count: count)
        let end = offset + Int64(count)
        let visible = pending?.baseVisibleSize ?? entry.size
        let base = pending?.base ?? (pending == nil ? entry : nil)
        // Only fetch base regions not fully covered by local writes. This
        // allows new files and complete overwrites to be read while offline.
        let visibleEnd = min(end, visible)
        var uncovered: [Range<Int64>] = visibleEnd > offset ? [offset..<visibleEnd] : []
        if let pending {
            for segment in pending.segments {
                let covered = segment.offset..<(segment.offset + segment.length)
                uncovered = uncovered.flatMap { range -> [Range<Int64>] in
                    if !range.overlaps(covered) { return [range] }
                    var pieces: [Range<Int64>] = []
                    if range.lowerBound < covered.lowerBound { pieces.append(range.lowerBound..<covered.lowerBound) }
                    if range.upperBound > covered.upperBound { pieces.append(covered.upperBound..<range.upperBound) }
                    return pieces
                }
            }
        }
        var fetches: [ReadPlan.Fetch] = []
        if let base {
            let size = Int64(blockSize), clock = now()
            for range in uncovered {
                var at = range.lowerBound
                while at < range.upperBound {
                    let blockOffset = at / size * size, stop = min(range.upperBound, blockOffset + size)
                    if fetches.last?.offset == blockOffset { fetches[fetches.count - 1].ranges.append(at..<stop) }
                    else {
                        let key = blockKey(base, offset: blockOffset)
                        var cachedLength: Int?
                        if var row: Block = try db.get("block", key) {
                            cachedLength = row.length
                            // Recency for eviction; at most one update per block per second.
                            if clock - row.accessed > 1_000_000_000 { row.accessed = clock; try db.put("block", key, row) }
                        }
                        fetches.append(.init(offset: blockOffset, key: key, cachedLength: cachedLength, ranges: [at..<stop]))
                    }
                    at = stop
                }
            }
        }
        if let pending {
            for segment in pending.segments {
                let start = max(offset, segment.offset), stop = min(end, segment.offset + segment.length)
                if start < stop {
                    let bytes = try readLocal(journal.appendingPathComponent(segment.blob), offset: start - segment.offset, length: Int(stop - start))
                    result.replaceSubrange(Int(start - offset)..<Int(stop - offset), with: bytes)
                }
            }
        }
        return ReadPlan(base: base, result: result, fetches: fetches, hasJournal: pending != nil, end: end)
    }
    /// Outside the state lock: copies each planned base block into the result.
    /// Base ranges never overlap journal segments, so the order does not matter.
    private func assemble(_ plan: ReadPlan, offset: Int64) throws -> Data {
        var result = plan.result
        guard let base = plan.base else { return result }
        for fetch in plan.fetches {
            let bytes = try block(base, offset: fetch.offset, key: fetch.key, cachedLength: fetch.cachedLength)
            for range in fetch.ranges {
                let inside = Int(range.lowerBound - fetch.offset), take = Int(range.upperBound - range.lowerBound)
                guard inside + take <= bytes.count else { throw DriveError(EIO, "Backend returned a short file range") }
                let start = bytes.startIndex + inside
                result.replaceSubrange(Int(range.lowerBound - offset)..<Int(range.upperBound - offset), with: bytes[start..<(start + take)])
            }
        }
        return result
    }
    private func blockKey(_ entry: FileEntry, offset: Int64) -> String {
        let identity = entry.path + "\0" + entry.version + "\0" + String(offset) + "\0" + String(blockSize)
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// A cache file is immutable for its key, so it may be read without the state lock.
    private func cachedBlock(_ key: String, length: Int) -> Data? {
        try? readLocal(cache.appendingPathComponent(key), offset: 0, length: length)
    }
    /// One base block: from the cache when present, otherwise fetched once for all
    /// concurrent readers and published. Never called under the state lock.
    private func block(_ entry: FileEntry, offset: Int64, key: String, cachedLength: Int?,
                       mustPersist: Bool = false, isPrefetch: Bool = false) throws -> Data {
        let count = Int(min(Int64(blockSize), entry.size - offset))
        guard count > 0 else { return Data() }
        if let bytes = cachedBlock(key, length: cachedLength ?? count) { return bytes }
        return try singleFlight(key, isPrefetch: isPrefetch) {
            // A flight that finished after the plan may have published this block.
            if let bytes = cachedBlock(key, length: count) { return bytes }
            let source = backend
            baselineTraffic(source)
            let bytes: Data
            do { bytes = try source.readSnapshot(entry.path, version: entry.version, offset: offset, length: count) }
            catch {
                recordTraffic(on: source)
                if !isPrefetch, isOfflineError(error) { try? lock.withLock(timeout: 10) { offline = true } }
                throw error
            }
            recordTraffic(on: source)
            guard bytes.count == count else { throw DriveError(EIO, "Backend returned a short file range") }
            try lock.withLock(timeout: 10) { try publish(entry, offset: offset, key: key, bytes: bytes, mustPersist: mustPersist) }
            return bytes
        }
    }
    private func singleFlight(_ key: String, isPrefetch: Bool, _ fetch: () throws -> Data) throws -> Data {
        while true {
            let (flight, leads) = memory.withLock { () -> (BlockFlight, Bool) in
                if let existing = flights[key] { return (existing, false) }
                let made = BlockFlight(isPrefetch: isPrefetch); flights[key] = made
                return (made, true)
            }
            if leads {
                let result = Result { try fetch() }
                memory.withLock { flights[key] = nil }
                flight.finish(result)
                return try result.get()
            }
            switch flight.wait() {
            case .success(let bytes): return bytes
            case .failure(let error):
                // A failed prefetch never fails the reader that joined it.
                guard flight.isPrefetch, !isPrefetch else { throw error }
            }
        }
    }
    /// Under the state lock: caches a fetched block, but never puts a superseded
    /// version into pinned space.
    private func publish(_ entry: FileEntry, offset: Int64, key: String, bytes: Data, mustPersist: Bool) throws {
        offline = false
        try persistTraffic()
        if let row: Block = try db.get("block", key) {
            // A row whose cache file was deleted outside the engine is cached again.
            if cachedBlock(key, length: row.length) != nil { return }
            try db.delete("block", key)
        }
        let pinned = try pinPaths().contains { contains($0, entry.path) }
        if pinned, let current: Metadata = try db.get("metadata", entry.path), current.entry.version != entry.version {
            if mustPersist { throw DriveError(ESTALE, "File changed while pinning") }
            return
        }
        let estimate = (Int64(bytes.count) + 4095) / 4096 * 4096
        if !pinned { try trimCache(to: max(0, cacheLimit - estimate)) }
        let free = try DurableIO.freeBytes(root)
        let canCache = (pinned || estimate <= cacheLimit) && free - estimate - 65_536 >= reserve
        if canCache {
            try DurableIO.write(bytes, to: cache.appendingPathComponent(key))
            try db.put("block", key, Block(key: key, path: entry.path, version: entry.version, offset: offset, length: bytes.count, accessed: now()))
            if !pinned { try trimCache(to: cacheLimit) }
        } else if mustPersist { throw DriveError(ENOSPC, "Pin would exceed the local free-space reserve") }
    }

    @discardableResult public func write(_ value: String, offset: Int64, data: Data) throws -> Int {
        let path = try canonicalPath(value)
        try refuseIfOwnedElsewhere(path)
        let wrote: Int = try withWritableJournal(path) { original in
            guard offset >= 0, data.count <= 64 * 1024 * 1024, offset <= Int64.max - Int64(data.count) else {
                throw DriveError(EINVAL, "Invalid write range (maximum 64 MiB per call)")
            }
            var pending = original
            if data.isEmpty { return 0 }
            try ensureJournalSpace(Int64(data.count), drainable: true)
            let blob = UUID().uuidString + ".data"
            try DurableIO.write(data, to: journal.appendingPathComponent(blob))
            pending.segments.append(Segment(offset: offset, length: Int64(data.count), blob: blob))
            pending.size = max(pending.size, offset + Int64(data.count)); pending.modified = now()
            try db.transaction { try db.put("journal", path, pending); try invalidatePins(under: path) }
            return data.count
        }
        touched(path)
        return wrote
    }
    public func create(_ value: String, directory: Bool) throws -> FileEntry {
        let path = try canonicalPath(value)
        try refuseIfOwnedElsewhere(path)
        if Housekeeping.isRefused(path) || (directory && Housekeeping.isLocalOnly(path)) {
            throw DriveError(EACCES, "macOS system folders are not stored on this drive")
        }
        // Existence checks may refresh metadata, so they run before the state lock.
        do { _ = try stat(path); throw DriveError(EEXIST, "Path already exists") }
        catch let error as DriveError where error.code == ENOENT {} // Only a confirmed missing path permits creation.
        if !directory { guard try stat(parent(path)).kind == .directory else { throw DriveError(ENOTDIR, "Parent is not a directory") } }
        return try lock.withLock {
            if let _: Journal = try db.get("journal", path) { throw DriveError(EEXIST, "Path already exists") }
            namespaceEpoch &+= 1
            if directory {
                let entry = try backend.createDirectory(path); noteIndexChange(); try record(entry); try invalidateListings(); return entry
            }
            try ensureJournalSpace(0)
            let timestamp = now()
            let pending = Journal(transactionID: UUID().uuidString, path: path, base: nil, size: 0,
                                  baseVisibleSize: 0, modified: timestamp, id: UInt64.random(in: (1 << 62)..<UInt64.max),
                                  mode: 0o644, segments: [], accessed: timestamp, mayHaveApplied: false, createdAt: timestamp)
            try db.transaction { try db.put("journal", path, pending); try invalidatePins(under: path) }
            touched(path)
            return pending.entry
        }
    }
    public func truncate(_ value: String, size: Int64) throws {
        let path = try canonicalPath(value)
        try refuseIfOwnedElsewhere(path)
        try withWritableJournal(path) { original in
            guard size >= 0 else { throw DriveError(EINVAL, "Negative file size") }
            var pending = original
            try ensureJournalSpace(0, drainable: true)
            pending.size = size; pending.baseVisibleSize = min(pending.baseVisibleSize, size); pending.modified = now()
            pending.segments = pending.segments.compactMap { segment in
                guard segment.offset < size else { return nil }
                var clipped = segment; clipped.length = min(clipped.length, size - segment.offset); return clipped
            }
            try db.transaction { try db.put("journal", path, pending); try invalidatePins(under: path) }
            try recoverOrphans()
        }
        touched(path)
    }
    private enum JournalAccess<T> { case done(T), sealed, metadataMissing }
    private func withWritableJournal<T>(_ path: String, _ body: (Journal) throws -> T) throws -> T {
        var drains = 0, missing = 0
        while true {
            // A new journal's base comes from metadata refreshed outside the state lock.
            let fetched = try refreshMetadataIfNeeded(path, force: missing > 0)
            let access: JournalAccess<T>
            do {
                access = try lock.withLock {
                    if let existing: Journal = try db.get("journal", path) {
                        if existing.sealed { return .sealed }
                        return .done(try body(existing))
                    }
                    let stored: Metadata? = try db.get("metadata", path)
                    guard let base = stored?.entry ?? fetched else { return .metadataMissing }
                    guard base.kind == .file else { throw DriveError(EISDIR, "Cannot modify a directory") }
                    let timestamp = now()
                    return .done(try body(Journal(transactionID: UUID().uuidString, path: path, base: base, size: base.size,
                                                  baseVisibleSize: base.size, modified: timestamp, id: base.id, mode: base.mode, segments: [],
                                                  mayHaveApplied: false, createdAt: timestamp)))
                }
            } catch is JournalFull {
                // Publishing other files can make room. No state lock is held here.
                // Offline, nothing can drain, so fail at once.
                guard drains < 2, try !lock.withLock({ offline }) else {
                    throw DriveError(ENOSPC, "Pending-write journal limit reached; upload before writing more")
                }
                drains += 1
                _ = try flushUploads(policy: .immediate)
                continue
            }
            switch access {
            case .done(let result): return result
            case .metadataMissing:
                missing += 1
                guard missing < 3 else { throw DriveError(EBUSY, "The drive namespace is changing; retry") }
            case .sealed:
                // The writer never uploads. It waits only for an in-flight upload of
                // this file, then settles a sealed journal through the commit fence.
                try resolveSealed(path)
            }
        }
    }

    /// Settles a sealed journal left by an earlier upload attempt, under this
    /// path's upload lock and outside the state lock. Never uploads.
    private func resolveSealed(_ path: String) throws {
        try legacyUploadLock.withShared {
            let pathLock = try uploadLock(for: path)
            try pathLock.withLock {
                guard let item: Journal = try lock.withLock({ try db.get("journal", path) }) else { return }
                if item.state == "conflict" { throw DriveError(ESTALE, Self.conflictMessage) }
                guard item.sealed else { return }
                let status: CommitStatus
                do {
                    status = try publisher.commitStatus(transactionID: item.transactionID, path: path, expectedVersion: item.base?.version)
                } catch let error as DriveError where error.code == ESTALE {
                    try lock.withLock {
                        guard var current: Journal = try db.get("journal", path), current.transactionID == item.transactionID else { return }
                        current.state = "conflict"; current.lastErrno = ESTALE
                        current.lastError = "Remote file changed; local data is retained"
                        try db.put("journal", path, current)
                    }
                    throw error
                } catch {
                    if isOfflineError(error) { try lock.withLock { offline = true } }
                    status = .unknown
                }
                switch status {
                case .applied(let entry):
                    try lock.withLock {
                        guard let current: Journal = try db.get("journal", path), current.transactionID == item.transactionID else { return }
                        try db.transaction { try db.delete("journal", path); try record(entry); try invalidateListings() }
                        namespaceEpoch &+= 1; offline = false; noteIndexChange(); try recoverOrphans()
                    }
                    published(path, lock: pathLock, sealedAt: DispatchTime.now().uptimeNanoseconds)
                case .absent:
                    try rotate(path, transactionID: item.transactionID)
                case .unknown:
                    guard item.mayHaveApplied == false else {
                        throw DriveError(EIO, "The previous upload of this file has an unknown outcome. Your changes are kept and will upload when the connection returns.")
                    }
                    try rotate(path, transactionID: item.transactionID)
                }
            }
        }
    }
    /// Gives an unpublished journal a fresh identity so writers can append again.
    private func rotate(_ path: String, transactionID: String) throws {
        try lock.withLock {
            guard var current: Journal = try db.get("journal", path), current.transactionID == transactionID else { return }
            rotate(&current)
            try db.put("journal", path, current)
        }
    }
    private func rotate(_ item: inout Journal) {
        item.sealed = false; item.transactionID = UUID().uuidString; item.mayHaveApplied = false
    }

    public func fsync(_ value: String) throws {
        try syncOne(canonicalPath(value))
    }
    /// Returns remaining uploads, including conflicts; successful publications
    /// disappear from this list. Failures never discard acknowledged local data.
    /// `isOpenForWriting` is never called while the state lock is held.
    public func flushUploads(policy: UploadPolicy = .immediate, isOpenForWriting: (String) -> Bool = { _ in false }) throws -> [UploadRecord] {
        assert(!lock.isHeldByCurrentThread, "Uploads must not run under the drive state lock")
        if policy.respectsBackoff, try !reachableForBackgroundUpload() { return try uploads() }
        let (pending, used): ([Journal], Int64) = try lock.withLock { (try db.all("journal"), try directoryAllocation(journal)) }
        let pressure = Double(used) >= policy.pressureFraction * Double(journalLimit)
        let clock = now(), uptime = DispatchTime.now().uptimeNanoseconds
        let writes = memory.withLock { lastWrite }
        var eligible: [(item: Journal, cutoff: Int64)] = []
        for item in pending where item.state != "conflict" && !Housekeeping.staysLocal(item.path) {
            if policy.respectsBackoff, let next = item.nextAttemptAt, clock < next { continue }
            if item.sealed || pressure { eligible.append((item, .max)); continue }
            // After a restart only the persisted wall-clock modification time is known.
            let idle = writes[item.path].map { uptime > $0 ? Int64(clamping: uptime - $0) : 0 } ?? max(0, clock - item.modified)
            let threshold = isOpenForWriting(item.path) ? policy.openIdleNanoseconds : policy.closedIdleNanoseconds
            // A write after this check moves `modified` past the cutoff and skips the file.
            if idle >= threshold { eligible.append((item, item.modified)) }
        }
        if pressure { eligible.sort { $0.item.pendingLength > $1.item.pendingLength } }
        else { eligible.sort { $0.item.modified < $1.item.modified } }
        for candidate in eligible { do { try syncOne(candidate.item.path, modifiedNoLaterThan: candidate.cutoff) } catch {} }
        let remaining = try uploads()
        // Storage refused uploads as read-only: learn whether another Mac took the drive.
        if remaining.contains(where: { $0.lastErrno == EROFS }) { _ = try? ownedElsewhere(refresh: true) }
        return remaining
    }
    /// Background passes do nothing while offline, probing at most every 15 s.
    /// BYO metadata is local, so its probe always succeeds and backoff applies instead.
    private func reachableForBackgroundUpload() throws -> Bool {
        guard try lock.withLock({ offline }) else { return true }
        let uptime = DispatchTime.now().uptimeNanoseconds
        let due = memory.withLock { () -> Bool in
            if let last = lastProbe, uptime &- last < 15_000_000_000 { return false }
            lastProbe = uptime; return true
        }
        guard due else { return false }
        do { _ = try backend.stat("/") }
        catch { return !isOfflineError(error) }
        try lock.withLock { offline = false }
        return true
    }
    private func syncOne(_ path: String, modifiedNoLaterThan cutoff: Int64 = .max) throws {
        assert(!lock.isHeldByCurrentThread, "Uploads must not run under the drive state lock")
        guard !Housekeeping.staysLocal(path) else { return }
        try legacyUploadLock.withShared {
        let pathLock = try uploadLock(for: path)
        try pathLock.withLock {
        // Whether an earlier attempt of this identity may already have published.
        var prior = true
        guard var pending: Journal = try lock.withLock({
            guard var item: Journal = try db.get("journal", path) else { return nil }
            if item.state == "conflict" { throw DriveError(ESTALE, Self.conflictMessage) }
            if !item.sealed && item.modified > cutoff { return nil }
            prior = item.mayHaveApplied ?? true
            item.sealed = true; item.mayHaveApplied = true
            try db.put("journal", path, item); return item
        }) else { return }
        let sealedAt = DispatchTime.now().uptimeNanoseconds
        let commit = FileCommit(transactionID: pending.transactionID, path: path, expectedVersion: pending.base?.version,
                                finalSize: pending.size, baseVisibleSize: pending.baseVisibleSize, mode: pending.mode,
                                extents: pending.segments.map { WriteExtent(offset: $0.offset, length: $0.length, blobURL: journal.appendingPathComponent($0.blob)) })
        baselineTraffic(publisher)
        do {
            let published: FileEntry
            do { published = try publisher.commit(commit); recordTraffic(on: publisher) }
            catch { recordTraffic(on: publisher); throw error }
            try lock.withLock {
                try db.transaction { try db.delete("journal", path); try record(published); try invalidateListings() }
                // Published: a failed cleanup is not a failed upload. Later passes reclaim the payloads.
                namespaceEpoch &+= 1; offline = false; noteIndexChange(); try? persistTraffic(); try? recoverOrphans()
            }
            self.published(path, lock: pathLock, sealedAt: sealedAt)
        } catch {
            // A namespace errno from the publishing step is ambiguous. Once the commit
            // fence reports this transaction absent, it is a namespace rejection.
            var disposition = (error as? DriveError)?.disposition ?? .ambiguous
            if disposition == .ambiguous, let code = (error as? DriveError)?.code, [ENOENT, ENOTDIR, EISDIR].contains(code),
               (try? publisher.commitStatus(transactionID: commit.transactionID, path: path, expectedVersion: commit.expectedVersion)) == .absent {
                disposition = .transactionAbsent
            }
            try lock.withLock {
            let failure = error as? DriveError
            let code = failure?.code ?? EIO
            switch (code, disposition) {
            case (ESTALE, _), (EEXIST, _):
                pending.state = "conflict"
            case (ENOENT, .transactionAbsent), (ENOTDIR, .transactionAbsent), (EISDIR, .transactionAbsent):
                // The namespace changed under the file; the journal is kept as a conflict.
                pending.state = "conflict"
            case (_, .transactionAbsent):
                rotate(&pending)
            case (_, .attemptNotDispatched) where !prior:
                rotate(&pending)
            default:
                // Ambiguous, or not dispatched after an attempt that may have
                // applied: keep this identity so a replay hits its receipt.
                pending.mayHaveApplied = true
            }
            let failures = (pending.failures ?? 0) + 1, clock = now()
            pending.failures = failures
            if pending.failingSince == nil { pending.failingSince = clock }
            pending.nextAttemptAt = clock + min(900_000_000_000, Int64(2_000_000_000) << Int64(min(failures - 1, 9)))
            pending.lastErrno = code
            pending.lastError = "Remote commit failed (errno \(code)); local data is retained"
            if isOfflineError(error) { offline = true }
            try? persistTraffic()
            // Write back only over the transaction this attempt sealed (before any rotation
            // above). Once it is gone, a writer may have started a new one, which must stay.
            if let current: Journal = try db.get("journal", path), current.transactionID == commit.transactionID {
                try db.put("journal", path, pending)
            }
            }
            throw error
        }
        }
        }
    }
    /// The per-path upload lock: `<state>/uploads/<sha256(path)>.lock`. At most
    /// 1,024 are cached; the cache drops paths that no longer have journals.
    private func uploadLock(for path: String) throws -> StateLock {
        if let cached = memory.withLock({ pathLocks[path] }) { return cached }
        let live: Set<String>? = memory.withLock({ pathLocks.count >= 1024 })
            ? Set(try lock.withLock { () -> [Journal] in try db.all("journal") }.map(\.path)) : nil
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".lock"
        let made = try StateLock(uploadLocks.appendingPathComponent(name), replaceable: true)
        return memory.withLock {
            if let cached = pathLocks[path] { return cached }
            if let live { pathLocks = pathLocks.filter { live.contains($0.key) } }
            if pathLocks.count < 1024 { pathLocks[path] = made }
            return made
        }
    }
    /// After a publication, while still holding the path lock: drop its lock file
    /// and idle record unless a newer write arrived.
    private func published(_ path: String, lock pathLock: StateLock, sealedAt: UInt64) {
        let pending = (try? lock.withLock { () -> Journal? in try db.get("journal", path) }) ?? nil
        guard pending == nil else { return }
        pathLock.removeFileWhileHeld()
        memory.withLock {
            pathLocks[path] = nil
            if let written = lastWrite[path], written <= sealedAt { lastWrite[path] = nil }
        }
    }
    private func touched(_ path: String) {
        let uptime = DispatchTime.now().uptimeNanoseconds
        memory.withLock { lastWrite[path] = uptime }
    }
    public func uploads() throws -> [UploadRecord] {
        try lock.withLock {
            let pending: [Journal] = try db.all("journal")
            return pending.filter { !Housekeeping.staysLocal($0.path) }.map { item in
                UploadRecord(transactionID: item.transactionID, path: item.path, logicalSize: item.size,
                             pendingBytes: item.segments.reduce(0) { $0 + DurableIO.allocatedBytes(journal.appendingPathComponent($1.blob)) },
                             state: item.state, lastError: item.lastError, lastErrno: item.lastErrno, failures: item.failures ?? 0,
                             failingSinceNanoseconds: item.failingSince, pendingSinceNanoseconds: item.createdAt ?? item.modified,
                             modifiedNanoseconds: item.modified)
            }
        }
    }
    /// Backend volume size, or nil when the backend reports none. Available space
    /// excludes the local journal, which still has to upload.
    public func capacity() throws -> VolumeCapacity? {
        guard var value = try backend.capacity() else { return nil }
        let pending = try lock.withLock { try uploadableJournalAllocation() }
        value.availableBytes = max(0, value.availableBytes - pending)
        return value
    }
    public func move(_ source: String, to destination: String) throws {
        let from = try canonicalPath(source), to = try canonicalPath(destination)
        try refuseIfOwnedElsewhere(from)
        if Housekeeping.isRefused(from) { throw DriveError(ENOENT, "No such file") }
        if Housekeeping.isRefused(to) { throw DriveError(EACCES, "macOS system folders are not stored on this drive") }
        let localFrom = Housekeeping.isLocalOnly(from), localTo = Housekeeping.isLocalOnly(to)
        if localFrom || localTo {
            // AppleDouble companions follow their file's renames, so both ends stay on this Mac.
            guard localFrom && localTo else { throw DriveError(EACCES, "macOS housekeeping files stay on this Mac") }
            return try moveLocal(from, to: to)
        }
        if from == to, from != "/" { _ = try stat(from); return }
        guard from != "/", to != "/", !contains(from, to) else { throw DriveError(EINVAL, "Invalid rename") }
        try settleChanges(under: [from, to])
        try lock.withLock {
            // Namespace changes require connectivity. Flush affected files first
            // so rename cannot orphan a journal or erase an acknowledged save.
            let pending: [Journal] = try db.all("journal")
            guard !pending.contains(where: { !Housekeeping.staysLocal($0.path) && (contains(from, $0.path) || contains(to, $0.path)) }) else {
                throw DriveError(EBUSY, "File changed during rename preparation; retry after saving")
            }
            namespaceEpoch &+= 1
            try backend.move(from, to: to)
            noteIndexChange()
            try rekeyLocalFiles(pending, from: from, to: to)
            try db.clear("metadata"); try invalidateListings()
            // Cached content remains evictable; pin snapshots must be recreated.
            try invalidatePins(under: from); try invalidatePins(under: to)
        }
    }
    public func remove(_ value: String, directory: Bool) throws {
        let path = try canonicalPath(value)
        try refuseIfOwnedElsewhere(path)
        guard path != "/" else { throw DriveError(EBUSY, "Cannot remove the drive root") }
        if Housekeeping.staysLocal(path) {
            try lock.withLock {
                guard (try db.get("journal", path) as Journal?) != nil else { throw DriveError(ENOENT, "No such file") }
                namespaceEpoch &+= 1
                try db.delete("journal", path); try recoverOrphans()
            }
            return
        }
        try settleChanges(under: [path])
        try lock.withLock {
            let pending: [Journal] = try db.all("journal")
            guard !pending.contains(where: { !Housekeeping.staysLocal($0.path) && contains(path, $0.path) }) else {
                throw DriveError(EBUSY, "File changed during removal preparation; retry after saving")
            }
            namespaceEpoch &+= 1
            do { try backend.remove(path, directory: directory) }
            catch let error as DriveError where directory && error.code == ENOTEMPTY {
                // Earlier versions stored housekeeping files. They are hidden now, but
                // storage still counts them, so a folder holding only those is emptied.
                let leftovers = try backend.list(path)
                guard !leftovers.isEmpty, leftovers.allSatisfy(Housekeeping.hides) else { throw error }
                for entry in leftovers { try backend.remove(entry.path, directory: entry.kind == .directory) }
                try backend.remove(path, directory: true)
            }
            noteIndexChange()
            try db.transaction {
                for item in pending where Housekeeping.staysLocal(item.path) && contains(path, item.path) { try db.delete("journal", item.path) }
            }
            try recoverOrphans()
            try db.clear("metadata"); try invalidateListings(); try invalidatePins(under: path)
        }
    }
    /// Renames a local-only file. The destination folder must exist; an existing
    /// local-only destination is replaced, as rename(2) does.
    private func moveLocal(_ from: String, to: String) throws {
        _ = try stat(parent(to))
        try lock.withLock {
            guard var item: Journal = try db.get("journal", from) else { throw DriveError(ENOENT, "No such file") }
            guard from != to else { return }
            namespaceEpoch &+= 1
            item.path = to
            try db.transaction { try db.delete("journal", from); try db.put("journal", to, item) }
            try recoverOrphans()
        }
        touched(to)
    }
    /// After a rename in storage, local-only files inside `from` follow it, and those
    /// inside a replaced `to` go with it.
    private func rekeyLocalFiles(_ pending: [Journal], from: String, to: String) throws {
        let local = pending.filter { Housekeeping.staysLocal($0.path) }
        guard !local.isEmpty else { return }
        try db.transaction {
            for item in local where contains(to, item.path) { try db.delete("journal", item.path) }
            for var item in local where item.path != from && contains(from, item.path) {
                try db.delete("journal", item.path)
                item.path = to + item.path.dropFirst(from.count)
                try db.put("journal", item.path, item)
            }
        }
        try recoverOrphans()
    }
    private func settleChanges(under paths: [String]) throws {
        let pending: [Journal] = try lock.withLock { try db.all("journal") }
        for item in pending where paths.contains(where: { contains($0, item.path) }) { try syncOne(item.path) }
    }
    private func invalidateListings() throws { try db.clear("listing") }
    /// Marks pins covering `path` incomplete. A pin in progress learns of it at completion.
    private func invalidatePins(under path: String, except pinning: String? = nil) throws {
        // Finder rewriting .DS_Store in a pinned folder changes nothing a pin holds.
        guard !Housekeeping.staysLocal(path) else { return }
        let pins: [PinStatus] = try db.all("pin")
        for var pin in pins where pin.path != pinning && (contains(path, pin.path) || contains(pin.path, path)) {
            pin.complete = false; pin.lastError = "Content or namespace changed; pin again to refresh the offline snapshot"
            try db.put("pin", pin.path, pin)
        }
    }

    /// Pins incrementally: bookkeeping takes the state lock per file and fetches run
    /// outside it, so reads and edits continue. Completion, under one lock
    /// acquisition, fails with EBUSY if an edit is pending and ESTALE if the
    /// content changed during the pin.
    public func pin(_ value: String) throws {
        let path = try canonicalPath(value)
        try lock.withLock { try db.put("pin", path, PinStatus(path: path, complete: false, fileCount: 0, lastError: nil)) }
        var fileCount = 0
        do {
            var stack = [path]
            var pinnedFiles = Set<String>()
            while let next = stack.popLast() {
                guard let entry = try pinnedEntry(next, pin: path) else { throw DriveError(EBUSY, "Upload pending edits before pinning") }
                if entry.kind == .directory {
                    stack.append(contentsOf: try list(next, exceptPin: path).map(\.path).filter { !Housekeeping.staysLocal($0) }); continue
                }
                var offset: Int64 = 0
                while offset < entry.size {
                    _ = try block(entry, offset: offset, key: blockKey(entry, offset: offset), cachedLength: nil, mustPersist: true)
                    offset += Int64(blockSize)
                }
                // Do not report a completed snapshot if content changed while downloading.
                // An edit made meanwhile fails the pin at completion instead.
                if let latest = try pinnedEntry(next, pin: path), latest.version != entry.version {
                    throw DriveError(ESTALE, "File changed while pinning")
                }
                try lock.withLock { try removeObsoleteBlocks(for: entry) }
                pinnedFiles.insert(next)
                fileCount += 1
            }
            try lock.withLock {
                let pending: [Journal] = try db.all("journal")
                if pending.contains(where: { !Housekeeping.staysLocal($0.path) && contains(path, $0.path) }) {
                    throw DriveError(EBUSY, "Files changed while pinning; pin again after they upload")
                }
                // invalidatePins records a change on the pin's row; an unpin removes it.
                guard let current: PinStatus = try db.get("pin", path), current.lastError == nil else {
                    throw DriveError(ESTALE, "Content changed while pinning")
                }
                try removeMissingPinnedBlocks(under: path, keeping: pinnedFiles)
                try db.put("pin", path, PinStatus(path: path, complete: true, fileCount: fileCount, lastError: nil))
            }
        } catch {
            try lock.withLock {
                // An unpin during the pin stays unpinned.
                guard var pin: PinStatus = try db.get("pin", path) else { return }
                pin.complete = false; pin.fileCount = fileCount
                pin.lastError = "Pin incomplete (errno \((error as? DriveError)?.code ?? EIO)); downloaded blocks are retained"
                try db.put("pin", path, pin)
            }
            throw error
        }
    }
    /// The remote entry a pin snapshots: fetched now, or the recorded metadata
    /// while offline. Nil while an edit of `path` is pending.
    private func pinnedEntry(_ path: String, pin: String) throws -> FileEntry? {
        let fetched = try refreshMetadataIfNeeded(path, force: true, exceptPin: pin)
        return try lock.withLock(timeout: 10) {
            if let _: Journal = try db.get("journal", path) { return nil }
            if let fetched { return fetched }
            guard let stored: Metadata = try db.get("metadata", path) else {
                throw DriveError(EBUSY, "The drive namespace is changing; retry")
            }
            return stored.entry
        }
    }
    public func unpin(_ value: String) throws {
        try lock.withLock { try db.delete("pin", canonicalPath(value)); try trimCache(to: cacheLimit) }
    }
    @discardableResult public func evictCache() throws -> Int64 {
        try lock.withLock {
            let before = try allocatedCache().evictable
            try trimCache(to: 0)
            return before - (try allocatedCache().evictable)
        }
    }
    public func allocatedLocalBytes(_ value: String) throws -> Int64 {
        try lock.withLock(timeout: 10) {
            let path = try canonicalPath(value)
            let blocks: [Block] = try db.all("block")
            let pending: [Journal] = try db.all("journal")
            let cached = blocks.filter { contains(path, $0.path) }.reduce(Int64(0)) { $0 + DurableIO.allocatedBytes(cache.appendingPathComponent($1.key)) }
            let dirty = pending.filter { contains(path, $0.path) }.flatMap(\.segments).reduce(Int64(0)) { $0 + DurableIO.allocatedBytes(journal.appendingPathComponent($1.blob)) }
            return cached + dirty
        }
    }
    public func status() throws -> DriveStatus {
        try lock.withLock {
            try persistTraffic()
            let sizes = try allocatedCache(), uploads = try uploads()
            let pending = try uploadableJournalAllocation()
            let total = try directoryAllocation(root)
            let traffic: TransferMetrics = try db.get("metrics", "traffic") ?? TransferMetrics()
            return DriveStatus(cacheBytes: sizes.evictable, pinnedBytes: sizes.pinned, pendingWriteBytes: pending,
                               stateBytes: max(0, total - sizes.evictable - sizes.pinned - pending), totalAllocatedBytes: total,
                               cacheLimitBytes: cacheLimit, maxJournalBytes: journalLimit, minFreeBytes: reserve,
                               availableBytes: try DurableIO.freeBytes(root), pendingUploads: uploads.count,
                               conflictedUploads: uploads.filter { $0.state == "conflict" }.count,
                               pins: try db.all("pin"), offline: offline, objectReadBytes: traffic.objectReadBytes,
                               objectGetRequests: traffic.objectGetRequests, indexBackup: try indexBackupStatus(),
                               ownedElsewhere: try db.get("index", "owner"),
                               failingUploads: UploadFailureSummary.make(uploads, now: now()))
        }
    }
    private func pinPaths() throws -> [String] { let pins: [PinStatus] = try db.all("pin"); return pins.map(\.path) }
    private func removeObsoleteBlocks(for entry: FileEntry) throws {
        let blocks: [Block] = try db.all("block")
        for block in blocks where block.path == entry.path && block.version != entry.version {
            try db.delete("block", block.key)
            let file = cache.appendingPathComponent(block.key)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    private func removeMissingPinnedBlocks(under path: String, keeping paths: Set<String>) throws {
        let blocks: [Block] = try db.all("block"), pending: [Journal] = try db.all("journal")
        let separatePins = try pinPaths().filter { $0 != path }
        for block in blocks where contains(path, block.path) && !paths.contains(block.path) {
            if separatePins.contains(where: { contains($0, block.path) }) || pending.contains(where: { $0.path == block.path }) { continue }
            try db.delete("block", block.key)
            let file = cache.appendingPathComponent(block.key)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    private func allocatedCache() throws -> (evictable: Int64, pinned: Int64) {
        let pins = try pinPaths(), blocks: [Block] = try db.all("block")
        var evictable: Int64 = 0, pinned: Int64 = 0
        for block in blocks {
            let bytes = DurableIO.allocatedBytes(cache.appendingPathComponent(block.key))
            if pins.contains(where: { contains($0, block.path) }) { pinned += bytes } else { evictable += bytes }
        }
        return (evictable, pinned)
    }
    private func trimCache(to limit: Int64) throws {
        let pins = try pinPaths(), blocks: [Block] = try db.all("block")
        let evictable = blocks.filter { block in !pins.contains { contains($0, block.path) } }.sorted { $0.accessed < $1.accessed }
        var bytes = evictable.reduce(Int64(0)) { $0 + DurableIO.allocatedBytes(cache.appendingPathComponent($1.key)) }
        for block in evictable where bytes > limit {
            let file = cache.appendingPathComponent(block.key), size = DurableIO.allocatedBytes(file)
            try db.delete("block", block.key)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            bytes -= size
        }
    }
    /// Before the first fetch or commit through `source`, remembers its counters, so
    /// traffic from before this engine used it is not counted.
    private func baselineTraffic(_ source: StorageBackend) {
        let id = ObjectIdentifier(source)
        guard memory.withLock({ trafficSeen[id] == nil }), let sample = try? source.transferMetrics() else { return }
        memory.withLock { if trafficSeen[id] == nil { trafficSeen[id] = sample } }
    }
    /// One sample after each fetch or commit. The counters' growth since the last
    /// sample is this engine's traffic, so concurrent fetches are counted once and a
    /// counter that dips (a rotated connection) only delays the count.
    private func recordTraffic(on source: StorageBackend) {
        // Counters are observability, never a reason to fail an otherwise
        // durable operation. A process killed mid-read can undercount.
        guard let sample = try? source.transferMetrics() else { return }
        let id = ObjectIdentifier(source)
        memory.withLock {
            guard var seen = trafficSeen[id] else { trafficSeen[id] = sample; return }
            unrecordedTraffic.objectReadBytes += max(0, sample.objectReadBytes - seen.objectReadBytes)
            unrecordedTraffic.objectGetRequests += max(0, sample.objectGetRequests - seen.objectGetRequests)
            seen.objectReadBytes = max(seen.objectReadBytes, sample.objectReadBytes)
            seen.objectGetRequests = max(seen.objectGetRequests, sample.objectGetRequests)
            trafficSeen[id] = seen
        }
    }
    /// Under the state lock: adds traffic recorded since the last call to the persisted total.
    private func persistTraffic() throws {
        let delta = memory.withLock { () -> TransferMetrics in defer { unrecordedTraffic = TransferMetrics() }; return unrecordedTraffic }
        guard delta.objectReadBytes > 0 || delta.objectGetRequests > 0 else { return }
        var total = (try? db.get("metrics", "traffic", as: TransferMetrics.self)) ?? TransferMetrics()
        total.objectReadBytes += delta.objectReadBytes; total.objectGetRequests += delta.objectGetRequests
        try? db.put("metrics", "traffic", total)
    }

    // MARK: Changes that need a decision

    static let conflictMessage = "This file changed elsewhere. Your copy is kept on this Mac until you choose which to keep."

    /// Pending changes that never upload by themselves: conflicts, and changes storage
    /// refuses from this Mac (EROFS). Each waits for keepMine, exportChange or keepTheirs.
    public func changesNeedingDecision() throws -> [UploadRecord] { try uploads().filter(\.needsDecision) }

    /// A name for this Mac's copy of `path` that nothing in its folder uses yet:
    /// "Report (conflict 2026-10-23).docx", then "Report (conflict 2026-10-23 2).docx".
    public func suggestedCopyName(for value: String, date: Date = Date()) throws -> String {
        let path = try canonicalPath(value), folder = parent(path)
        let taken = Set(try list(folder).map(\.name))
        return Self.copyName((path as NSString).lastPathComponent, date: date) { taken.contains($0) }
    }
    /// The same naming without a listing; `taken` says which names are in use.
    public static func copyName(_ name: String, date: Date, taken: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let stem = (name as NSString).deletingPathExtension, suffix = (name as NSString).pathExtension
        var attempt = 1
        while true {
            let label = "conflict " + formatter.string(from: date) + (attempt > 1 ? " \(attempt)" : "")
            let candidate = "\(stem) (\(label))" + (suffix.isEmpty ? "" : "." + suffix)
            if !taken(candidate) { return candidate }
            attempt += 1
        }
    }

    /// Keeps this Mac's copy of a conflicted file as a new file named `name` in the same
    /// folder, which uploads like any new file; `path` then shows the version in storage.
    /// Parts of the copy still shared with the version it was based on are read first, from
    /// the cache or storage. When storage no longer has that version (ESTALE), nothing changes.
    @discardableResult
    public func keepMine(_ value: String, as name: String) throws -> FileEntry {
        let path = try canonicalPath(value)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw DriveError(EINVAL, "Choose a name without slashes, up to 255 bytes")
        }
        let target = try canonicalPath((parent(path) == "/" ? "" : parent(path)) + "/" + name)
        guard target != path, !Housekeeping.staysLocal(target) else { throw DriveError(EINVAL, "Choose another name for your copy") }
        try refuseIfOwnedElsewhere(target)
        do { _ = try stat(target); throw DriveError(EEXIST, "Something named “\(name)” is already in this folder") }
        catch let error as DriveError where error.code == ENOENT {}
        do { guard try stat(parent(target)).kind == .directory else { throw DriveError(ENOTDIR, "The file’s folder is gone") } }
        catch let error as DriveError where error.code == ENOENT {
            throw DriveError(ENOENT, "The file’s folder no longer exists in storage. Export your copy instead.")
        }
        return try withDecision(path) { item in
            guard item.state == "conflict" else {
                throw DriveError(EROFS, "This drive doesn’t accept new files from this Mac. Export your copy instead.")
            }
            try fillFromBase(path, item)
            return try lock.withLock {
                guard let current: Journal = try db.get("journal", path), current.transactionID == item.transactionID else {
                    throw DriveError(EBUSY, "The file changed; try again")
                }
                guard (try db.get("journal", target) as Journal?) == nil else { throw DriveError(EEXIST, "Something named “\(name)” is already in this folder") }
                // A new file from now on: no base, a fresh identity and no history of failures.
                var copy = current
                copy.path = target; copy.base = nil; copy.baseVisibleSize = 0
                copy.transactionID = UUID().uuidString; copy.id = UInt64.random(in: (1 << 62)..<UInt64.max)
                copy.sealed = false; copy.state = "pending"; copy.mayHaveApplied = false
                copy.lastError = nil; copy.lastErrno = nil; copy.failures = nil; copy.failingSince = nil; copy.nextAttemptAt = nil
                namespaceEpoch &+= 1
                try db.transaction {
                    try db.delete("journal", path); try db.put("journal", target, copy)
                    try db.delete("metadata", path); try invalidateListings()
                    try invalidatePins(under: path); try invalidatePins(under: target)
                }
                return copy.entry
            }
        }
    }

    /// Writes this Mac's copy of a file that needs a decision to `destination`, outside the
    /// drive, then drops it from the drive as keepTheirs does. For drives that refuse new
    /// files from this Mac, and copies whose folder is gone. An existing `destination` is
    /// replaced only with `replacing`.
    public func exportChange(_ value: String, to destination: URL, replacing: Bool = false) throws {
        let path = try canonicalPath(value)
        guard destination.isFileURL else { throw DriveError(EINVAL, "Choose a file on this Mac") }
        try withDecision(path) { item in
            let folder = destination.deletingLastPathComponent()
            let staged = folder.appendingPathComponent(".paraair-export-" + UUID().uuidString)
            let fd = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard fd >= 0 else { throw DriveError(errno, "Can’t write to that folder") }
            var published = false
            defer { if !published { _ = Darwin.unlink(staged.path) } }
            do {
                defer { Darwin.close(fd) }
                var offset: Int64 = 0
                while offset < item.size {
                    let bytes = try readForDecision(path, offset: offset, length: Int(min(item.size - offset, 8 << 20)))
                    try bytes.withUnsafeBytes { raw in
                        var written = 0
                        while written < raw.count {
                            let count = Darwin.pwrite(fd, raw.baseAddress!.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
                            if count < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Couldn’t write your copy") }
                            guard count > 0 else { throw DriveError(EIO, "Couldn’t write your copy") }
                            written += count
                        }
                    }
                    offset += Int64(bytes.count)
                }
                guard Darwin.fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw DriveError(errno, "Couldn’t save your copy") }
            }
            let modified = TimeInterval(item.modified) / 1_000_000_000
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: staged.path)
            let moved = replacing ? Darwin.rename(staged.path, destination.path)
                : renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL))
            guard moved == 0 else {
                throw errno == EEXIST ? DriveError(EEXIST, "A file with that name is already there") : DriveError(errno, "Couldn’t save your copy")
            }
            published = true
            try DurableIO.syncDirectory(folder)
            try discard(path, item)
        }
    }

    /// Drops this Mac's copy of a file that needs a decision, so the version in storage
    /// shows (or nothing, if storage has none). Any other pending change still uploads.
    public func keepTheirs(_ value: String) throws {
        let path = try canonicalPath(value)
        try withDecision(path) { try discard(path, $0) }
    }

    /// Runs `body` with `path`'s journal while holding its upload lock, so no upload or
    /// settling runs meanwhile. Only changes that need a decision qualify.
    private func withDecision<T>(_ path: String, _ body: (Journal) throws -> T) throws -> T {
        assert(!lock.isHeldByCurrentThread, "Decisions read storage and must not run under the drive state lock")
        return try legacyUploadLock.withShared {
            let pathLock = try uploadLock(for: path)
            return try pathLock.withLock {
                guard let item: Journal = try lock.withLock({ try db.get("journal", path) }), !Housekeeping.staysLocal(path),
                      item.state == "conflict" || item.lastErrno == EROFS else {
                    throw DriveError(ENOENT, "This file has no change waiting for a decision")
                }
                let result = try body(item)
                published(path, lock: pathLock, sealedAt: DispatchTime.now().uptimeNanoseconds)
                return result
            }
        }
    }
    /// Under the path's upload lock: deletes the journal `item` names, unless it moved on.
    private func discard(_ path: String, _ item: Journal) throws {
        try lock.withLock {
            guard let current: Journal = try db.get("journal", path), current.transactionID == item.transactionID else {
                throw DriveError(EBUSY, "The file changed; try again")
            }
            namespaceEpoch &+= 1
            try db.transaction {
                try db.delete("journal", path); try db.delete("metadata", path)
                try invalidateListings(); try invalidatePins(under: path)
            }
            try recoverOrphans()
        }
    }
    /// The local view of a range, which may need the version the change was based on.
    /// Storage that no longer has that version answers ESTALE.
    private func readForDecision(_ path: String, offset: Int64, length: Int) throws -> Data {
        do { return try read(path, offset: offset, length: length) }
        catch let error as DriveError where error.code == ESTALE {
            throw DriveError(ESTALE, "Part of your copy is still the earlier version of the file, and storage no longer has it. "
                             + "Only the version in storage can be kept.")
        }
    }
    /// Copies into the journal every byte the change still takes from its base, so it no
    /// longer needs the base. The copies hold what reads already show, so a crash midway
    /// leaves the same file. Called with the path's upload lock held.
    private func fillFromBase(_ path: String, _ item: Journal) throws {
        var uncovered: [Range<Int64>] = item.baseVisibleSize > 0 ? [0..<item.baseVisibleSize] : []
        for segment in item.segments {
            let covered = segment.offset..<(segment.offset + segment.length)
            uncovered = uncovered.flatMap { range -> [Range<Int64>] in
                guard range.overlaps(covered) else { return [range] }
                return [range.lowerBound..<max(range.lowerBound, covered.lowerBound), min(range.upperBound, covered.upperBound)..<range.upperBound]
                    .filter { !$0.isEmpty }
            }
        }
        for range in uncovered {
            var offset = range.lowerBound
            while offset < range.upperBound {
                let bytes = try readForDecision(path, offset: offset, length: Int(min(range.upperBound - offset, 8 << 20)))
                guard !bytes.isEmpty else { throw DriveError(EIO, "Your copy is shorter than expected") }
                try lock.withLock {
                    guard var current: Journal = try db.get("journal", path), current.transactionID == item.transactionID else {
                        throw DriveError(EBUSY, "The file changed; try again")
                    }
                    try ensureJournalSpace(Int64(bytes.count))
                    let blob = UUID().uuidString + ".data"
                    try DurableIO.write(bytes, to: journal.appendingPathComponent(blob))
                    // Beneath the local writes, which never overlap these ranges anyway.
                    current.segments.insert(Segment(offset: offset, length: Int64(bytes.count), blob: blob), at: 0)
                    try db.put("journal", path, current)
                }
                offset += Int64(bytes.count)
            }
        }
    }

    // MARK: Sequential readahead (cloud tuning only)

    /// The readahead windows of active streams, in blocks. For tests.
    func readaheadWindows() -> [String: Int] { memory.withLock { streams.compactMapValues { $0.window > 0 ? $0.window : nil } } }
    /// Waits until queued prefetches finish. For tests.
    func waitForReadahead() { prefetchQueue.waitUntilAllOperationsAreFinished() }
    /// Detects sequential reads of `path` and queues prefetches of the blocks after
    /// `end`. The window starts at two blocks on the second sequential read and
    /// doubles up to min(maxBlocks, cacheLimit / blockSize / 4); all windows together
    /// stay within half the cache. A seek restarts detection and cancels queued work.
    private func readahead(_ path: String, entry: FileEntry, offset: Int64, end: Int64, hasJournal: Bool) {
        guard tuning.readahead.maxBlocks > 0 else { return }
        let size = Int64(blockSize), cap = min(tuning.readahead.maxBlocks, Int(cacheLimit / size / 4))
        let budget = Int(cacheLimit / 2 / size), uptime = DispatchTime.now().uptimeNanoseconds
        let queued = memory.withLock { () -> (generation: UInt64, offsets: [Int64])? in
            streams = streams.filter { uptime &- $0.value.lastUse < 30_000_000_000 }
            guard var stream = streams[path], stream.next == offset, !hasJournal, cap > 0 else {
                streamGenerations &+= 1
                streams[path] = ReadStream(next: end, generation: streamGenerations, lastUse: uptime)
                if streams.count > 64, let oldest = streams.min(by: { $0.value.lastUse < $1.value.lastUse })?.key { streams[oldest] = nil }
                return nil
            }
            stream.next = end; stream.lastUse = uptime
            defer { streams[path] = stream }
            let start = (end + size - 1) / size * size
            guard start < entry.size else { stream.window = 0; return nil }
            let others = streams.reduce(0) { $0 + ($1.key == path ? 0 : $1.value.window) }
            stream.window = min(max(2, stream.window * 2), cap, max(0, budget - others))
            let limit = min(entry.size, start + Int64(stream.window) * size)
            var offsets: [Int64] = [], at = max(start, stream.scheduled)
            while at < limit { offsets.append(at); at += size }
            stream.scheduled = max(stream.scheduled, limit)
            return offsets.isEmpty ? nil : (stream.generation, offsets)
        }
        guard let queued else { return }
        for blockOffset in queued.offsets {
            prefetchQueue.addOperation { [weak self] in
                self?.prefetch(path, entry: entry, offset: blockOffset, generation: queued.generation)
            }
        }
    }
    /// One queued prefetch. Skips a superseded stream, a block already cached or in
    /// flight, and files with local edits. Any failure, such as ESTALE when the
    /// file changed, stops the stream's readahead. Never sets `mustPersist`.
    private func prefetch(_ path: String, entry: FileEntry, offset: Int64, generation: UInt64) {
        let key = blockKey(entry, offset: offset)
        let current = memory.withLock { streams[path]?.generation == generation && flights[key] == nil }
        guard current, cachedBlock(key, length: Int(min(Int64(blockSize), entry.size - offset))) == nil,
              let eligible = try? lock.withLock(timeout: 10, { () -> Bool in
                  let pending: Journal? = try db.get("journal", path), row: Block? = try db.get("block", key)
                  return pending == nil && row == nil
              }), eligible else { return }
        do { _ = try block(entry, offset: offset, key: key, cachedLength: nil, isPrefetch: true) }
        catch { memory.withLock { if streams[path]?.generation == generation { streams[path] = nil } } }
    }
    /// Thrown from a writer under the state lock when the journal is full but the
    /// write would fit once other files publish. Caught where no lock is held.
    private struct JournalFull: Error {}
    private func ensureJournalSpace(_ additional: Int64, drainable: Bool = false) throws {
        let used = try directoryAllocation(journal)
        let estimated = (additional + 4095) / 4096 * 4096
        guard used <= journalLimit, estimated <= journalLimit - used else {
            if drainable && estimated <= journalLimit { throw JournalFull() }
            throw DriveError(ENOSPC, "Pending-write journal limit reached; upload before writing more")
        }
        let free = try DurableIO.freeBytes(root)
        if free - estimated - 65_536 < reserve { try trimCache(to: 0) }
        guard try DurableIO.freeBytes(root) - estimated - 65_536 >= reserve else { throw DriveError(ENOSPC, "Write would exceed the local free-space reserve") }
    }
    private func readLocal(_ url: URL, offset: Int64, length: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DriveError(errno, "Local cached data is unavailable") }
        defer { Darwin.close(fd) }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in
            var read = 0
            while read < length {
                let count = Darwin.pread(fd, raw.baseAddress!.advanced(by: read), length - read, off_t(offset + Int64(read)))
                if count < 0 { if errno == EINTR { continue }; throw DriveError(errno, "Cannot read local data") }
                guard count > 0 else { throw DriveError(EIO, "Local data is incomplete") }; read += count
            }
        }
        return data
    }
    private func directoryAllocation(_ url: URL) throws -> Int64 {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return 0 }
        var count: Int64 = 0
        while let file = files.nextObject() as? URL { count += DurableIO.allocatedBytes(file) }
        return count
    }
    private func indexBackupStatus() throws -> IndexBackupStatus? {
        // Whether a drive's index is local is learned on its first attempt; until then, nothing to report.
        guard let state: IndexBackupState = try db.get("index", "backup"), !state.notNeeded,
              state.lastBackupAt != nil || state.lastError != nil else { return nil }
        return IndexBackupStatus(lastBackupNanoseconds: state.lastBackupAt, pendingSinceNanoseconds: state.firstChangeAt,
                                 lastError: state.lastError, lastErrno: state.lastErrno)
    }
    /// Refuses a change once another Mac owns the drive. Housekeeping stays local, so it is
    /// never refused.
    private func refuseIfOwnedElsewhere(_ path: String) throws {
        guard !Housekeeping.staysLocal(path), let owner = try ownedElsewhere(refresh: false) else { return }
        throw DriveError(EROFS, "This drive is now used on \(owner.ownerName ?? "another Mac"). It’s read-only on this Mac.")
    }
    /// Whether another Mac owns this drive. After 10 s, asks storage, which answers from its
    /// last check without the network; with `refresh`, storage reads the owner record now.
    /// Offline or unconnected, the saved answer stands. Changes are saved for other
    /// processes (the app, the CLI).
    @discardableResult
    public func ownedElsewhere(refresh: Bool = false) throws -> OwnedElsewhere? {
        let uptime = DispatchTime.now().uptimeNanoseconds
        if !refresh, let cached = memory.withLock({ ownershipChecked }), uptime &- cached.uptime < 10_000_000_000 { return cached.value }
        let (saved, isOffline): (OwnedElsewhere?, Bool) = try lock.withLock(timeout: 10) { (try db.get("index", "owner"), offline) }
        var value = saved
        if !isOffline, let answer = try? backend.ownership(refresh: refresh) {
            if answer.ownedElsewhere {
                if value?.ownerName != answer.ownerName || value == nil { value = OwnedElsewhere(ownerName: answer.ownerName, seenNanoseconds: now()) }
            } else { value = nil }
            // Written only when it changes, so the write path rarely touches the database.
            if value != saved {
                try lock.withLock(timeout: 10) {
                    if let value { try db.put("index", "owner", value) } else { try db.delete("index", "owner") }
                }
            }
        }
        memory.withLock { ownershipChecked = (uptime, value) }
        return value
    }
    /// The saved notices, without storage or the cache walk `status()` does: for polling.
    public func notices() throws -> (indexBackup: IndexBackupStatus?, ownedElsewhere: OwnedElsewhere?) {
        try lock.withLock(timeout: 10) { (try indexBackupStatus(), try db.get("index", "owner")) }
    }
    /// Records, under the state lock, that a change reached storage since the last index
    /// backup. Best effort: the change itself already succeeded, so a failed note must not
    /// turn it into an error; the next change records it again.
    private func noteIndexChange() {
        do {
            var state: IndexBackupState = try db.get("index", "backup") ?? IndexBackupState()
            guard !state.notNeeded else { return }
            let clock = now()
            state.changedAt = clock
            if state.firstChangeAt == nil { state.firstChangeAt = clock }
            try db.put("index", "backup", state)
        } catch {}
    }
    /// Backs up the drive's index into its storage when changes are waiting and the policy
    /// says it is time. Returns whether a backup was made. One runs at a time per engine;
    /// never call it under the state lock. A failure is recorded and rethrown.
    @discardableResult
    public func backupIndexIfDue(policy: IndexBackupPolicy = .standard) throws -> Bool {
        assert(!lock.isHeldByCurrentThread, "Index backups must not run under the drive state lock")
        let (due, previous) = try lock.withLock(timeout: 10) { () -> (Bool, String?) in
            guard let state: IndexBackupState = try db.get("index", "backup"), !state.notNeeded,
                  let changed = state.changedAt, let first = state.firstChangeAt else { return (false, nil) }
            // Times are wall clock, persisted across restarts. One in the future means the
            // clock went back; treat that span as elapsed rather than wait for it again.
            let clock = now()
            func elapsed(since time: Int64) -> Int64 { clock >= time ? clock - time : .max }
            if state.failures > 0, let attempt = state.lastAttemptAt {
                let retry = state.lastErrno == EFBIG ? 86_400_000_000_000
                    : min(policy.retryNanoseconds << Int64(min(state.failures - 1, 4)), 3_600_000_000_000)
                if elapsed(since: attempt) < retry { return (false, nil) }
            }
            if let last = state.lastBackupAt, elapsed(since: last) < policy.minIntervalNanoseconds { return (false, nil) }
            return (elapsed(since: changed) >= policy.quietNanoseconds || elapsed(since: first) >= policy.maxDelayNanoseconds, state.lastKey)
        }
        guard due, memory.withLock({ () -> Bool in
            if indexBackupRunning { return false }
            indexBackupRunning = true; return true
        }) else { return false }
        defer { memory.withLock { indexBackupRunning = false } }
        let started = now()
        let key: String?
        do { key = try backend.backupIndex(replacing: previous) }
        catch {
            try lock.withLock(timeout: 10) {
                var state: IndexBackupState = try db.get("index", "backup") ?? IndexBackupState()
                state.lastAttemptAt = now(); state.failures += 1
                state.lastError = (error as? DriveError)?.message ?? error.localizedDescription
                state.lastErrno = (error as? DriveError)?.code
                try db.put("index", "backup", state)
            }
            throw error
        }
        // The backup exists now; failing to record it is a state error, not a failed backup.
        try lock.withLock(timeout: 10) {
            var state: IndexBackupState = try db.get("index", "backup") ?? IndexBackupState()
            if let key {
                state.lastBackupAt = started; state.lastAttemptAt = started; state.lastKey = key
                state.lastError = nil; state.lastErrno = nil; state.failures = 0
                // A change made while the dump ran may be missing from it. It happened after
                // `started`, so measuring the delay from there keeps the bound.
                if let changed = state.changedAt, changed > started { state.firstChangeAt = started }
                else { state.changedAt = nil; state.firstChangeAt = nil }
            } else {
                state = IndexBackupState(notNeeded: true)
            }
            try db.put("index", "backup", state)
        }
        return key != nil
    }
    /// Journal bytes that still have to upload: everything but local-only files.
    private func uploadableJournalAllocation() throws -> Int64 {
        let pending: [Journal] = try db.all("journal")
        let local = pending.filter { Housekeeping.staysLocal($0.path) }.flatMap(\.segments)
            .reduce(Int64(0)) { $0 + DurableIO.allocatedBytes(journal.appendingPathComponent($1.blob)) }
        return max(0, try directoryAllocation(journal) - local)
    }
    private func recoverOrphans() throws {
        let pending: [Journal] = try db.all("journal"), blocks: [Block] = try db.all("block")
        let liveJournal = Set(pending.flatMap(\.segments).map(\.blob)), liveCache = Set(blocks.map(\.key))
        for (directory, live) in [(journal, liveJournal), (cache, liveCache)] {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !live.contains(url.lastPathComponent) {
                // Only generated immutable payload names are owned by recovery.
                let name = url.lastPathComponent
                if name.hasPrefix(".tmp-") || (directory == journal && name.hasSuffix(".data") && UUID(uuidString: String(name.dropLast(5))) != nil) || (directory == cache && name.count == 64 && name.allSatisfy(\.isHexDigit)) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
