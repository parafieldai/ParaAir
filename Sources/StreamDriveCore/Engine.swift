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

/// The same durable state is shared by the CLI and FSKit process. A process
/// lock covers database changes and filesystem publication; WAL + FULL sync
/// acknowledges writes only after the immutable payload and journal are durable.
public final class Engine {
    private let backend: StorageBackend
    private let publisher: StorageBackend
    private let root: URL
    private let cache: URL
    private let journal: URL
    private let db: Database
    private let lock: StateLock
    private let uploadLock: StateLock
    private let cacheLimit: Int64
    private let reserve: Int64
    private let blockSize: Int
    private let journalLimit: Int64
    private var offline = false
    private let metadataLifetime: Int64 = 1_000_000_000

    public init(backend: StorageBackend, stateDirectory: URL,
                cacheLimitBytes: Int64 = 1_073_741_824, minFreeBytes: Int64 = 5_368_709_120,
                blockSize: Int = 1_048_576, maxJournalBytes: Int64 = 4_294_967_296,
                publishingBackend: StorageBackend? = nil) throws {
        guard stateDirectory.isFileURL, cacheLimitBytes >= 0, minFreeBytes >= 0,
              blockSize >= 4096, blockSize <= 8 * 1024 * 1024,
              maxJournalBytes >= 0 else { throw DriveError(EINVAL, "Invalid drive cache or journal configuration") }
        self.backend = backend; publisher = publishingBackend ?? backend; root = stateDirectory
        cache = root.appendingPathComponent("cache", isDirectory: true)
        journal = root.appendingPathComponent("journal", isDirectory: true)
        cacheLimit = cacheLimitBytes; reserve = minFreeBytes; self.blockSize = blockSize; journalLimit = maxJournalBytes
        try DurableIO.directory(root)
        lock = try StateLock(root.appendingPathComponent("state.lock"))
        uploadLock = try StateLock(root.appendingPathComponent("upload.lock"))
        db = try lock.withLock { [cache, journal, root] in
            try DurableIO.directory(cache); try DurableIO.directory(journal)
            return try Database(root.appendingPathComponent("state.sqlite3"))
        }
        try lock.withLock { try recoverOrphans(); try trimCache(to: cacheLimit) }
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
    private func record(_ entry: FileEntry) throws {
        if let previous: Metadata = try db.get("metadata", entry.path), previous.entry.version != entry.version {
            try invalidatePins(under: entry.path)
        }
        try db.put("metadata", entry.path, Metadata(entry: entry, verified: now()))
    }
    private func remoteStat(_ path: String, fresh: Bool = false) throws -> FileEntry {
        let cached: Metadata? = try db.get("metadata", path)
        if !fresh, let cached, now() - cached.verified < metadataLifetime { return cached.entry }
        do {
            let entry = try backend.stat(path); offline = false; try record(entry); return entry
        } catch {
            if isOfflineError(error), let cached { offline = true; return cached.entry }
            if (error as? DriveError)?.code == ENOENT { try db.delete("metadata", path); try invalidatePins(under: path) }
            throw error
        }
    }
    public func stat(_ value: String) throws -> FileEntry {
        try lock.withLock {
            let path = try canonicalPath(value)
            if let pending: Journal = try db.get("journal", path) { return pending.entry }
            return try remoteStat(path)
        }
    }
    public func list(_ value: String) throws -> [FileEntry] {
        try lock.withLock {
            let path = try canonicalPath(value)
            var entries: [FileEntry]
            do {
                entries = try backend.list(path); offline = false
                try db.transaction {
                    if let previous: [FileEntry] = try db.get("listing", path), Set(previous.map(\.path)) != Set(entries.map(\.path)) {
                        try invalidatePins(under: path)
                    }
                    for entry in entries { try record(entry) }
                    try db.put("listing", path, entries)
                }
            } catch {
                guard isOfflineError(error), let saved: [FileEntry] = try db.get("listing", path) else { throw error }
                offline = true; entries = saved
            }
            let pending: [Journal] = try db.all("journal")
            var byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
            for item in pending where parent(item.path) == path { byPath[item.path] = item.entry }
            return byPath.values.sorted { $0.name < $1.name }
        }
    }

    public func read(_ value: String, offset: Int64, length: Int) throws -> Data {
        try lock.withLock {
            let path = try canonicalPath(value)
            guard offset >= 0, length >= 0, length <= 64 * 1024 * 1024,
                  offset <= Int64.max - Int64(length) else { throw DriveError(EINVAL, "Invalid read range (maximum 64 MiB per call)") }
            let pending: Journal? = try db.get("journal", path)
            let entry = try pending?.entry ?? remoteStat(path)
            guard entry.kind == .file else { throw DriveError(EISDIR, "Cannot read a directory") }
            if offset >= entry.size || length == 0 { return Data() }
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
            if let base {
                for range in uncovered {
                    var at = range.lowerBound
                    while at < range.upperBound {
                        let blockOffset = at / Int64(blockSize) * Int64(blockSize)
                        let bytes = try loadBlock(base, offset: blockOffset)
                        let inside = Int(at - blockOffset)
                        let take = min(bytes.count - inside, Int(range.upperBound - at))
                        guard take > 0 else { throw DriveError(EIO, "Backend returned a short file range") }
                        result.replaceSubrange(Int(at - offset)..<Int(at - offset) + take, with: bytes[inside..<inside + take])
                        at += Int64(take)
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
            return result
        }
    }

    @discardableResult public func write(_ value: String, offset: Int64, data: Data) throws -> Int {
        let path = try canonicalPath(value)
        return try withWritableJournal(path) { original in
            guard offset >= 0, data.count <= 64 * 1024 * 1024, offset <= Int64.max - Int64(data.count) else {
                throw DriveError(EINVAL, "Invalid write range (maximum 64 MiB per call)")
            }
            var pending = original
            if data.isEmpty { return 0 }
            try ensureJournalSpace(Int64(data.count))
            let blob = UUID().uuidString + ".data"
            try DurableIO.write(data, to: journal.appendingPathComponent(blob))
            pending.segments.append(Segment(offset: offset, length: Int64(data.count), blob: blob))
            pending.size = max(pending.size, offset + Int64(data.count)); pending.modified = now()
            try db.transaction { try db.put("journal", path, pending); try invalidatePins(under: path) }
            return data.count
        }
    }
    public func create(_ value: String, directory: Bool) throws -> FileEntry {
        try lock.withLock {
            let path = try canonicalPath(value)
            do { _ = try stat(path); throw DriveError(EEXIST, "Path already exists") }
            catch let error as DriveError where error.code == ENOENT {} // Only a confirmed missing path permits creation.
            if directory {
                let entry = try backend.createDirectory(path); try record(entry); try invalidateListings(); return entry
            }
            guard try stat(parent(path)).kind == .directory else { throw DriveError(ENOTDIR, "Parent is not a directory") }
            try ensureJournalSpace(0)
            let timestamp = now()
            let pending = Journal(transactionID: UUID().uuidString, path: path, base: nil, size: 0,
                                  baseVisibleSize: 0, modified: timestamp, id: UInt64.random(in: (1 << 62)..<UInt64.max),
                                  mode: 0o644, segments: [], accessed: timestamp)
            try db.transaction { try db.put("journal", path, pending); try invalidatePins(under: path) }
            return pending.entry
        }
    }
    public func truncate(_ value: String, size: Int64) throws {
        let path = try canonicalPath(value)
        try withWritableJournal(path) { original in
            guard size >= 0 else { throw DriveError(EINVAL, "Negative file size") }
            var pending = original
            try ensureJournalSpace(0)
            pending.size = size; pending.baseVisibleSize = min(pending.baseVisibleSize, size); pending.modified = now()
            pending.segments = pending.segments.compactMap { segment in
                guard segment.offset < size else { return nil }
                var clipped = segment; clipped.length = min(clipped.length, size - segment.offset); return clipped
            }
            try db.transaction { try db.put("journal", path, pending); try invalidatePins(under: path) }
            try recoverOrphans()
        }
    }
    private func withWritableJournal<T>(_ path: String, _ body: (Journal) throws -> T) throws -> T {
        while true {
            let result: T? = try lock.withLock {
                if let existing: Journal = try db.get("journal", path) {
                    if existing.sealed { return nil }
                    return try body(existing)
                }
                let base = try remoteStat(path)
                guard base.kind == .file else { throw DriveError(EISDIR, "Cannot modify a directory") }
                return try body(Journal(transactionID: UUID().uuidString, path: path, base: base, size: base.size,
                                        baseVisibleSize: base.size, modified: now(), id: base.id, mode: base.mode, segments: []))
            }
            if let result { return result }
            // Wait only on a sealed transaction of the file being edited. State
            // and cache locks remain free while the network outcome is resolved.
            try syncOne(path)
        }
    }

    public func fsync(_ value: String) throws {
        try syncOne(canonicalPath(value))
    }
    /// Returns remaining uploads, including conflicts; successful publications
    /// disappear from this list. Failures never discard acknowledged local data.
    public func flushUploads() throws -> [UploadRecord] {
        let pending: [Journal] = try lock.withLock { try db.all("journal") }
        for item in pending where item.state != "conflict" { do { try syncOne(item.path) } catch {} }
        return try uploads()
    }
    private func syncOne(_ path: String) throws {
        try uploadLock.withLock {
        guard var pending: Journal = try lock.withLock({
            guard var item: Journal = try db.get("journal", path) else { return nil }
            if item.state == "conflict" { throw DriveError(ESTALE, "Remote file changed; pending local data is retained") }
            item.sealed = true; try db.put("journal", path, item); return item
        }) else { return }
        let commit = FileCommit(transactionID: pending.transactionID, path: path, expectedVersion: pending.base?.version,
                                finalSize: pending.size, baseVisibleSize: pending.baseVisibleSize, mode: pending.mode,
                                extents: pending.segments.map { WriteExtent(offset: $0.offset, length: $0.length, blobURL: journal.appendingPathComponent($0.blob)) })
        do {
            let published = try measured(on: publisher) { try publisher.commit(commit) }
            try lock.withLock {
                try db.transaction { try db.delete("journal", path); try record(published); try invalidateListings() }
                offline = false; try recoverOrphans()
            }
        } catch {
            try lock.withLock {
            if (error as? DriveError)?.code == ESTALE || (error as? DriveError)?.code == EEXIST { pending.state = "conflict" }
            pending.lastError = "Remote commit failed (errno \((error as? DriveError)?.code ?? EIO)); local data is retained"
            if isOfflineError(error) { offline = true }
            // If local cleanup fails after publication, do not resurrect a
            // journal already removed by the successful database transaction.
            if let _: Journal = try db.get("journal", path) { try db.put("journal", path, pending) }
            }
            throw error
        }
        }
    }
    public func uploads() throws -> [UploadRecord] {
        try lock.withLock {
            let pending: [Journal] = try db.all("journal")
            return pending.map { item in
                UploadRecord(transactionID: item.transactionID, path: item.path, logicalSize: item.size,
                             pendingBytes: item.segments.reduce(0) { $0 + DurableIO.allocatedBytes(journal.appendingPathComponent($1.blob)) },
                             state: item.state, lastError: item.lastError)
            }
        }
    }
    public func move(_ source: String, to destination: String) throws {
        let from = try canonicalPath(source), to = try canonicalPath(destination)
        if from == to, from != "/" { _ = try stat(from); return }
        guard from != "/", to != "/", !contains(from, to) else { throw DriveError(EINVAL, "Invalid rename") }
        try settleChanges(under: [from, to])
        try lock.withLock {
            // Namespace changes require connectivity. Flush affected files first
            // so rename cannot orphan a journal or erase an acknowledged save.
            let pending: [Journal] = try db.all("journal")
            guard !pending.contains(where: { contains(from, $0.path) || contains(to, $0.path) }) else {
                throw DriveError(EBUSY, "File changed during rename preparation; retry after saving")
            }
            try backend.move(from, to: to)
            try db.clear("metadata"); try invalidateListings()
            // Cached content remains evictable; pin snapshots must be recreated.
            try invalidatePins(under: from); try invalidatePins(under: to)
        }
    }
    public func remove(_ value: String, directory: Bool) throws {
        let path = try canonicalPath(value)
        guard path != "/" else { throw DriveError(EBUSY, "Cannot remove the drive root") }
        try settleChanges(under: [path])
        try lock.withLock {
            let pending: [Journal] = try db.all("journal")
            guard !pending.contains(where: { contains(path, $0.path) }) else {
                throw DriveError(EBUSY, "File changed during removal preparation; retry after saving")
            }
            try backend.remove(path, directory: directory)
            try db.clear("metadata"); try invalidateListings(); try invalidatePins(under: path)
        }
    }
    private func settleChanges(under paths: [String]) throws {
        let pending: [Journal] = try lock.withLock { try db.all("journal") }
        for item in pending where paths.contains(where: { contains($0, item.path) }) { try syncOne(item.path) }
    }
    private func invalidateListings() throws { try db.clear("listing") }
    private func invalidatePins(under path: String) throws {
        let pins: [PinStatus] = try db.all("pin")
        for var pin in pins where contains(path, pin.path) || contains(pin.path, path) {
            pin.complete = false; pin.lastError = "Content or namespace changed; pin again to refresh the offline snapshot"
            try db.put("pin", pin.path, pin)
        }
    }

    public func pin(_ value: String) throws {
        try lock.withLock {
            let path = try canonicalPath(value)
            var pin = PinStatus(path: path, complete: false, fileCount: 0, lastError: nil)
            try db.put("pin", path, pin)
            do {
                var stack = [path]
                var pinnedFiles = Set<String>()
                while let next = stack.popLast() {
                    if let _: Journal = try db.get("journal", next) { throw DriveError(EBUSY, "Upload pending edits before pinning") }
                    let entry = try remoteStat(next, fresh: true)
                    if entry.kind == .directory { stack.append(contentsOf: try list(next).map(\.path)); continue }
                    var offset: Int64 = 0
                    while offset < entry.size { _ = try loadBlock(entry, offset: offset, mustPersist: true); offset += Int64(blockSize) }
                    // Do not report a completed snapshot if content changed while downloading.
                    guard try remoteStat(next, fresh: true).version == entry.version else { throw DriveError(ESTALE, "File changed while pinning") }
                    try removeObsoleteBlocks(for: entry)
                    pinnedFiles.insert(next)
                    pin.fileCount += 1
                }
                try removeMissingPinnedBlocks(under: path, keeping: pinnedFiles)
                pin.complete = true; try db.put("pin", path, pin)
            } catch {
                pin.lastError = "Pin incomplete (errno \((error as? DriveError)?.code ?? EIO)); downloaded blocks are retained"
                try db.put("pin", path, pin); throw error
            }
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
        try lock.withLock {
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
            let sizes = try allocatedCache(), uploads = try uploads()
            let pending = try directoryAllocation(journal)
            let total = try directoryAllocation(root)
            let traffic: TransferMetrics = try db.get("metrics", "traffic") ?? TransferMetrics()
            return DriveStatus(cacheBytes: sizes.evictable, pinnedBytes: sizes.pinned, pendingWriteBytes: pending,
                               stateBytes: max(0, total - sizes.evictable - sizes.pinned - pending), totalAllocatedBytes: total,
                               cacheLimitBytes: cacheLimit, maxJournalBytes: journalLimit, minFreeBytes: reserve,
                               availableBytes: try DurableIO.freeBytes(root), pendingUploads: uploads.count,
                               conflictedUploads: uploads.filter { $0.state == "conflict" }.count,
                               pins: try db.all("pin"), offline: offline, objectReadBytes: traffic.objectReadBytes,
                               objectGetRequests: traffic.objectGetRequests)
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
    private func loadBlock(_ entry: FileEntry, offset: Int64, mustPersist: Bool = false) throws -> Data {
        let identity = entry.path + "\0" + entry.version + "\0" + String(offset) + "\0" + String(blockSize)
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent(key)
        if var block: Block = try db.get("block", key) {
            if let bytes = try? readLocal(file, offset: 0, length: block.length) {
                block.accessed = now(); try db.put("block", key, block); return bytes
            }
            try db.delete("block", key)
        }
        let count = Int(min(Int64(blockSize), entry.size - offset))
        guard count > 0 else { return Data() }
        let bytes: Data
        do { bytes = try measured { try backend.readSnapshot(entry.path, version: entry.version, offset: offset, length: count) }; offline = false }
        catch { if isOfflineError(error) { offline = true }; throw error }
        guard bytes.count == count else { throw DriveError(EIO, "Backend returned a short file range") }
        let pinned = try pinPaths().contains { contains($0, entry.path) }
        let estimate = (Int64(bytes.count) + 4095) / 4096 * 4096
        if !pinned { try trimCache(to: max(0, cacheLimit - estimate)) }
        let free = try DurableIO.freeBytes(root)
        let canCache = (pinned || estimate <= cacheLimit) && free - estimate - 65_536 >= reserve
        if canCache {
            try DurableIO.write(bytes, to: file)
            try db.put("block", key, Block(key: key, path: entry.path, version: entry.version, offset: offset, length: count, accessed: now()))
            if !pinned { try trimCache(to: cacheLimit) }
        } else if mustPersist { throw DriveError(ENOSPC, "Pin would exceed the local free-space reserve") }
        return bytes
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
    private func measured<T>(on source: StorageBackend? = nil, _ body: () throws -> T) throws -> T {
        let source = source ?? backend
        let before = try? source.transferMetrics()
        defer {
            // Counters are observability, never a reason to reject an otherwise
            // durable operation. A process killed mid-read can undercount.
            if let before, let after = try? source.transferMetrics() {
                try? lock.withLock {
                var total = (try? db.get("metrics", "traffic", as: TransferMetrics.self)) ?? TransferMetrics()
                total.objectReadBytes += max(0, after.objectReadBytes - before.objectReadBytes)
                total.objectGetRequests += max(0, after.objectGetRequests - before.objectGetRequests)
                try? db.put("metrics", "traffic", total)
                }
            }
        }
        return try body()
    }
    private func ensureJournalSpace(_ additional: Int64) throws {
        let used = try directoryAllocation(journal)
        let estimated = (additional + 4095) / 4096 * 4096
        guard used <= journalLimit, estimated <= journalLimit - used else { throw DriveError(ENOSPC, "Pending-write journal limit reached; upload before writing more") }
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
